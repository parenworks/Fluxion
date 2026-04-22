;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Clack/Hunchentoot server integration

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; CSRF token generation
;;; -------------------------------------------------------

(defun generate-csrf-token ()
  "Generate a random CSRF token string (32 hex characters)."
  (format nil "~(~32,'0X~)" (random (expt 2 128))))

;;; -------------------------------------------------------
;;; Session
;;; -------------------------------------------------------

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

;;; -------------------------------------------------------
;;; Event queue (for persistent SSE push)
;;; -------------------------------------------------------

(defclass event-queue ()
  ((events  :initform nil
            :accessor eq-events)
   (lock    :initform (bt:make-lock "event-queue")
            :accessor eq-lock)
   (condvar :initform (bt:make-condition-variable :name "event-queue-cv")
            :accessor eq-condvar)
   (closed-p :initform nil
             :accessor eq-closed-p))
  (:documentation "Thread-safe event queue with blocking dequeue."))

(defun make-event-queue ()
  (make-instance 'event-queue))

(defun enqueue-event (queue event)
  "Add EVENT to QUEUE and wake any waiting reader."
  (bt:with-lock-held ((eq-lock queue))
    (setf (eq-events queue)
          (nconc (eq-events queue) (list event)))
    (bt:condition-notify (eq-condvar queue))))

(defun dequeue-all-events (queue &key (timeout 15))
  "Block until events are available or TIMEOUT seconds elapse.
Returns the list of events (may be empty on timeout)."
  (bt:with-lock-held ((eq-lock queue))
    (when (and (null (eq-events queue))
               (not (eq-closed-p queue)))
      (bt:condition-wait (eq-condvar queue) (eq-lock queue)
                         :timeout timeout))
    (prog1 (eq-events queue)
      (setf (eq-events queue) nil))))

(defun close-event-queue (queue)
  "Mark QUEUE as closed and wake any waiting reader."
  (bt:with-lock-held ((eq-lock queue))
    (setf (eq-closed-p queue) t)
    (bt:condition-notify (eq-condvar queue))))

(defun ensure-event-queue (session)
  "Return the session's event queue, creating it if needed."
  (or (session-event-queue session)
      (setf (session-event-queue session) (make-event-queue))))

(defun touch-session (session)
  "Update the last-accessed-at timestamp on SESSION."
  (setf (session-last-accessed-at session) (get-universal-time))
  session)

(defun session-expired-p (session ttl)
  "Return T if SESSION has not been accessed within TTL seconds."
  (> (- (get-universal-time) (session-last-accessed-at session)) ttl))

(defun generate-session-id ()
  "Generate a random session ID string."
  (format nil "~A-~A"
          (get-universal-time)
          (random (expt 2 64))))

(defgeneric session-component (session id)
  (:documentation "Find a component by ID within a SESSION."))

(defmethod session-component ((session session) (id string))
  (gethash id (session-components session)))

(defgeneric (setf session-component) (component session id)
  (:documentation "Store a component in a SESSION under ID."))

(defmethod (setf session-component) ((c component) (session session) (id string))
  (setf (gethash id (session-components session)) c))

;;; -------------------------------------------------------
;;; Authentication
;;; -------------------------------------------------------

(defun authenticated-p (session)
  "Return T if SESSION has an authenticated user."
  (not (null (session-user session))))

(defun authenticate (session user &key roles)
  "Set the authenticated user on SESSION.
USER can be any application-defined value (string, plist, CLOS object, etc.).
ROLES is an optional list of role keywords.
Regenerates the CSRF token to prevent session fixation."
  (setf (session-user session) user)
  (when roles
    (setf (session-user-roles session) roles))
  ;; Regenerate CSRF token on privilege change
  (setf (session-csrf-token session) (generate-csrf-token))
  user)

(defun logout (session)
  "Clear the authenticated user from SESSION.
Regenerates the CSRF token."
  (setf (session-user session) nil)
  (setf (session-user-roles session) nil)
  (setf (session-csrf-token session) (generate-csrf-token))
  nil)

(defun has-role-p (session role)
  "Return T if SESSION's user has ROLE in their roles list."
  (and (authenticated-p session)
       (member role (session-user-roles session))))

(defun require-auth (session &key (login-url "/login"))
  "If SESSION is not authenticated, return a redirect response to LOGIN-URL.
Returns NIL if the user is authenticated (meaning: proceed normally).
Use in page handlers as a guard:
  (or (require-auth session) (render-protected-page ...))"
  (unless (authenticated-p session)
    (list 303
          (list :location login-url
                :content-type "text/plain")
          '("Redirecting to login"))))

(defun require-role (session role &key (login-url "/login") (forbidden-url nil))
  "If SESSION's user lacks ROLE, return a redirect or 403 response.
Returns NIL if the user has the role (meaning: proceed normally).
If the user is not authenticated at all, redirects to LOGIN-URL.
If authenticated but lacking the role, returns 403 (or redirects to FORBIDDEN-URL)."
  (cond
    ((not (authenticated-p session))
     (list 303
           (list :location login-url
                 :content-type "text/plain")
           '("Redirecting to login")))
    ((not (has-role-p session role))
     (if forbidden-url
         (list 303
               (list :location forbidden-url
                     :content-type "text/plain")
               '("Insufficient permissions"))
         (list 403
               '(:content-type "text/plain")
               '("Forbidden: insufficient permissions"))))
    (t nil)))

;;; -------------------------------------------------------
;;; Application container
;;; -------------------------------------------------------

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
               :documentation "Clack server backend. :woo (default) or :hunchentoot."))
  (:documentation "Top-level Fluxion application."))

(defun make-fluxion-app (&key (port 5000) static-dir (session-ttl 3600)
                             (reaper-interval 60) (server :woo))
  "Create a new Fluxion application instance.
SERVER is the Clack backend: :woo (default) or :hunchentoot.
Woo uses libev for async I/O. Install libev-dev to use it."
  (make-instance 'fluxion-app :port port :static-dir static-dir
                              :session-ttl session-ttl
                              :reaper-interval reaper-interval
                              :server server))

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

(defun push-component-patch (session component &key (mode "morph"))
  "Re-render COMPONENT and push a patch event to SESSION's SSE stream."
  (mark-dirty component)
  (let ((events (patch-component component :mode mode :force t)))
    (push-events session events)))

;;; -------------------------------------------------------
;;; Request parsing
;;; -------------------------------------------------------

(defun parse-request-body (env)
  "Parse the request body from a Clack ENV as a JSON alist.
Returns NIL if no body or parse failure."
  (let ((body-stream (getf env :raw-body)))
    (when body-stream
      (handler-case
          (let ((body-string
                  (let ((buf (make-array 4096 :element-type '(unsigned-byte 8)
                                              :adjustable t :fill-pointer 0)))
                    (loop for byte = (read-byte body-stream nil nil)
                          while byte do (vector-push-extend byte buf))
                    (babel:octets-to-string buf :encoding :utf-8))))
            (when (and body-string (plusp (length body-string)))
              (cl-json:decode-json-from-string body-string)))
        (error () nil)))))

(defun get-request-path (env)
  "Extract the request path from Clack ENV."
  (getf env :path-info "/"))

(defun get-request-method (env)
  "Extract the request method keyword from Clack ENV."
  (getf env :request-method :get))

;;; -------------------------------------------------------
;;; Static file serving
;;; -------------------------------------------------------

(defun serve-static-file (filepath content-type)
  "Serve a static file as a Clack response."
  (if (probe-file filepath)
      (list 200
            (list :content-type content-type)
            (pathname filepath))
      (list 404
            '(:content-type "text/plain")
            '("Not Found"))))

(defun static-file-handler (app env)
  "Handle static file requests under /static/."
  (let* ((path (get-request-path env))
         (relative (subseq path (length "/static/")))
         (static-dir (or (app-static-dir app)
                         (asdf:system-relative-pathname "fluxion" "static/")))
         (filepath (merge-pathnames relative static-dir))
         (content-type (guess-content-type relative)))
    (serve-static-file filepath content-type)))

(defun guess-content-type (filename)
  "Guess content-type from file extension."
  (let ((ext (pathname-type (pathname filename))))
    (cond
      ((string-equal ext "js")   "application/javascript")
      ((string-equal ext "css")  "text/css")
      ((string-equal ext "html") "text/html")
      ((string-equal ext "json") "application/json")
      (t "application/octet-stream"))))

;;; -------------------------------------------------------
;;; CLOS action dispatch
;;; -------------------------------------------------------

(defun parse-action-path (path)
  "Parse a path like /action/component-id/action-name.
Returns (values component-id action-keyword) or NIL."
  (let ((parts (remove "" (uiop:split-string path :separator "/") :test #'string=)))
    (when (and (= (length parts) 3)
               (string-equal (first parts) "action"))
      (values (second parts)
              (intern (string-upcase (third parts)) :keyword)))))

(defun dispatch-component-action (app path params &key session)
  "Try to dispatch PATH as a CLOS component action.
Returns a Clack response or NIL if the path is not an action route."
  (multiple-value-bind (component-id action-keyword)
      (parse-action-path path)
    (when component-id
      (let ((component (find-component app component-id :session session)))
        (if component
            (handler-case
                (let* ((*pending-events* (list nil))
                       (action-events (handle-action component action-keyword params))
                       (cell-events (drain-pending-events))
                       (events (if (listp action-events)
                                   (append action-events cell-events)
                                   action-events)))
                  (if (listp events)
                      (list 200
                            (sse-headers)
                            (list (with-output-to-string (s)
                                    (send-events s events))))
                      events))
              (error (e)
                (let ((msg (format nil "Action error: ~A" e)))
                  (list 200
                        (sse-headers)
                        (list (with-output-to-string (s)
                                (send-event s (make-script-event
                                               (format nil "fluxionShowError(~A)"
                                                       (cl-json:encode-json-to-string msg))))))))))
            (list 200
                  (sse-headers)
                  (list (with-output-to-string (s)
                          (send-event s (make-script-event
                                         (format nil "fluxionShowError(~A)"
                                                 (cl-json:encode-json-to-string
                                                  (format nil "Component '~A' not found" component-id)))))))))))))

;;; -------------------------------------------------------
;;; Session management
;;; -------------------------------------------------------

(alexandria:define-constant +session-cookie-name+ "fluxion-sid" :test #'equal)

(defun get-csrf-header (env)
  "Extract the X-CSRF-Token header from a Clack ENV."
  (let ((headers (getf env :headers)))
    (when headers
      (gethash "x-csrf-token" headers))))

(defun csrf-valid-p (session env)
  "Return T if the CSRF token in the request matches the session's token."
  (let ((request-token (get-csrf-header env))
        (session-token (session-csrf-token session)))
    (and request-token
         session-token
         (string= request-token session-token))))

(defun csrf-rejection-response ()
  "Return a 403 response for CSRF validation failure."
  (list 403
        '(:content-type "text/plain")
        '("Forbidden: invalid or missing CSRF token")))

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
                           (setf (gethash id (session-components session)) c)))
                       (app-component-factories app))
              (setf (gethash new-sid (app-sessions app)) session)
              (values session t)))))))

(defun set-session-cookie (response session)
  "Add a Set-Cookie header to RESPONSE for SESSION."
  (let ((cookie (format nil "~A=~A; Path=/; HttpOnly; SameSite=Lax"
                        +session-cookie-name+ (session-id session))))
    (list (first response)
          (append (second response) (list :set-cookie cookie))
          (third response))))

;;; -------------------------------------------------------
;;; Router
;;; -------------------------------------------------------

(defclass route ()
  ((method  :initarg :method
            :accessor route-method
            :type keyword
            :documentation "HTTP method keyword (:get, :post, or :any).")
   (pattern :initarg :pattern
            :accessor route-pattern
            :type string
            :documentation "URL pattern, e.g. \"/users/:id\".")
   (segments :initarg :segments
             :accessor route-segments
             :documentation "Pre-parsed list of (keyword-or-string) segments.")
   (handler :initarg :handler
            :accessor route-handler
            :documentation "Function (app session env &key params) -> response.")
   (guard   :initarg :guard
            :accessor route-guard
            :initform nil
            :documentation "Optional guard function (session) -> response-or-nil.
If it returns a response, that response is sent and the handler is skipped.")
   (name    :initarg :name
            :accessor route-name
            :initform nil
            :documentation "Optional route name for URL generation."))
  (:documentation "A single route entry in the router."))

(defclass router ()
  ((routes  :initform nil
            :accessor router-routes
            :documentation "List of route objects in registration order.")
   (not-found-handler :initarg :not-found-handler
                      :accessor router-not-found-handler
                      :initform nil
                      :documentation "Optional handler for 404. Signature: (app session env)."))
  (:documentation "Path-based request router."))

(defun make-router (&key not-found-handler)
  "Create a new router instance."
  (make-instance 'router :not-found-handler not-found-handler))

(defun parse-pattern (pattern)
  "Parse a URL pattern like \"/users/:id/posts\" into a list of segments.
Each segment is either a string (literal) or a keyword (parameter).
Example: (\"/users/:id\") -> (\"users\" :id)"
  (loop for seg in (remove "" (uiop:split-string pattern :separator "/") :test #'string=)
        collect (if (and (> (length seg) 0)
                         (char= (char seg 0) #\:))
                    (intern (string-upcase (subseq seg 1)) :keyword)
                    seg)))

(defun match-route (route path method)
  "Try to match PATH and METHOD against ROUTE.
Returns (values matched-p params-alist) where params-alist contains
extracted path parameters."
  (unless (or (eq (route-method route) :any)
              (eq (route-method route) method))
    (return-from match-route (values nil nil)))
  (let ((path-segments (remove "" (uiop:split-string path :separator "/") :test #'string=))
        (route-segments (route-segments route))
        (params nil))
    (unless (= (length path-segments) (length route-segments))
      (return-from match-route (values nil nil)))
    (loop for ps in path-segments
          for rs in route-segments
          do (cond
               ((keywordp rs)
                (push (cons rs ps) params))
               ((string= ps rs)
                nil)
               (t
                (return-from match-route (values nil nil)))))
    (values t (nreverse params))))

(defun add-route (router method pattern handler &key guard name)
  "Add a route to the router. METHOD is :get, :post, or :any.
PATTERN is a URL path like \"/users/:id\".
HANDLER is (app session env &key params) -> response.
GUARD is an optional (session) -> response-or-nil."
  (let ((route (make-instance 'route
                              :method method
                              :pattern pattern
                              :segments (parse-pattern pattern)
                              :handler handler
                              :guard guard
                              :name name)))
    (setf (router-routes router)
          (append (router-routes router) (list route)))
    route))

(defun dispatch-route (router app session env)
  "Find and dispatch the first matching route. Returns a Clack response.
If no route matches, calls the not-found-handler or returns 404."
  (let ((path (get-request-path env))
        (method (get-request-method env)))
    (dolist (route (router-routes router))
      (multiple-value-bind (matched params)
          (match-route route path method)
        (when matched
          ;; Run guard if present
          (when (route-guard route)
            (let ((guard-response (funcall (route-guard route) session)))
              (when guard-response
                (return-from dispatch-route guard-response))))
          ;; Run handler
          (return-from dispatch-route
            (funcall (route-handler route) app session env :params params)))))
    ;; No match
    (if (router-not-found-handler router)
        (funcall (router-not-found-handler router) app session env)
        (list 404
              '(:content-type "text/plain")
              '("Not found")))))

(defun router-handler (router)
  "Return a page-handler function suitable for passing to start.
This bridges the router into the existing Fluxion server."
  (lambda (app session env)
    (dispatch-route router app session env)))

(defmacro defroute (router-var method pattern args &body body)
  "Define a route on ROUTER-VAR.
METHOD is :get, :post, or :any.
PATTERN is a URL path like \"/users/:id\".
ARGS is a lambda list (app session env &key params).

Example:
  (defroute *router* :get \"/\" (app session env &key params)
    (list 200 '(:content-type \"text/html\") (list \"Hello\")))

  (defroute *router* :get \"/users/:id\" (app session env &key params)
    (let ((user-id (cdr (assoc :id params))))
      ...))"
  `(add-route ,router-var ,method ,pattern
              (lambda ,args ,@body)))

;;; -------------------------------------------------------
;;; Main Clack application handler
;;; -------------------------------------------------------

(defun make-clack-app (app page-handler)
  "Build a Clack application function for APP.
PAGE-HANDLER is a function of (app session env) that returns the initial
HTML page response."
  (lambda (env)
    (let ((path (get-request-path env))
          (method (get-request-method env)))
      (cond
        ;; Static files (no session needed)
        ((alexandria:starts-with-subseq "/static/" path)
         (static-file-handler app env))

        ;; Everything else needs a session
        (t
         (multiple-value-bind (session new-session-p)
             (get-or-create-session app env)
           (let ((response
                   (cond
                     ;; Persistent SSE stream (GET /sse)
                     ((and (eq method :get)
                           (string= path "/sse"))
                      (let ((queue (ensure-event-queue session)))
                        ;; Return a streaming callback for Clack
                        ;; The responder (handle-normal-response) returns a writer
                        ;; function when called without a body.
                        (lambda (responder)
                          (let ((writer (funcall responder
                                          '(200 (:content-type "text/event-stream"
                                                 :cache-control "no-cache"
                                                 :x-accel-buffering "no")))))
                            (handler-case
                                (loop until (eq-closed-p queue) do
                                  (let ((events (dequeue-all-events queue :timeout 15)))
                                    (if events
                                        (dolist (event events)
                                          (funcall writer (format-sse-event event)))
                                        ;; Keep-alive comment
                                        (funcall writer
                                                 (format nil ": keepalive~%~%")))))
                              (error ()
                                ;; Client disconnected
                                nil))
                            (ignore-errors (funcall writer nil :close t))))))

                     ;; All POST routes require a valid CSRF token
                     ((and (eq method :post)
                           (not (csrf-valid-p session env)))
                      (csrf-rejection-response))

                     ;; CLOS component actions (POST /action/component-id/action-name)
                     ((and (eq method :post)
                           (alexandria:starts-with-subseq "/action/" path))
                      (let ((params (parse-request-body env)))
                        (or (dispatch-component-action app path params :session session)
                            (list 404
                                  '(:content-type "text/plain")
                                  '("Action not found")))))

                     ;; Legacy registered action endpoints
                     ((and (eq method :post)
                           (gethash path (app-actions app)))
                      (let ((action-fn (gethash path (app-actions app)))
                            (params (parse-request-body env)))
                        (handler-case
                            (let ((events (funcall action-fn app params)))
                              (if (listp events)
                                  (list 200
                                        (sse-headers)
                                        (list (with-output-to-string (s)
                                                (send-events s events))))
                                  events))
                          (error (e)
                            (let ((msg (format nil "Action error: ~A" e)))
                              (list 200
                                    (sse-headers)
                                    (list (with-output-to-string (s)
                                            (send-event s (make-script-event
                                                           (format nil "fluxionShowError(~A)"
                                                                   (cl-json:encode-json-to-string msg))))))))))))

                     ;; Default: serve the page
                     (t
                      (funcall page-handler app session env)))))
             ;; Set session cookie on new sessions (skip for streaming responses)
             (if (and new-session-p (listp response))
                 (set-session-cookie response session)
                 response))))))))

;;; -------------------------------------------------------
;;; Start / Stop
;;; -------------------------------------------------------

(defgeneric start (app page-handler &key)
  (:documentation "Start the Fluxion application server."))

(defmethod start ((app fluxion-app) page-handler &key (port nil port-supplied-p)
                                                      (server nil server-supplied-p))
  (when port-supplied-p
    (setf (app-port app) port))
  (when server-supplied-p
    (setf (app-server app) server))
  (let ((clack-app (make-clack-app app page-handler)))
    (setf (app-handler app)
          (clack:clackup clack-app
                         :port (app-port app)
                         :server (app-server app)))
    (start-session-reaper app)
    app))

(defgeneric stop (app)
  (:documentation "Stop the Fluxion application server."))

(defmethod stop ((app fluxion-app))
  (stop-session-reaper app)
  (when (app-handler app)
    (clack:stop (app-handler app))
    (setf (app-handler app) nil))
  app)

;;; -------------------------------------------------------
;;; Session reaper
;;; -------------------------------------------------------

(defun reap-sessions (app)
  "Remove expired sessions from APP. Closes event queues so SSE
threads unblock and terminate cleanly. Returns the number reaped."
  (let ((ttl (app-session-ttl app))
        (reaped 0)
        (queues-to-close nil))
    (bt:with-lock-held ((app-session-lock app))
      (let ((to-remove nil))
        (maphash (lambda (sid session)
                   (when (session-expired-p session ttl)
                     (push sid to-remove)
                     (let ((q (session-event-queue session)))
                       (when q (push q queues-to-close)))))
                 (app-sessions app))
        (dolist (sid to-remove)
          (remhash sid (app-sessions app))
          (incf reaped))))
    ;; Close queues outside the session lock to avoid deadlock
    (dolist (q queues-to-close)
      (ignore-errors (close-event-queue q)))
    reaped))

(defun start-session-reaper (app)
  "Start the background session reaper thread for APP."
  (stop-session-reaper app)
  (setf (app-reaper-stop-flag app) nil)
  (setf (app-reaper-thread app)
        (bt:make-thread
         (lambda ()
           (loop
             (sleep (app-reaper-interval app))
             (when (app-reaper-stop-flag app)
               (return))
             (handler-case
                 (let ((n (reap-sessions app)))
                   (when (plusp n)
                     (format t "[fluxion] Reaped ~D expired session~:P~%" n)))
               (error (e)
                 (format t "[fluxion] Session reaper error: ~A~%" e)))))
         :name "fluxion-session-reaper")))

(defun stop-session-reaper (app)
  "Stop the background session reaper thread gracefully.
Sets the stop flag and waits briefly for the thread to exit."
  (when (app-reaper-thread app)
    (setf (app-reaper-stop-flag app) t)
    (when (bt:thread-alive-p (app-reaper-thread app))
      ;; Give the thread time to notice the flag and exit
      (ignore-errors
        (bt:join-thread (app-reaper-thread app))))
    (setf (app-reaper-thread app) nil)))
