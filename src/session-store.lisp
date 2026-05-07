;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Session persistence
;;;;
;;;; Pluggable session storage backends. Sessions are always held in memory
;;;; for fast access; the store provides persistence across server restarts.
;;;;
;;;; Backends:
;;;;   memory-session-store  - No persistence (default, current behaviour)
;;;;   db-session-store      - Persist to any fluxion.db backend
;;;;
;;;; The store protocol:
;;;;   store-session      - Write a session to persistent storage
;;;;   load-session       - Read a session from persistent storage by ID
;;;;   delete-session     - Remove a session from persistent storage
;;;;   load-all-sessions  - Load all non-expired sessions (for server restart)
;;;;   gc-sessions        - Remove expired sessions from storage
;;;;   store-setup        - One-time initialization (create tables, etc.)

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Session store protocol
;;; -------------------------------------------------------

(defgeneric store-session (store session)
  (:documentation
   "Persist SESSION to the backing store. Called on session creation
and periodically on mutation (touch, auth changes)."))

(defgeneric load-session (store session-id)
  (:documentation
   "Load a session by ID from the backing store.
Returns a SESSION instance or NIL if not found.
Components and event queues are not restored (they are runtime-only)."))

(defgeneric delete-session (store session-id)
  (:documentation
   "Remove a session from the backing store.
Called when a session is reaped or explicitly invalidated."))

(defgeneric load-all-sessions (store)
  (:documentation
   "Load all sessions from the backing store.
Used on server restart to restore active sessions.
Returns a list of SESSION instances."))

(defgeneric gc-sessions (store ttl)
  (:documentation
   "Remove sessions from the backing store that have not been accessed
within TTL seconds. Returns the number of sessions removed."))

(defgeneric store-setup (store)
  (:documentation
   "One-time initialization for the store (create tables, etc.).
Idempotent: safe to call multiple times."))

;;; -------------------------------------------------------
;;; Session serialization
;;; -------------------------------------------------------

(defun serialize-session (session)
  "Convert SESSION's persistent fields to an alist for storage.
Components and event queues are runtime-only and not serialized."
  (list (cons "id" (session-id session))
        (cons "created_at" (session-created-at session))
        (cons "last_accessed_at" (session-last-accessed-at session))
        (cons "csrf_token" (session-csrf-token session))
        (cons "user_data" (when (session-user session)
                            (prin1-to-string (session-user session))))
        (cons "user_roles" (when (session-user-roles session)
                             (prin1-to-string (session-user-roles session))))))

(defun deserialize-session (data)
  "Restore a SESSION from an alist of persistent fields.
DATA is an alist with string keys as returned by the store."
  (let ((session (make-instance 'session
                   :id (cdr (assoc "id" data :test #'string=)))))
    (let ((created (cdr (assoc "created_at" data :test #'string=))))
      (when created
        (setf (session-created-at session) created)))
    (let ((accessed (cdr (assoc "last_accessed_at" data :test #'string=))))
      (when accessed
        (setf (session-last-accessed-at session) accessed)))
    (let ((csrf (cdr (assoc "csrf_token" data :test #'string=))))
      (when csrf
        (setf (session-csrf-token session) csrf)))
    (let ((user-str (cdr (assoc "user_data" data :test #'string=))))
      (when (and user-str (plusp (length user-str)))
        (setf (session-user session)
              (read-from-string user-str))))
    (let ((roles-str (cdr (assoc "user_roles" data :test #'string=))))
      (when (and roles-str (plusp (length roles-str)))
        (setf (session-user-roles session)
              (read-from-string roles-str))))
    session))

;;; -------------------------------------------------------
;;; Memory session store (no persistence, default)
;;; -------------------------------------------------------

(defclass memory-session-store ()
  ()
  (:documentation "No-op session store. Sessions live only in memory.
This is the default and preserves existing behaviour."))

(defmethod store-setup ((store memory-session-store))
  nil)

(defmethod store-session ((store memory-session-store) session)
  (declare (ignore session))
  nil)

(defmethod load-session ((store memory-session-store) session-id)
  (declare (ignore session-id))
  nil)

(defmethod delete-session ((store memory-session-store) session-id)
  (declare (ignore session-id))
  nil)

(defmethod load-all-sessions ((store memory-session-store))
  nil)

(defmethod gc-sessions ((store memory-session-store) ttl)
  (declare (ignore ttl))
  0)
