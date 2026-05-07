;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Migration system
;;;;
;;;; Versioned schema migrations with sequential execution and rollback.
;;;; Migrations are registered per-module (a simple string key) and
;;;; tracked in a database table. On startup, call (migrate "my-module")
;;;; to run all pending migrations in order.
;;;;
;;;; Usage:
;;;;   (migrate:define-migration "my-app" 1
;;;;     :up (lambda ()
;;;;           (fluxion.db:create "posts"
;;;;             '((title :text) (body :text))))
;;;;     :down (lambda ()
;;;;             (fluxion.db:drop "posts")))
;;;;
;;;;   (migrate:migrate "my-app")

(defpackage #:fluxion.migrate
  (:use #:cl)
  (:local-nicknames (#:db #:fluxion.db))
  (:export
   ;; Setup
   #:setup
   ;; Defining migrations
   #:define-migration
   #:clear-migrations
   ;; Running
   #:migrate
   #:rollback
   #:rollback-to
   ;; Querying
   #:current-version
   #:pending
   #:history
   #:migrations-for))

(in-package #:fluxion.migrate)

;;; -------------------------------------------------------
;;; Migration registry (in-memory)
;;; -------------------------------------------------------

(defstruct migration
  "A registered migration step."
  (module "" :type string)
  (version 0 :type integer)
  (description "" :type string)
  (up nil :type (or null function))
  (down nil :type (or null function)))

(defvar *migrations* (make-hash-table :test 'equal)
  "Registry of migrations. Keys are module name strings, values are
lists of migration structs sorted by version.")

(defun migrations-for (module)
  "Return the list of registered migrations for MODULE, sorted by version."
  (gethash module *migrations*))

(defun register-migration (module version &key up down (description ""))
  "Register a migration for MODULE at VERSION."
  (let ((mig (make-migration :module module
                             :version version
                             :description description
                             :up up
                             :down down))
        (existing (gethash module *migrations*)))
    (when (find version existing :key #'migration-version)
      (setf existing (remove version existing :key #'migration-version)))
    (setf (gethash module *migrations*)
          (sort (cons mig existing) #'< :key #'migration-version))))

(defmacro define-migration (module version &key up down (description ""))
  "Define a migration for MODULE at VERSION.
UP is a function to apply the migration.
DOWN is an optional function to reverse it."
  `(register-migration ,module ,version
                       :up ,up
                       :down ,down
                       :description ,description))

(defun clear-migrations (&optional module)
  "Clear registered migrations. If MODULE is given, clear only that module."
  (if module
      (remhash module *migrations*)
      (clrhash *migrations*)))

;;; -------------------------------------------------------
;;; Version tracking table
;;; -------------------------------------------------------

(defparameter *table* "fluxion_migrations"
  "Database table for tracking applied migrations.")

(defun setup ()
  "Create the migrations tracking table. Idempotent."
  (db:create *table*
             '((module :text)
               (version :integer)
               (description :text)
               (applied_at :bigint))
             :if-exists :ignore))

(defun applied-versions (module)
  "Return a sorted list of version numbers that have been applied for MODULE."
  (let ((rows (db:select *table*
                          (db:compile-query `(:= module ,module))
                          :sort '((version . :asc)))))
    (mapcar (lambda (row)
              (let ((v (cdr (assoc "version" row :test #'string=))))
                (if (stringp v) (parse-integer v) v)))
            rows)))

(defun record-applied (module version description)
  "Record that a migration has been applied."
  (db:insert *table*
             `(("module" . ,module)
               ("version" . ,version)
               ("description" . ,description)
               ("applied_at" . ,(get-universal-time)))))

(defun record-removed (module version)
  "Remove the record of an applied migration."
  (db:remove *table*
             (db:compile-query
              `(:and (:= module ,module)
                     (:= version ,version)))))

;;; -------------------------------------------------------
;;; Query API
;;; -------------------------------------------------------

(defun current-version (module)
  "Return the highest applied migration version for MODULE, or 0."
  (let ((versions (applied-versions module)))
    (if versions
        (reduce #'max versions)
        0)))

(defun pending (module)
  "Return a list of migration structs that have not yet been applied."
  (let ((applied (applied-versions module))
        (all (migrations-for module)))
    (remove-if (lambda (mig)
                 (member (migration-version mig) applied))
               all)))

(defun history (module)
  "Return the migration history for MODULE as an alist of rows."
  (db:select *table*
             (db:compile-query `(:= module ,module))
             :sort '((version . :asc))))

;;; -------------------------------------------------------
;;; Execution
;;; -------------------------------------------------------

(define-condition migration-error (error)
  ((module :initarg :module :reader migration-error-module)
   (version :initarg :version :reader migration-error-version)
   (direction :initarg :direction :reader migration-error-direction)
   (cause :initarg :cause :reader migration-error-cause))
  (:report (lambda (c stream)
             (format stream "Migration ~A v~D (~A) failed: ~A"
                     (migration-error-module c)
                     (migration-error-version c)
                     (migration-error-direction c)
                     (migration-error-cause c)))))

(defun migrate (module &key (to nil))
  "Run all pending migrations for MODULE in version order.
If TO is specified, only run up to and including that version.
Returns the number of migrations applied."
  (let ((pending-migs (pending module))
        (count 0))
    (when to
      (setf pending-migs
            (remove-if (lambda (mig) (> (migration-version mig) to))
                       pending-migs)))
    (dolist (mig pending-migs)
      (let ((up-fn (migration-up mig)))
        (unless up-fn
          (error 'migration-error
                 :module module
                 :version (migration-version mig)
                 :direction :up
                 :cause "No :up function defined"))
        (handler-case
            (progn
              (funcall up-fn)
              (record-applied module
                              (migration-version mig)
                              (migration-description mig))
              (incf count))
          (error (e)
            (error 'migration-error
                   :module module
                   :version (migration-version mig)
                   :direction :up
                   :cause e)))))
    count))

(defun rollback (module &key (steps 1))
  "Roll back the last STEPS applied migrations for MODULE.
Returns the number of migrations rolled back."
  (let* ((applied (reverse (applied-versions module)))
         (to-rollback (subseq applied 0 (min steps (length applied))))
         (all (migrations-for module))
         (count 0))
    (dolist (version to-rollback)
      (let ((mig (find version all :key #'migration-version)))
        (unless mig
          (error 'migration-error
                 :module module :version version :direction :down
                 :cause "Migration not found in registry"))
        (let ((down-fn (migration-down mig)))
          (unless down-fn
            (error 'migration-error
                   :module module :version version :direction :down
                   :cause "No :down function defined"))
          (handler-case
              (progn
                (funcall down-fn)
                (record-removed module version)
                (incf count))
            (error (e)
              (error 'migration-error
                     :module module :version version :direction :down
                     :cause e))))))
    count))

(defun rollback-to (module target-version)
  "Roll back all migrations for MODULE above TARGET-VERSION.
Returns the number of migrations rolled back."
  (let* ((current (current-version module))
         (applied (reverse (applied-versions module)))
         (to-rollback (remove-if (lambda (v) (<= v target-version)) applied))
         (all (migrations-for module))
         (count 0))
    (declare (ignore current))
    (dolist (version to-rollback)
      (let ((mig (find version all :key #'migration-version)))
        (unless mig
          (error 'migration-error
                 :module module :version version :direction :down
                 :cause "Migration not found in registry"))
        (let ((down-fn (migration-down mig)))
          (unless down-fn
            (error 'migration-error
                   :module module :version version :direction :down
                   :cause "No :down function defined"))
          (handler-case
              (progn
                (funcall down-fn)
                (record-removed module version)
                (incf count))
            (error (e)
              (error 'migration-error
                     :module module :version version :direction :down
                     :cause e))))))
    count))
