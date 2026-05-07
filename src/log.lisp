;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Logging interface
;;;;
;;;; Structured, leveled logging with swappable backends and
;;;; category-based filtering.
;;;;
;;;; Levels (ascending severity):
;;;;   :trace :debug :info :warn :error :severe :fatal
;;;;
;;;; Usage:
;;;;   (log:info "Server started on port ~D" 5000)
;;;;   (log:warn "Session ~A expired" sid :category :session)
;;;;   (log:error "Database connection failed" :category :db)

(defpackage #:fluxion.log
  (:use #:cl)
  (:shadow #:log #:error #:warn #:trace #:debug)
  (:export
   ;; Levels
   #:+levels+
   #:level-value
   ;; Core logging
   #:log
   #:trace
   #:debug
   #:info
   #:warn
   #:error
   #:severe
   #:fatal
   ;; Configuration
   #:*level*
   #:*backend*
   #:*category-levels*
   #:*timestamp-format*
   #:set-category-level
   ;; Backend protocol
   #:log-backend
   #:backend-write
   ;; Backends
   #:stream-log-backend
   #:make-stream-log-backend
   #:file-log-backend
   #:make-file-log-backend
   #:null-log-backend
   #:make-null-log-backend
   #:multi-log-backend
   #:make-multi-log-backend
   ;; Log entry
   #:log-entry
   #:entry-level
   #:entry-category
   #:entry-message
   #:entry-timestamp
   #:entry-data))

(in-package #:fluxion.log)

;;; -------------------------------------------------------
;;; Levels
;;; -------------------------------------------------------

(defparameter +levels+
  '(:trace :debug :info :warn :error :severe :fatal)
  "Log levels in ascending severity order.")

(defun level-value (level)
  "Return the numeric severity of LEVEL. Higher = more severe."
  (or (position level +levels+)
      (cl:error "Unknown log level: ~S" level)))

;;; -------------------------------------------------------
;;; Log entry
;;; -------------------------------------------------------

(defstruct log-entry
  "A structured log entry."
  (level :info :type keyword)
  (category nil :type (or null keyword))
  (message "" :type string)
  (timestamp (get-universal-time) :type integer)
  (data nil :type list))

;;; -------------------------------------------------------
;;; Configuration
;;; -------------------------------------------------------

(defvar *level* :info
  "Minimum log level. Messages below this level are suppressed.")

(defvar *category-levels* (make-hash-table :test 'eq)
  "Per-category minimum log levels. Overrides *level* for specific categories.")

(defvar *timestamp-format*
  '(:year #\- :month #\- :day #\Space :hour #\: :min #\: :sec)
  "Timestamp format specification.")

(defun set-category-level (category level)
  "Set the minimum log level for a specific CATEGORY.
Pass NIL as LEVEL to remove the override."
  (if level
      (setf (gethash category *category-levels*) level)
      (remhash category *category-levels*)))

(defun effective-level (category)
  "Return the effective minimum level for CATEGORY."
  (if category
      (or (gethash category *category-levels*) *level*)
      *level*))

(defun level-enabled-p (level category)
  "Return T if LEVEL meets the threshold for CATEGORY."
  (>= (level-value level) (level-value (effective-level category))))

;;; -------------------------------------------------------
;;; Timestamp formatting
;;; -------------------------------------------------------

(defun format-timestamp (universal-time)
  "Format UNIVERSAL-TIME as a human-readable string."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time)
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

;;; -------------------------------------------------------
;;; Backend protocol
;;; -------------------------------------------------------

(defclass log-backend () ()
  (:documentation "Abstract base class for log backends."))

(defgeneric backend-write (backend entry)
  (:documentation "Write a log entry to the backend."))

;;; -------------------------------------------------------
;;; Stream backend
;;; -------------------------------------------------------

(defclass stream-log-backend (log-backend)
  ((stream :initarg :stream
           :initform *standard-output*
           :reader backend-stream)
   (lock :initform (bordeaux-threads:make-lock "log-lock")
         :reader backend-lock))
  (:documentation "Log backend that writes formatted text to a stream."))

(defun make-stream-log-backend (&key (stream *standard-output*))
  "Create a stream log backend."
  (make-instance 'stream-log-backend :stream stream))

(defmethod backend-write ((backend stream-log-backend) entry)
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (let ((stream (backend-stream backend)))
      (format stream "[~A] [~A]~@[ [~(~A~)]~] ~A~%"
              (format-timestamp (log-entry-timestamp entry))
              (string-upcase (symbol-name (log-entry-level entry)))
              (log-entry-category entry)
              (log-entry-message entry))
      (when (log-entry-data entry)
        (loop for (k v) on (log-entry-data entry) by #'cddr
              do (format stream "  ~(~A~): ~A~%" k v)))
      (force-output stream))))

;;; -------------------------------------------------------
;;; File backend (with rotation)
;;; -------------------------------------------------------

(defclass file-log-backend (log-backend)
  ((path :initarg :path
         :reader backend-path)
   (max-size :initarg :max-size
             :initform (* 10 1024 1024)
             :reader backend-max-size)
   (max-files :initarg :max-files
              :initform 5
              :reader backend-max-files)
   (lock :initform (bordeaux-threads:make-lock "file-log-lock")
         :reader backend-lock)
   (stream :initform nil
           :accessor backend-file-stream))
  (:documentation "Log backend that writes to a file with size-based rotation."))

(defun make-file-log-backend (path &key (max-size (* 10 1024 1024))
                                         (max-files 5))
  "Create a file log backend.
PATH is the log file path.
MAX-SIZE is the maximum file size before rotation (default 10MB).
MAX-FILES is the number of rotated files to keep (default 5)."
  (make-instance 'file-log-backend
                 :path path :max-size max-size :max-files max-files))

(defun ensure-file-stream (backend)
  "Ensure the file stream is open."
  (unless (and (backend-file-stream backend)
               (open-stream-p (backend-file-stream backend)))
    (setf (backend-file-stream backend)
          (open (backend-path backend)
                :direction :output
                :if-exists :append
                :if-does-not-exist :create
                :external-format :utf-8))))

(defun rotate-if-needed (backend)
  "Rotate the log file if it exceeds max-size."
  (when (and (backend-file-stream backend)
             (open-stream-p (backend-file-stream backend)))
    (let ((pos (file-position (backend-file-stream backend))))
      (when (and pos (> pos (backend-max-size backend)))
        (close (backend-file-stream backend))
        (setf (backend-file-stream backend) nil)
        ;; Rotate files: foo.log.4 -> deleted, foo.log.3 -> foo.log.4, etc.
        (let ((path (backend-path backend)))
          (loop for i from (1- (backend-max-files backend)) downto 1
                do (let ((from (format nil "~A.~D" path i))
                         (to (format nil "~A.~D" path (1+ i))))
                     (when (probe-file from)
                       (rename-file from to))))
          (when (probe-file path)
            (rename-file path (format nil "~A.1" path))))
        (ensure-file-stream backend)))))

(defmethod backend-write ((backend file-log-backend) entry)
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (ensure-file-stream backend)
    (let ((stream (backend-file-stream backend)))
      (format stream "[~A] [~A]~@[ [~(~A~)]~] ~A~%"
              (format-timestamp (log-entry-timestamp entry))
              (string-upcase (symbol-name (log-entry-level entry)))
              (log-entry-category entry)
              (log-entry-message entry))
      (when (log-entry-data entry)
        (loop for (k v) on (log-entry-data entry) by #'cddr
              do (format stream "  ~(~A~): ~A~%" k v)))
      (force-output stream))
    (rotate-if-needed backend)))

;;; -------------------------------------------------------
;;; Null backend
;;; -------------------------------------------------------

(defclass null-log-backend (log-backend) ()
  (:documentation "Log backend that discards all messages."))

(defun make-null-log-backend ()
  "Create a null log backend."
  (make-instance 'null-log-backend))

(defmethod backend-write ((backend null-log-backend) entry)
  (declare (ignore entry))
  nil)

;;; -------------------------------------------------------
;;; Multi backend (fan-out)
;;; -------------------------------------------------------

(defclass multi-log-backend (log-backend)
  ((backends :initarg :backends
             :initform '()
             :reader backend-list))
  (:documentation "Log backend that writes to multiple backends."))

(defun make-multi-log-backend (&rest backends)
  "Create a multi backend that fans out to all given backends."
  (make-instance 'multi-log-backend :backends backends))

(defmethod backend-write ((backend multi-log-backend) entry)
  (dolist (b (backend-list backend))
    (backend-write b entry)))

;;; -------------------------------------------------------
;;; Core logging
;;; -------------------------------------------------------

(defvar *backend* (make-stream-log-backend)
  "The currently active log backend.")

(defun log (level message &key category data)
  "Log a message at LEVEL.
CATEGORY is an optional keyword for filtering.
DATA is a plist of structured key-value pairs."
  (when (level-enabled-p level category)
    (let ((entry (make-log-entry
                  :level level
                  :category category
                  :message message
                  :data data)))
      (backend-write *backend* entry)))
  (values))

;;; -------------------------------------------------------
;;; Convenience functions
;;; -------------------------------------------------------

(defmacro define-level-fn (name level)
  `(defun ,name (format-string &rest args)
     ,(format nil "Log a message at ~A level.~%The last keyword arguments :category and :data are extracted if present."
              (string-upcase (symbol-name level)))
     (multiple-value-bind (fmt-args category data)
         (extract-log-args args)
       (log ,level (apply #'format nil format-string fmt-args)
            :category category :data data))))

(defun extract-log-args (args)
  "Extract :category and :data keyword args from the tail of ARGS.
Returns (values format-args category data)."
  (let ((category nil)
        (data nil)
        (fmt-args '())
        (rest args))
    (loop while rest do
      (cond
        ((and (eq (car rest) :category) (cdr rest))
         (setf category (cadr rest))
         (setf rest (cddr rest)))
        ((and (eq (car rest) :data) (cdr rest))
         (setf data (cadr rest))
         (setf rest (cddr rest)))
        (t
         (push (car rest) fmt-args)
         (setf rest (cdr rest)))))
    (values (nreverse fmt-args) category data)))

(define-level-fn trace :trace)
(define-level-fn debug :debug)
(define-level-fn info :info)
(define-level-fn warn :warn)
(define-level-fn error :error)
(define-level-fn severe :severe)
(define-level-fn fatal :fatal)
