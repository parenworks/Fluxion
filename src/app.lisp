;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Application container, registries, SSE push, health

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Application container
;;; -------------------------------------------------------

(defgeneric app-sessions (app)
  (:documentation "Hash table of active sessions keyed by session-id string."))

(defgeneric app-session-lock (app)
  (:documentation "Lock protecting concurrent access to the session store."))

(defgeneric app-session-ttl (app)
  (:documentation "Session time-to-live in seconds before idle expiry."))

(defgeneric app-reaper-interval (app)
  (:documentation "Seconds between session reaper runs."))

(defgeneric app-handler (app)
  (:documentation "The running Clack handler reference (used for stopping the server)."))

(defgeneric app-server (app)
  (:documentation "Clack server backend keyword (:woo or :hunchentoot)."))

(defgeneric app-started-at (app)
  (:documentation "Universal time when the server was started."))

(defgeneric app-request-log (app)
  (:documentation "When non-nil, every request is logged to *standard-output*."))

(defclass fluxion-app ()
  ((components :initform (make-hash-table :test 'equal)
               :accessor app-components
               :documentation "Registry of global component instances, keyed by component-id.")
   (component-factories :initform (make-hash-table :test 'equal)
                        :accessor app-component-factories
                        :documentation "Factory functions keyed by component-id. Called to create per-session instances.")
   (actions    :initform (make-hash-table :test 'equal)
               :accessor app-actions
               :documentation "Registry of action handlers, keyed by URL path string.")
   (sessions   :initform (make-hash-table :test 'equal)
               :accessor app-sessions
               :documentation "Session store, keyed by session-id string.")
   (session-lock :initform (bt:make-lock "fluxion-session-lock")
                 :accessor app-session-lock)
   (session-ttl :initarg :session-ttl
                :accessor app-session-ttl
                :initform 3600
                :documentation "Session time-to-live in seconds. Default 1 hour.")
   (reaper-thread :initform nil
                  :accessor app-reaper-thread
                  :documentation "Background thread that periodically removes expired sessions.")
   (reaper-stop-flag :initform nil
                     :accessor app-reaper-stop-flag
                     :documentation "When T, the reaper thread exits on its next cycle.")
   (reaper-interval :initarg :reaper-interval
                    :accessor app-reaper-interval
                    :initform 60
                    :documentation "Seconds between session reaper runs. Default 60.")
   (static-dir :initarg :static-dir
               :accessor app-static-dir
               :initform nil
               :documentation "Directory path for serving static files (fluxion.js, etc).")
   (handler    :initform nil
               :accessor app-handler
               :documentation "The running Clack handler (used for stopping).")
   (port       :initarg :port
               :accessor app-port
               :initform 5000)
   (server     :initarg :server
               :accessor app-server
               :initform :woo
               :documentation "Clack server backend. :woo (default) or :hunchentoot.")
   (started-at :initform nil
               :accessor app-started-at
               :documentation "Universal time when the server was started.")
   (request-log :initarg :request-log
                :accessor app-request-log
                :initform t
                :documentation "When non-nil, log every request to *standard-output*.")
   (middleware  :initform nil
               :accessor app-middleware
               :documentation "List of middleware-entry structs applied at start time."))
  (:documentation "Top-level Fluxion application."))

(defmethod print-object ((app fluxion-app) stream)
  (print-unreadable-object (app stream :type t :identity t)
    (format stream ":~D ~A ~D session~:P"
            (app-port app)
            (string-downcase (symbol-name (app-server app)))
            (hash-table-count (app-sessions app)))))

(defun make-fluxion-app (&key (port 5000) static-dir (session-ttl 3600)
                             (reaper-interval 60) (server :woo) (request-log t))
  "Create a new Fluxion application instance.
SERVER is the Clack backend: :woo (default) or :hunchentoot.
Woo uses libev for async I/O. Install libev-dev to use it.
REQUEST-LOG: when non-nil (default T), logs every request.
Middleware is added after creation via ADD-MIDDLEWARE."
  (make-instance 'fluxion-app :port port :static-dir static-dir
                              :session-ttl session-ttl
                              :reaper-interval reaper-interval
                              :server server
                              :request-log request-log))

;;; -------------------------------------------------------
;;; Component registry
;;; -------------------------------------------------------

(defgeneric register-component (app component)
  (:documentation "Register a global (shared) COMPONENT instance in APP."))

(defmethod register-component ((app fluxion-app) (c component))
  (setf (gethash (component-id c) (app-components app)) c)
  c)

(defgeneric register-component-factory (app id factory-fn)
  (:documentation "Register a factory function for per-session component creation.
ID is the component-id string. FACTORY-FN is a function of zero arguments
that returns a fresh component instance."))

(defmethod register-component-factory ((app fluxion-app) (id string) factory-fn)
  (setf (gethash id (app-component-factories app)) factory-fn)
  id)

(defgeneric find-component (app id &key session)
  (:documentation "Find a component by ID. Checks session first, then global registry."))

(defmethod find-component ((app fluxion-app) (id string) &key session)
  (or (and session (session-component session id))
      (gethash id (app-components app))))

;;; -------------------------------------------------------
;;; Action registry
;;; -------------------------------------------------------

(defgeneric register-action (app path handler-fn)
  (:documentation
   "Register an action handler function for PATH.
HANDLER-FN is a function of (app env) that should return a list
of SSE events to send, or write directly to an event stream."))

(defmethod register-action ((app fluxion-app) (path string) handler-fn)
  (setf (gethash path (app-actions app)) handler-fn)
  path)

;;; -------------------------------------------------------
;;; SSE streaming
;;; -------------------------------------------------------

(defun sse-headers ()
  "Return standard SSE response headers."
  '(:content-type "text/event-stream"
    :cache-control "no-cache"
    :connection "keep-alive"
    :access-control-allow-origin "*"))

(defun send-event (stream event)
  "Write a single SSE-EVENT to STREAM."
  (write-sse-event event stream))

(defun send-events (stream events)
  "Write a list of SSE-EVENTs to STREAM."
  (dolist (event events)
    (send-event stream event)))

(defun patch (stream component &key (mode "morph"))
  "Convenience: render COMPONENT and write a patch event to STREAM."
  (let ((html (render-to-string component))
        (selector (component-selector component)))
    (send-event stream
                (make-patch-event selector html :mode mode))))

(defun push-event (session event)
  "Push an SSE event to a session's persistent SSE connection.
The event will be delivered to the browser via the EventSource stream."
  (let ((queue (session-event-queue session)))
    (when queue
      (enqueue-event queue event))))

(defun push-events (session events)
  "Push multiple SSE events to a session's persistent connection."
  (let ((queue (session-event-queue session)))
    (when queue
      (dolist (e events)
        (enqueue-event queue e)))))

(defgeneric push-component-patch (session component &key mode)
  (:documentation "Re-render COMPONENT and push a patch event to SESSION's SSE stream."))

(defmethod push-component-patch ((session session) (component component)
                                 &key (mode "morph"))
  (mark-dirty component)
  (let ((events (patch-component component :mode mode :force t)))
    (push-events session events)))

;;; -------------------------------------------------------
;;; Session management (app-level)
;;; -------------------------------------------------------

(defun get-or-create-session (app env)
  "Return (values session is-new-p). Creates a new session if needed.
Ensures per-session component instances are created from factories."
  (let ((sid (get-session-id-from-env env)))
    (bt:with-lock-held ((app-session-lock app))
      (let ((existing (and sid (gethash sid (app-sessions app)))))
        (if existing
            (progn
              (touch-session existing)
              (values existing nil))
            (let* ((new-sid (generate-session-id))
                   (session (make-instance 'session :id new-sid)))
              ;; Create per-session component instances from factories
              (maphash (lambda (id factory-fn)
                         (let ((c (funcall factory-fn)))
                           (setf (gethash id (session-components session)) c)
                           (setf (component-session c) session)
                           (component-mounted c session)))
                       (app-component-factories app))
              (setf (gethash new-sid (app-sessions app)) session)
              (values session t)))))))

;;; -------------------------------------------------------
;;; Health endpoint
;;; -------------------------------------------------------

(defun app-uptime-seconds (app)
  "Return seconds since the app was started, or 0 if not started."
  (if (app-started-at app)
      (- (get-universal-time) (app-started-at app))
      0))

(defun app-session-count (app)
  "Return the current number of active sessions."
  (hash-table-count (app-sessions app)))

(defun app-sse-connection-count (app)
  "Return the number of sessions with active (not closed) event queues."
  (let ((count 0))
    (bt:with-lock-held ((app-session-lock app))
      (maphash (lambda (sid session)
                 (declare (ignore sid))
                 (let ((q (session-event-queue session)))
                   (when (and q (not (eq-closed-p q)))
                     (incf count))))
               (app-sessions app)))
    count))

(defun health-response (app)
  "Return a JSON health check response."
  (let ((uptime (app-uptime-seconds app)))
    (list 200
          '(:content-type "application/json"
            :cache-control "no-cache")
          (list (cl-json:encode-json-to-string
                 `((:status . "ok")
                   (:uptime_seconds . ,uptime)
                   (:uptime_human . ,(format nil "~Dd ~Dh ~Dm ~Ds"
                                             (floor uptime 86400)
                                             (floor (mod uptime 86400) 3600)
                                             (floor (mod uptime 3600) 60)
                                             (mod uptime 60)))
                   (:sessions . ,(app-session-count app))
                   (:sse_connections . ,(app-sse-connection-count app))
                   (:server . ,(string-downcase (symbol-name (app-server app))))
                   (:port . ,(app-port app))))))))
