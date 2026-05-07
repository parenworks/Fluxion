;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - SQLite Backend
;;;;
;;;; Zero-configuration database backend using SQLite.
;;;; Suitable for development, testing, and single-process deployments.

(defpackage #:fluxion.db.sqlite
  (:use #:cl)
  (:local-nicknames (#:db #:fluxion.db)
                    (#:q #:fluxion.db.query))
  (:export
   #:sqlite-backend
   #:make-sqlite-backend))

(in-package #:fluxion.db.sqlite)

;;; -------------------------------------------------------
;;; Backend class
;;; -------------------------------------------------------

(defclass sqlite-backend (db:backend)
  ((database :initarg :database
             :initform ":memory:"
             :accessor backend-database
             :documentation "Path to SQLite database file, or \":memory:\" for in-memory.")
   (handle :initform nil
           :accessor backend-handle
           :documentation "Active SQLite connection handle."))
  (:documentation "SQLite database backend for Fluxion."))

(defun make-sqlite-backend (&key (database ":memory:"))
  "Create a new SQLite backend. DATABASE is a file path or \":memory:\"."
  (make-instance 'sqlite-backend :database database))

;;; -------------------------------------------------------
;;; Connection
;;; -------------------------------------------------------

(defmethod db:connect ((backend sqlite-backend) &key database)
  (when database
    (setf (backend-database backend) database))
  (when (backend-handle backend)
    (warn 'db:connection-already-open)
    (return-from db:connect backend))
  (handler-case
      (let ((handle (sqlite:connect (backend-database backend))))
        ;; Enable WAL mode for better concurrency
        (sqlite:execute-non-query handle "PRAGMA journal_mode=WAL")
        ;; Enable foreign keys
        (sqlite:execute-non-query handle "PRAGMA foreign_keys=ON")
        (setf (backend-handle backend) handle)
        (setf db:*backend* backend)
        backend)
    (error (e)
      (error 'db:connection-failed
             :message (format nil "SQLite connection to ~A failed: ~A"
                              (backend-database backend) e)))))

(defmethod db:disconnect ((backend sqlite-backend))
  (when (backend-handle backend)
    (sqlite:disconnect (backend-handle backend))
    (setf (backend-handle backend) nil))
  (when (eq db:*backend* backend)
    (setf db:*backend* nil)))

(defmethod db:connected-p ((backend sqlite-backend))
  (not (null (backend-handle backend))))

(defun %handle (backend)
  "Return the active SQLite handle or signal an error."
  (or (backend-handle backend)
      (error 'db:connection-failed :message "SQLite backend not connected")))

;;; -------------------------------------------------------
;;; SQL execution helpers
;;; -------------------------------------------------------

(defun %execute (backend sql &optional params)
  "Execute a non-query SQL statement with parameters."
  (let ((handle (%handle backend)))
    (if params
        (let ((stmt (sqlite:prepare-statement handle sql)))
          (unwind-protect
               (progn
                 (loop for param in params
                       for i from 1
                       do (sqlite:bind-parameter stmt i (coerce-param param)))
                 (sqlite:step-statement stmt))
            (sqlite:finalize-statement stmt)))
        (sqlite:execute-non-query handle sql))))

(defun %query-rows (backend sql &optional params)
  "Execute a query and return results as a list of alists."
  (let* ((handle (%handle backend))
         (stmt (sqlite:prepare-statement handle sql)))
    (unwind-protect
         (progn
           (when params
             (loop for param in params
                   for i from 1
                   do (sqlite:bind-parameter stmt i (coerce-param param))))
           (let ((columns nil)
                 (rows nil))
             (loop while (sqlite:step-statement stmt)
                   do (progn
                        (unless columns
                          (setf columns (sqlite:statement-column-names stmt)))
                        (let ((row nil))
                          (loop for i from 0 below (length columns)
                                for col-name in columns
                                do (push (cons col-name
                                               (sqlite:statement-column-value stmt i))
                                         row))
                          (push (nreverse row) rows))))
             (nreverse rows)))
      (sqlite:finalize-statement stmt))))

(defun %last-insert-id (backend)
  "Return the last inserted row ID."
  (sqlite:last-insert-rowid (%handle backend)))

(defun coerce-param (value)
  "Coerce a Lisp value to a SQLite-compatible parameter.
Booleans become 0/1. NIL becomes :null."
  (cond
    ((null value) :null)
    ((eq value t) 1)
    ((eq value nil) 0)
    (t value)))

;;; -------------------------------------------------------
;;; Collection management
;;; -------------------------------------------------------

(defmethod db:%collections ((backend sqlite-backend))
  (let ((rows (%query-rows backend
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")))
    (mapcar (lambda (row) (cdr (first row))) rows)))

(defmethod db:%collection-exists-p ((backend sqlite-backend) name)
  (let ((rows (%query-rows backend
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
                (list name))))
    (not (null rows))))

(defmethod db:%create ((backend sqlite-backend) name structure &key (if-exists :error))
  (when (db:%collection-exists-p backend name)
    (ecase if-exists
      (:error (error 'db:collection-already-exists :name name
                     :message "Collection already exists"))
      (:ignore (return-from db:%create nil))))
  (let ((sql (q:compile-create-table name structure)))
    (%execute backend sql)))

(defmethod db:%drop ((backend sqlite-backend) name)
  (unless (db:%collection-exists-p backend name)
    (error 'db:invalid-collection :name name
           :message "Collection does not exist"))
  (%execute backend (format nil "DROP TABLE ~A" (q:quote-identifier name))))

(defmethod db:%empty ((backend sqlite-backend) name)
  (%execute backend (format nil "DELETE FROM ~A" (q:quote-identifier name))))

(defmethod db:%alter ((backend sqlite-backend) name structure)
  (let* ((current (db:%collection-structure backend name))
         (current-names (mapcar (lambda (s) (string-downcase (first s))) current))
         (new-cols (remove-if (lambda (spec)
                                (member (string-downcase
                                         (q:field-name-sql (first spec)))
                                        current-names :test #'string=))
                              structure)))
    (when new-cols
      (dolist (sql (q:compile-alter-table name new-cols))
        (%execute backend sql)))))

(defmethod db:%collection-structure ((backend sqlite-backend) name)
  (let ((rows (%query-rows backend
                (format nil "PRAGMA table_info(~A)" (q:quote-identifier name)))))
    (mapcar (lambda (row)
              (list (cdr (assoc "name" row :test #'string=))
                    (sql-type-to-keyword (cdr (assoc "type" row :test #'string=)))))
            ;; Skip _id column
            (remove-if (lambda (row)
                         (string= "_id" (cdr (assoc "name" row :test #'string=))))
                       rows))))

(defun sql-type-to-keyword (sql-type)
  "Convert a SQL type string back to a Fluxion field-type keyword."
  (let ((up (string-upcase sql-type)))
    (cond
      ((string= up "TEXT") :text)
      ((string= up "INTEGER") :integer)
      ((string= up "REAL") :float)
      (t :text))))

;;; -------------------------------------------------------
;;; Data operations
;;; -------------------------------------------------------

(defmethod db:%insert ((backend sqlite-backend) collection data)
  (let ((compiled (q:compile-insert collection data)))
    (%execute backend (car compiled) (cdr compiled))
    (%last-insert-id backend)))

(defmethod db:%select ((backend sqlite-backend) collection query
                        &key fields skip amount sort unique)
  (let ((compiled (q:compile-select collection query
                                    :fields fields :skip skip
                                    :amount amount :sort sort
                                    :unique unique)))
    (%query-rows backend (car compiled) (cdr compiled))))

(defmethod db:%count ((backend sqlite-backend) collection query)
  (let* ((where-sql (car query))
         (where-params (cdr query))
         (sql (format nil "SELECT COUNT(*) AS \"count\" FROM ~A WHERE ~A"
                      (q:quote-identifier collection) where-sql))
         (rows (%query-rows backend sql where-params)))
    (if rows
        (cdr (first (first rows)))
        0)))

(defmethod db:%update ((backend sqlite-backend) collection query data
                        &key skip amount sort)
  (declare (ignore skip amount sort))
  (let ((compiled (q:compile-update collection query data)))
    (%execute backend (car compiled) (cdr compiled))))

(defmethod db:%remove ((backend sqlite-backend) collection query
                        &key skip amount sort)
  (declare (ignore skip amount sort))
  (let ((compiled (q:compile-delete collection query)))
    (%execute backend (car compiled) (cdr compiled))))

(defmethod db:%iterate ((backend sqlite-backend) collection query function
                         &key fields skip amount sort unique)
  (let ((rows (db:%select backend collection query
                          :fields fields :skip skip :amount amount
                          :sort sort :unique unique)))
    (dolist (row rows)
      (funcall function row))))

(defmethod db:%execute-transaction ((backend sqlite-backend) thunk)
  (let ((handle (%handle backend)))
    (sqlite:execute-non-query handle "BEGIN")
    (handler-case
        (prog1 (funcall thunk)
          (sqlite:execute-non-query handle "COMMIT"))
      (error (e)
        (sqlite:execute-non-query handle "ROLLBACK")
        (error e)))))
