;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Configuration system
;;;;
;;;; Per-module persistent configuration with s-expression storage,
;;;; environment support, defaults, and live reload.
;;;;
;;;; Usage:
;;;;   (config:define-section :database
;;;;     (:host "localhost")
;;;;     (:port 5432)
;;;;     (:name "myapp"))
;;;;
;;;;   (config:get :database :host)     ; => "localhost"
;;;;   (config:set :database :host "db.example.com")
;;;;   (config:save)
;;;;
;;;;   ;; Per-environment
;;;;   (setf config:*environment* :production)
;;;;   (config:load-file "config/production.lisp")

(defpackage #:fluxion.config
  (:use #:cl)
  (:shadow #:get #:set)
  (:export
   ;; Sections and defaults
   #:define-section
   #:undefine-section
   #:sections
   #:section-keys
   #:section-defaults
   ;; Get/set
   #:get
   #:set
   #:reset
   #:reset-section
   #:reset-all
   ;; Persistence
   #:load-file
   #:save
   #:save-to
   #:*config-path*
   ;; Environment
   #:*environment*
   #:environment-config-path
   ;; Introspection
   #:all-values
   #:section-values
   ;; Hooks
   #:*on-change*))

(in-package #:fluxion.config)

;;; -------------------------------------------------------
;;; Storage
;;; -------------------------------------------------------

(defvar *defaults* (make-hash-table :test 'eq)
  "Default values per section. Keys are section keywords,
values are alists of (key . default-value).")

(defvar *values* (make-hash-table :test 'eq)
  "Current configuration values. Same structure as *defaults*.")

(defvar *lock* (bordeaux-threads:make-lock "config-lock"))

;;; -------------------------------------------------------
;;; Environment
;;; -------------------------------------------------------

(defvar *environment* :development
  "Current environment name. Used to resolve config file paths.")

(defvar *config-path* nil
  "Path to the current configuration file. NIL means no persistence.")

(defun environment-config-path (base-dir &optional (env *environment*))
  "Return the config file path for ENV under BASE-DIR.
E.g. (environment-config-path \"config/\") => \"config/development.lisp\""
  (merge-pathnames (format nil "~(~A~).lisp" env)
                   (uiop:ensure-directory-pathname base-dir)))

;;; -------------------------------------------------------
;;; Sections and defaults
;;; -------------------------------------------------------

(defmacro define-section (section &body defaults)
  "Define a configuration section with default values.
SECTION is a keyword. DEFAULTS are (key value) pairs.

  (define-section :database
    (:host \"localhost\")
    (:port 5432))"
  (let ((pairs (mapcar (lambda (pair)
                         `(cons ,(first pair) ,(second pair)))
                       defaults)))
    `(%define-section ,section (list ,@pairs))))

(defun %define-section (section default-alist)
  "Internal function for define-section."
  (bordeaux-threads:with-lock-held (*lock*)
    (setf (gethash section *defaults*) default-alist)
    ;; Initialize values with defaults where not already set
    (let ((current (gethash section *values*)))
      (dolist (d default-alist)
        (unless (assoc (car d) current)
          (push (cons (car d) (cdr d)) current)))
      (setf (gethash section *values*) current)))
  section)

(defun undefine-section (section)
  "Remove a configuration section and its values."
  (bordeaux-threads:with-lock-held (*lock*)
    (remhash section *defaults*)
    (remhash section *values*)))

(defun sections ()
  "Return a list of all defined section names."
  (let ((result '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k result)) *defaults*)
    (sort result #'string< :key #'symbol-name)))

(defun section-keys (section)
  "Return a list of key names for SECTION."
  (bordeaux-threads:with-lock-held (*lock*)
    (mapcar #'car (or (gethash section *defaults*) '()))))

(defun section-defaults (section)
  "Return the default alist for SECTION."
  (bordeaux-threads:with-lock-held (*lock*)
    (copy-alist (gethash section *defaults*))))

;;; -------------------------------------------------------
;;; Get / Set
;;; -------------------------------------------------------

(defvar *on-change* nil
  "Hook function called after a value changes.
Receives (section key old-value new-value).")

(defun get (section key &optional default)
  "Get a configuration value. Falls back to section default, then DEFAULT."
  (bordeaux-threads:with-lock-held (*lock*)
    (let ((section-vals (gethash section *values*)))
      (if section-vals
          (let ((pair (assoc key section-vals)))
            (if pair
                (cdr pair)
                (let ((def-pair (assoc key (gethash section *defaults*))))
                  (if def-pair (cdr def-pair) default))))
          (let ((def-pair (assoc key (gethash section *defaults*))))
            (if def-pair (cdr def-pair) default))))))

(defun set (section key value)
  "Set a configuration value. Fires *on-change* if the value changes."
  (let ((old-value (get section key)))
    (bordeaux-threads:with-lock-held (*lock*)
      (let ((section-vals (gethash section *values*)))
        (let ((pair (assoc key section-vals)))
          (if pair
              (setf (cdr pair) value)
              (setf (gethash section *values*)
                    (cons (cons key value) section-vals))))))
    (when (and *on-change* (not (equal old-value value)))
      (funcall *on-change* section key old-value value)))
  value)

(defun reset (section key)
  "Reset a single key to its default value."
  (let ((def (cdr (assoc key (gethash section *defaults*)))))
    (set section key def)))

(defun reset-section (section)
  "Reset all keys in SECTION to their defaults."
  (bordeaux-threads:with-lock-held (*lock*)
    (setf (gethash section *values*)
          (copy-alist (or (gethash section *defaults*) '())))))

(defun reset-all ()
  "Reset all sections to their defaults."
  (bordeaux-threads:with-lock-held (*lock*)
    (maphash (lambda (section defaults)
               (setf (gethash section *values*) (copy-alist defaults)))
             *defaults*)))

;;; -------------------------------------------------------
;;; Introspection
;;; -------------------------------------------------------

(defun section-values (section)
  "Return the current values alist for SECTION."
  (bordeaux-threads:with-lock-held (*lock*)
    (copy-alist (gethash section *values*))))

(defun all-values ()
  "Return a plist of (section . alist) for all sections."
  (bordeaux-threads:with-lock-held (*lock*)
    (let ((result '()))
      (maphash (lambda (k v) (push (cons k (copy-alist v)) result)) *values*)
      result)))

;;; -------------------------------------------------------
;;; Persistence (s-expression files)
;;; -------------------------------------------------------

(defun load-file (path)
  "Load configuration from a Lisp file.
The file should contain s-expressions of the form:
  (:section-name (:key1 value1) (:key2 value2) ...)"
  (when (probe-file path)
    (with-open-file (in path :direction :input :external-format :utf-8)
      (let ((*read-eval* nil))
        (loop for form = (read in nil :eof)
              until (eq form :eof)
              do (when (and (listp form) (keywordp (car form)))
                   (let ((section (car form))
                         (pairs (cdr form)))
                     (dolist (pair pairs)
                       (when (and (listp pair) (>= (length pair) 2))
                         (set section (first pair) (second pair)))))))))
    (setf *config-path* path)
    t))

(defun serialize-config (stream)
  "Write the current configuration to STREAM as s-expressions."
  (maphash (lambda (section vals)
             (when vals
               (format stream "(~S~%" section)
               (dolist (pair vals)
                 (format stream "  (~S ~S)~%" (car pair) (cdr pair)))
               (format stream ")~%~%")))
           *values*))

(defun save-to (path)
  "Save the current configuration to PATH."
  (bordeaux-threads:with-lock-held (*lock*)
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :external-format :utf-8)
      (format out ";;;; Fluxion configuration - ~A~%" *environment*)
      (format out ";;;; Auto-generated. Edit with care.~%~%")
      (serialize-config out)))
  (setf *config-path* path)
  path)

(defun save ()
  "Save configuration to *config-path*. Signals an error if no path is set."
  (unless *config-path*
    (cl:error "No config path set. Use (save-to path) or set *config-path*."))
  (save-to *config-path*))
