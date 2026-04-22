;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Clack/Hunchentoot server integration

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Application container
;;; -------------------------------------------------------

(defclass fluxion-app ()
  ((components :initform (make-hash-table :test 'equal)
               :accessor app-components
               :documentation "Registry of live component instances, keyed by component-id.")
   (actions    :initform (make-hash-table :test 'equal)
               :accessor app-actions
               :documentation "Registry of action handlers, keyed by URL path string.")
   (static-dir :initarg :static-dir
               :accessor app-static-dir
               :initform nil
               :documentation "Directory path for serving static files (fluxion.js, etc).")
   (handler    :initform nil
               :accessor app-handler
               :documentation "The running Clack handler (used for stopping).")
   (port       :initarg :port
               :accessor app-port
               :initform 5000))
  (:documentation "Top-level Fluxion application."))

(defun make-fluxion-app (&key (port 5000) static-dir)
  "Create a new Fluxion application instance."
  (make-instance 'fluxion-app :port port :static-dir static-dir))

;;; -------------------------------------------------------
;;; Component registry
;;; -------------------------------------------------------

(defgeneric register-component (app component)
  (:documentation "Register a live COMPONENT instance in APP."))

(defmethod register-component ((app fluxion-app) (c component))
  (setf (gethash (component-id c) (app-components app)) c)
  c)

(defgeneric find-component (app id)
  (:documentation "Find a registered component by its ID string."))

(defmethod find-component ((app fluxion-app) (id string))
  (gethash id (app-components app)))

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
;;; Main Clack application handler
;;; -------------------------------------------------------

(defun make-clack-app (app page-handler)
  "Build a Clack application function for APP.
PAGE-HANDLER is a function of (app env) that returns the initial
HTML page response."
  (lambda (env)
    (let ((path (get-request-path env))
          (method (get-request-method env)))
      (cond
        ;; Static files
        ((alexandria:starts-with-subseq "/static/" path)
         (static-file-handler app env))

        ;; SSE action endpoints (POST - returns event-stream)
        ((and (eq method :post)
              (gethash path (app-actions app)))
         (let ((action-fn (gethash path (app-actions app)))
               (params (parse-request-body env)))
           (handler-case
               (let ((events (funcall action-fn app params)))
                 (if (listp events)
                     ;; Action returned a list of events; format as SSE
                     (list 200
                           (sse-headers)
                           (list (with-output-to-string (s)
                                   (send-events s events))))
                     ;; Action returned something else (e.g. a direct response)
                     events))
             (error (e)
               (list 500
                     '(:content-type "text/plain")
                     (list (format nil "Action error: ~A" e)))))))

        ;; Default: serve the page
        (t
         (funcall page-handler app env))))))

;;; -------------------------------------------------------
;;; Start / Stop
;;; -------------------------------------------------------

(defgeneric start (app page-handler &key)
  (:documentation "Start the Fluxion application server."))

(defmethod start ((app fluxion-app) page-handler &key (port nil port-supplied-p))
  (when port-supplied-p
    (setf (app-port app) port))
  (let ((clack-app (make-clack-app app page-handler)))
    (setf (app-handler app)
          (clack:clackup clack-app
                         :port (app-port app)
                         :server :hunchentoot))
    app))

(defgeneric stop (app)
  (:documentation "Stop the Fluxion application server."))

(defmethod stop ((app fluxion-app))
  (when (app-handler app)
    (clack:stop (app-handler app))
    (setf (app-handler app) nil))
  app)
