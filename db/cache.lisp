;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Caching interface
;;;;
;;;; Named cache entries with invalidation and TTL-based expiration.
;;;; Supports multiple backends: in-memory (default), database.
;;;;
;;;; Usage:
;;;;   (cache:with-cache (:user-list 60)
;;;;     (expensive-user-query))
;;;;
;;;;   (cache:get :user-list)
;;;;   (cache:renew :user-list)

(defpackage #:fluxion.cache
  (:use #:cl)
  (:shadow #:get #:remove)
  (:export
   ;; Backend protocol
   #:cache-backend
   #:cache-get
   #:cache-put
   #:cache-remove
   #:cache-clear
   #:cache-exists-p
   ;; Memory backend
   #:memory-cache-backend
   #:make-memory-cache-backend
   ;; DB backend
   #:db-cache-backend
   #:make-db-cache-backend
   #:setup
   ;; High-level API
   #:*backend*
   #:get
   #:put
   #:remove
   #:renew
   #:clear
   #:exists-p
   #:with-cache
   #:gc-expired))

(in-package #:fluxion.cache)

;;; -------------------------------------------------------
;;; Cache entry
;;; -------------------------------------------------------

(defstruct cache-entry
  "A cached value with metadata."
  (value nil)
  (created-at (get-universal-time) :type integer)
  (ttl nil :type (or null integer)))

(defun entry-expired-p (entry)
  "Return T if ENTRY has a TTL and is past its expiration."
  (when (cache-entry-ttl entry)
    (> (get-universal-time)
       (+ (cache-entry-created-at entry)
          (cache-entry-ttl entry)))))

;;; -------------------------------------------------------
;;; Backend protocol
;;; -------------------------------------------------------

(defclass cache-backend () ()
  (:documentation "Abstract base class for cache backends."))

(defgeneric cache-get (backend name &optional variant)
  (:documentation "Retrieve a cached entry for NAME and optional VARIANT.
Returns the cache-entry struct or NIL."))

(defgeneric cache-put (backend name value &key variant ttl)
  (:documentation "Store VALUE under NAME with optional VARIANT and TTL (seconds)."))

(defgeneric cache-remove (backend name &optional variant)
  (:documentation "Remove the cache entry for NAME and optional VARIANT."))

(defgeneric cache-clear (backend)
  (:documentation "Remove all cache entries."))

(defgeneric cache-exists-p (backend name &optional variant)
  (:documentation "Return T if a non-expired entry exists for NAME and optional VARIANT."))

(defgeneric cache-gc (backend)
  (:documentation "Remove all expired entries. Returns count removed."))

;;; -------------------------------------------------------
;;; Memory backend
;;; -------------------------------------------------------

(defclass memory-cache-backend (cache-backend)
  ((store :initform (make-hash-table :test 'equal)
          :reader backend-store)
   (lock :initform (bordeaux-threads:make-lock "cache-lock")
         :reader backend-lock))
  (:documentation "In-memory cache backend using a hash table."))

(defun make-memory-cache-backend ()
  "Create a new in-memory cache backend."
  (make-instance 'memory-cache-backend))

(defun cache-key (name &optional variant)
  "Build a hash key from NAME and optional VARIANT."
  (if variant
      (cons name variant)
      name))

(defmethod cache-get ((backend memory-cache-backend) name &optional variant)
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (let ((entry (gethash (cache-key name variant) (backend-store backend))))
      (when entry
        (if (entry-expired-p entry)
            (progn
              (remhash (cache-key name variant) (backend-store backend))
              nil)
            entry)))))

(defmethod cache-put ((backend memory-cache-backend) name value &key variant ttl)
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (setf (gethash (cache-key name variant) (backend-store backend))
          (make-cache-entry :value value :ttl ttl))))

(defmethod cache-remove ((backend memory-cache-backend) name &optional variant)
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (remhash (cache-key name variant) (backend-store backend))))

(defmethod cache-clear ((backend memory-cache-backend))
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (clrhash (backend-store backend))))

(defmethod cache-exists-p ((backend memory-cache-backend) name &optional variant)
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (let ((entry (gethash (cache-key name variant) (backend-store backend))))
      (and entry (not (entry-expired-p entry))))))

(defmethod cache-gc ((backend memory-cache-backend))
  (bordeaux-threads:with-lock-held ((backend-lock backend))
    (let ((removed 0)
          (now (get-universal-time)))
      (maphash (lambda (key entry)
                 (when (and (cache-entry-ttl entry)
                            (> now (+ (cache-entry-created-at entry)
                                      (cache-entry-ttl entry))))
                   (remhash key (backend-store backend))
                   (incf removed)))
               (backend-store backend))
      removed)))

;;; -------------------------------------------------------
;;; DB backend
;;; -------------------------------------------------------

(defclass db-cache-backend (cache-backend)
  ((table-name :initarg :table-name
               :initform "fluxion_cache"
               :reader backend-table-name))
  (:documentation "Database-backed cache using fluxion.db."))

(defun make-db-cache-backend (&key (table-name "fluxion_cache"))
  "Create a database-backed cache backend."
  (make-instance 'db-cache-backend :table-name table-name))

(defun setup (&optional (backend *backend*))
  "Create the cache table if it does not exist. Idempotent."
  (when (typep backend 'db-cache-backend)
    (fluxion.db:create (backend-table-name backend)
                       '((name :text)
                         (variant :text)
                         (value :text)
                         (created_at :integer)
                         (ttl :integer))
                       :if-exists :ignore)))

(defun db-key-query (backend name &optional variant)
  "Build a query for NAME and optional VARIANT."
  (let ((table (backend-table-name backend)))
    (declare (ignore table))
    (if variant
        (fluxion.db:compile-query
         `(:and (:= name ,(princ-to-string name))
                (:= variant ,(princ-to-string variant))))
        (fluxion.db:compile-query
         `(:and (:= name ,(princ-to-string name))
                (:= variant ""))))))

(defmethod cache-get ((backend db-cache-backend) name &optional variant)
  (let* ((query (db-key-query backend name variant))
         (row (fluxion.db:select-one (backend-table-name backend) query)))
    (when row
      (let ((ttl-val (cdr (assoc "ttl" row :test #'string=)))
            (created (cdr (assoc "created_at" row :test #'string=))))
        (let ((ttl (and ttl-val (not (zerop ttl-val)) ttl-val)))
          (if (and ttl (> (get-universal-time) (+ created ttl)))
              (progn
                (fluxion.db:remove (backend-table-name backend) query)
                nil)
              (make-cache-entry
               :value (cdr (assoc "value" row :test #'string=))
               :created-at created
               :ttl ttl)))))))

(defmethod cache-put ((backend db-cache-backend) name value &key variant ttl)
  (let ((query (db-key-query backend name variant))
        (name-str (princ-to-string name))
        (variant-str (if variant (princ-to-string variant) ""))
        (value-str (princ-to-string value)))
    ;; Upsert: remove then insert
    (fluxion.db:remove (backend-table-name backend) query)
    (fluxion.db:insert (backend-table-name backend)
                       `(("name" . ,name-str)
                         ("variant" . ,variant-str)
                         ("value" . ,value-str)
                         ("created_at" . ,(get-universal-time))
                         ("ttl" . ,(or ttl 0))))))

(defmethod cache-remove ((backend db-cache-backend) name &optional variant)
  (fluxion.db:remove (backend-table-name backend)
                     (db-key-query backend name variant)))

(defmethod cache-clear ((backend db-cache-backend))
  (fluxion.db:empty (backend-table-name backend)))

(defmethod cache-exists-p ((backend db-cache-backend) name &optional variant)
  (not (null (cache-get backend name variant))))

(defmethod cache-gc ((backend db-cache-backend))
  (let* ((now (get-universal-time))
         (query (fluxion.db:compile-query '(:> ttl 0)))
         (rows (fluxion.db:select (backend-table-name backend) query))
         (removed 0))
    (dolist (row rows)
      (let ((created (cdr (assoc "created_at" row :test #'string=)))
            (ttl (cdr (assoc "ttl" row :test #'string=)))
            (id (cdr (assoc "_id" row :test #'string=))))
        (when (and created ttl (> now (+ created ttl)))
          (fluxion.db:remove (backend-table-name backend)
                             (fluxion.db:compile-query `(:= _id ,id)))
          (incf removed))))
    removed))

;;; -------------------------------------------------------
;;; High-level API
;;; -------------------------------------------------------

(defvar *backend* (make-memory-cache-backend)
  "The currently active cache backend.")

(defun get (name &optional variant)
  "Retrieve the cached value for NAME (and optional VARIANT).
Returns the value and T as second value if found, or NIL NIL if not cached."
  (let ((entry (cache-get *backend* name variant)))
    (if entry
        (values (cache-entry-value entry) t)
        (values nil nil))))

(defun put (name value &key variant ttl)
  "Store VALUE under NAME with optional VARIANT and TTL (seconds).
Returns VALUE."
  (cache-put *backend* name value :variant variant :ttl ttl)
  value)

(defun remove (name &optional variant)
  "Remove the cached entry for NAME (and optional VARIANT)."
  (cache-remove *backend* name variant))

(defun renew (name &optional variant)
  "Invalidate the cached entry for NAME (and optional VARIANT).
Alias for REMOVE."
  (cache-remove *backend* name variant))

(defun clear ()
  "Remove all cache entries."
  (cache-clear *backend*))

(defun exists-p (name &optional variant)
  "Return T if a non-expired cache entry exists for NAME."
  (cache-exists-p *backend* name variant))

(defun gc-expired ()
  "Remove all expired cache entries. Returns count removed."
  (cache-gc *backend*))

(defmacro with-cache ((name &optional ttl variant) &body body)
  "Execute BODY and cache the result under NAME.
If a valid cached value exists, return it without executing BODY.
TTL is the time-to-live in seconds (NIL = no expiry).
VARIANT allows multiple cached values under the same NAME."
  (let ((v (gensym "VARIANT"))
        (entry (gensym "ENTRY")))
    `(let* ((,v ,variant)
            (,entry (cache-get *backend* ,name ,v)))
       (if (and ,entry (not (entry-expired-p ,entry)))
           (cache-entry-value ,entry)
           (let ((result (progn ,@body)))
             (cache-put *backend* ,name result :variant ,v :ttl ,ttl)
             result)))))
