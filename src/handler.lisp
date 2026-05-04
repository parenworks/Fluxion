;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Clack handler, request dispatch, static files, start/stop

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Request parsing
;;; -------------------------------------------------------

(defgeneric parse-request-body (env)
  (:documentation "Parse the request body from a Clack ENV as a JSON alist.
Returns NIL if no body or parse failure.
Override or wrap with :around methods for custom content types."))

(defmethod parse-request-body (env)
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
      ((string-equal ext "js")    "application/javascript")
      ((string-equal ext "mjs")   "application/javascript")
      ((string-equal ext "css")   "text/css")
      ((string-equal ext "html")  "text/html")
      ((string-equal ext "json")  "application/json")
      ((string-equal ext "png")   "image/png")
      ((string-equal ext "jpg")   "image/jpeg")
      ((string-equal ext "jpeg")  "image/jpeg")
      ((string-equal ext "gif")   "image/gif")
      ((string-equal ext "svg")   "image/svg+xml")
      ((string-equal ext "ico")   "image/x-icon")
      ((string-equal ext "webp")  "image/webp")
      ((string-equal ext "woff")  "font/woff")
      ((string-equal ext "woff2") "font/woff2")
      ((string-equal ext "ttf")   "font/ttf")
      ((string-equal ext "otf")   "font/otf")
      ((string-equal ext "map")   "application/json")
      ((string-equal ext "xml")   "application/xml")
      ((string-equal ext "txt")   "text/plain")
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
;;; Request logging
;;; -------------------------------------------------------

(defun format-log-timestamp ()
  "Return a timestamp string for log output."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

(defun log-request (method path status elapsed-ms)
  "Log a request in structured format."
  (format t "[~A] ~A ~A ~D ~,1Fms~%"
          (format-log-timestamp)
          method path status elapsed-ms))

;;; -------------------------------------------------------
;;; Main Clack application handler
;;; -------------------------------------------------------

(defun make-clack-app (app page-handler)
  "Build a Clack application function for APP.
PAGE-HANDLER is a function of (app session env) that returns the initial
HTML page response."
  (lambda (env)
    (let ((path (get-request-path env))
          (method (get-request-method env))
          (start-time (get-internal-real-time)))
      (flet ((finish-request (response)
               (when (and (app-request-log app) (listp response))
                 (let ((elapsed-ms (* 1000.0
                                      (/ (- (get-internal-real-time) start-time)
                                         (float internal-time-units-per-second)))))
                   (log-request method path (first response) elapsed-ms)))
               response))
        (cond
          ;; Health check (no session needed)
          ((and (eq method :get) (string= path "/health"))
           (finish-request (health-response app)))

          ;; Static files (no session needed)
          ((alexandria:starts-with-subseq "/static/" path)
           (finish-request (static-file-handler app env)))

          ;; Everything else needs a session
          (t
           (multiple-value-bind (session new-session-p)
               (get-or-create-session app env)
             (let* ((*current-session* session)
                    (response
                     (cond
                       ;; Persistent SSE stream (GET /sse)
                       ((and (eq method :get)
                             (string= path "/sse"))
                        (let ((queue (ensure-event-queue session)))
                          ;; Return a streaming callback for Clack.
                          ;; On Woo (async), we spawn a dedicated thread so
                          ;; the event loop stays free for other requests.
                          ;; On Hunchentoot (thread-per-connection), we must
                          ;; block inside the callback — returning would let
                          ;; Hunchentoot finalize the response and corrupt
                          ;; the chunked stream the SSE writer is using.
                          (lambda (responder)
                            (let ((writer (funcall responder
                                            '(200 (:content-type "text/event-stream"
                                                   :cache-control "no-cache"
                                                   :x-accel-buffering "no")))))
                              (flet ((sse-loop ()
                                       (unwind-protect
                                            (handler-case
                                                (loop until (eq-closed-p queue) do
                                                  (let ((events (dequeue-all-events queue :timeout 15)))
                                                    (if events
                                                        (dolist (event events)
                                                          (funcall writer (format-sse-event event)))
                                                        ;; Keep-alive: also touch session to prevent expiry
                                                        (progn
                                                          (touch-session session)
                                                          (funcall writer
                                                                   (format nil ": keepalive~%~%"))))))
                                              (error ()
                                                ;; Client disconnected
                                                nil))
                                         (ignore-errors (funcall writer nil :close t)))))
                                (if (eq (app-server app) :woo)
                                    ;; Woo: spawn a thread to avoid blocking the event loop
                                    (bt:make-thread #'sse-loop :name "fluxion-sse-writer")
                                    ;; Hunchentoot/others: block the request thread
                                    (sse-loop)))))))

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
               (let ((final (if (and new-session-p (listp response))
                                (set-session-cookie response session)
                                response)))
                 (finish-request final))))))))))

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
  (setf (app-started-at app) (get-universal-time))
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
