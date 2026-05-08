;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Session class and management

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Current session (dynamic variable)
;;; -------------------------------------------------------

(defvar *current-session* nil
  "The session for the current request. Bound during request dispatch.")

;;; -------------------------------------------------------
;;; Session
;;; -------------------------------------------------------

(defgeneric session-id (session)
  (:documentation "Unique session identifier string (used as the cookie value)."))

(defgeneric session-components (session)
  (:documentation "Hash table of component instances for this session, keyed by component-id."))

(defgeneric session-event-queue (session)
  (:documentation "The SSE event queue for this session. Created on first /sse connection."))

(defgeneric session-csrf-token (session)
  (:documentation "The session's CSRF token string. Validated on every POST request."))

(defgeneric session-user (session)
  (:documentation "Application-defined user data. NIL when not authenticated."))

(defgeneric session-user-roles (session)
  (:documentation "List of role keywords for the authenticated user, e.g. (:admin :editor)."))

(defclass session ()
  ((id              :initarg :id
                    :accessor session-id
                    :type string)
   (components      :initform (make-hash-table :test 'equal)
                    :accessor session-components
                    :documentation "Component instances for this session, keyed by component-id.")
   (created-at      :initform (get-universal-time)
                    :accessor session-created-at)
   (last-accessed-at :initform (get-universal-time)
                     :accessor session-last-accessed-at
                     :documentation "Universal time of last request using this session.")
   (event-queue     :initform nil
                    :accessor session-event-queue
                    :documentation "Event queue for persistent SSE push. Created on first /sse connect.")
   (csrf-token      :initform (generate-csrf-token)
                    :accessor session-csrf-token
                    :type string
                    :documentation "Random token for CSRF protection. Validated on every POST.")
   (user            :initform nil
                    :accessor session-user
                    :documentation "Application-defined user data. NIL when not authenticated.")
   (user-roles      :initform nil
                    :accessor session-user-roles
                    :documentation "List of role keywords for the authenticated user, e.g. (:admin :editor)."))
  (:documentation "A per-browser session holding its own component instances."))

(defmethod print-object ((s session) stream)
  (print-unreadable-object (s stream :type t :identity t)
    (format stream "~A ~D component~:P~@[ user=~A~]"
            (session-id s)
            (hash-table-count (session-components s))
            (session-user s))))

;;; -------------------------------------------------------
;;; Session event queue
;;; -------------------------------------------------------

(defun ensure-event-queue (session)
  "Return the session's event queue, creating it if needed.
Closes any existing queue first so that the previous SSE loop
terminates cleanly and does not steal events from the new connection."
  (let ((old (session-event-queue session)))
    (when old
      (close-event-queue old)))
  (setf (session-event-queue session) (make-event-queue)))

;;; -------------------------------------------------------
;;; Session utilities
;;; -------------------------------------------------------

(defun touch-session (session)
  "Update the last-accessed-at timestamp on SESSION."
  (setf (session-last-accessed-at session) (get-universal-time))
  session)

(defun session-expired-p (session ttl)
  "Return T if SESSION has not been accessed within TTL seconds."
  (> (- (get-universal-time) (session-last-accessed-at session)) ttl))

(defun generate-session-id ()
  "Generate a cryptographically random session ID string (32 hex characters)."
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defgeneric session-component (session id)
  (:documentation "Find a component by ID within a SESSION."))

(defmethod session-component ((session session) (id string))
  (gethash id (session-components session)))

(defgeneric (setf session-component) (component session id)
  (:documentation "Store a component in a SESSION under ID."))

(defmethod (setf session-component) ((c component) (session session) (id string))
  (setf (gethash id (session-components session)) c))

;;; -------------------------------------------------------
;;; CSRF validation
;;; -------------------------------------------------------

(defun get-csrf-header (env)
  "Extract the X-CSRF-Token header from a Clack ENV."
  (let ((headers (getf env :headers)))
    (when headers
      (gethash "x-csrf-token" headers))))

(defun read-body-as-string (env)
  "Read :raw-body from ENV into a string. Caches result in :fluxion-body-string.
Handles both stream and string bodies. Uses nconc to mutate the shared ENV list."
  (or (getf env :fluxion-body-string)
      (let ((body (getf env :raw-body)))
        (when body
          (let ((s (handler-case
                       (if (stringp body)
                           body
                           (when (streamp body)
                             (let ((buf (make-array 4096 :element-type '(unsigned-byte 8)
                                                         :adjustable t :fill-pointer 0)))
                               (loop for byte = (read-byte body nil nil)
                                     while byte do (vector-push-extend byte buf))
                               (babel:octets-to-string buf :encoding :utf-8))))
                     (error () nil))))
            (when s
              (nconc env (list :fluxion-body-string s)))
            s)))))

(defun parse-form-body (env)
  "Parse a URL-encoded form body from ENV, returning an alist of string pairs.
Caches the raw body string on ENV so the stream only needs to be read once."
  (let ((content-type (getf env :content-type)))
    (when (and content-type
               (search "application/x-www-form-urlencoded" content-type))
      (let ((body-string (read-body-as-string env)))
        (when (and body-string (plusp (length body-string)))
          (loop for pair in (cl-ppcre:split "&" body-string)
                for kv = (cl-ppcre:split "=" pair :limit 2)
                when (= (length kv) 2)
                collect (cons (quri:url-decode (first kv))
                              (quri:url-decode (second kv)))))))))

(defun csrf-valid-p (session env)
  "Return T if the CSRF token in the request matches the session's token.
Checks both the X-CSRF-Token header (for XHR) and the _csrf form parameter (for HTML forms)."
  (let* ((header-token (get-csrf-header env))
         (form-params (unless header-token (parse-form-body env)))
         (form-token (when form-params
                       (cdr (assoc "_csrf" form-params :test #'string=))))
         (request-token (or header-token form-token))
         (session-token (session-csrf-token session)))
    (when form-params
      (nconc env (list :fluxion-form-params form-params)))
    (and request-token
         session-token
         (string= request-token session-token))))

(defun csrf-rejection-response ()
  "Return a 403 response for CSRF validation failure."
  (list 403
        '(:content-type "text/plain")
        '("Forbidden: invalid or missing CSRF token")))

;;; -------------------------------------------------------
;;; Cookie handling
;;; -------------------------------------------------------

(alexandria:define-constant +session-cookie-name+ "fluxion-sid" :test #'equal)

(defun parse-cookies (env)
  "Parse the Cookie header from Clack ENV into an alist.
Handles both Lack's :headers hash-table and raw :http-cookie plist key."
  (let* ((headers (getf env :headers))
         (cookie-header (or (and headers (gethash "cookie" headers))
                            (getf env :http-cookie))))
    (when cookie-header
      (loop for pair in (uiop:split-string cookie-header :separator ";")
            for trimmed = (string-trim " " pair)
            for eqpos = (position #\= trimmed)
            when eqpos
              collect (cons (subseq trimmed 0 eqpos)
                            (subseq trimmed (1+ eqpos)))))))

(defun get-session-id-from-env (env)
  "Extract the Fluxion session ID from cookies, or NIL."
  (let ((cookies (parse-cookies env)))
    (cdr (assoc +session-cookie-name+ cookies :test #'string=))))

(defun set-session-cookie (response session)
  "Add a Set-Cookie header to RESPONSE for SESSION."
  (let ((cookie (format nil "~A=~A; Path=/; HttpOnly; SameSite=Lax"
                        +session-cookie-name+ (session-id session))))
    (list (first response)
          (append (second response) (list :set-cookie cookie))
          (third response))))
