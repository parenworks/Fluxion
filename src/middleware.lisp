;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Middleware / hook system
;;;;
;;;; Middleware wraps the Clack handler in an onion-style chain.
;;;; Each middleware is a function of (handler) that returns a new handler.
;;;; The handler signature is (lambda (env) ...) per the Clack convention.
;;;;
;;;; Middleware is added to a fluxion-app and composed at start time.
;;;; The outermost middleware runs first (first added = outermost).
;;;;
;;;; Example:
;;;;   (add-middleware app #'my-logger-middleware)
;;;;   (add-middleware app (make-rate-limiter :requests-per-second 10))

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Middleware protocol
;;; -------------------------------------------------------

(defgeneric add-middleware (app middleware &key name)
  (:documentation "Add MIDDLEWARE to APP's middleware chain.
MIDDLEWARE is a function of (handler) that returns a new handler.
NAME is an optional keyword for identification and removal.
Middleware is applied in registration order (first = outermost)."))

(defgeneric remove-middleware (app name)
  (:documentation "Remove middleware identified by NAME from APP."))

(defgeneric clear-middleware (app)
  (:documentation "Remove all middleware from APP."))

;;; -------------------------------------------------------
;;; Middleware entry
;;; -------------------------------------------------------

(defstruct middleware-entry
  "A named middleware entry in the chain."
  (name nil :type (or keyword null))
  (fn   nil :type function))

;;; -------------------------------------------------------
;;; Implementation on fluxion-app
;;; -------------------------------------------------------

(defmethod add-middleware ((app fluxion-app) middleware &key name)
  (let ((entry (make-middleware-entry :name name :fn middleware)))
    (setf (slot-value app 'middleware)
          (append (slot-value app 'middleware) (list entry)))
    name))

(defmethod remove-middleware ((app fluxion-app) name)
  (setf (slot-value app 'middleware)
        (remove name (slot-value app 'middleware)
                :key #'middleware-entry-name))
  name)

(defmethod clear-middleware ((app fluxion-app))
  (setf (slot-value app 'middleware) nil))

(defun wrap-handler (handler app)
  "Compose all registered middleware around HANDLER.
Middleware is applied in registration order: first registered = outermost."
  (let ((wrapped handler))
    (dolist (entry (reverse (slot-value app 'middleware)))
      (setf wrapped (funcall (middleware-entry-fn entry) wrapped)))
    wrapped))

;;; -------------------------------------------------------
;;; Built-in middleware: request logger
;;; -------------------------------------------------------

(defun make-request-logger (&key (stream *standard-output*)
                                 (skip-health nil))
  "Return a middleware that logs each request.
STREAM: output stream (default *standard-output*).
SKIP-HEALTH: when T, omit GET /health from the log."
  (lambda (handler)
    (lambda (env)
      (let* ((path (getf env :path-info "/"))
             (method (getf env :request-method :get))
             (start-time (get-internal-real-time))
             (skip (and skip-health
                        (eq method :get)
                        (string= path "/health"))))
        (let ((response (funcall handler env)))
          (unless skip
            (let ((elapsed-ms (* 1000.0
                                 (/ (- (get-internal-real-time) start-time)
                                    (float internal-time-units-per-second))))
                  (status (if (listp response) (first response) "?")))
              (format stream "[~A] ~A ~A ~A ~,1Fms~%"
                      (format-log-timestamp)
                      method path status elapsed-ms)))
          response)))))

;;; -------------------------------------------------------
;;; Built-in middleware: rate limiter
;;; -------------------------------------------------------

(defun make-rate-limiter (&key (requests-per-second 10)
                               (burst 20)
                               (key-fn nil))
  "Return a middleware that rate-limits requests using a token bucket.
REQUESTS-PER-SECOND: refill rate.
BURST: maximum tokens (allows short bursts above the steady rate).
KEY-FN: function of (env) returning a string key for per-client limiting.
         Default NIL means global (all clients share one bucket)."
  (let ((buckets (make-hash-table :test 'equal))
        (lock (bt:make-lock "rate-limiter")))
    (lambda (handler)
      (lambda (env)
        (let* ((key (if key-fn (funcall key-fn env) :global))
               (now (/ (get-internal-real-time)
                       (float internal-time-units-per-second)))
               (allowed nil))
          (bt:with-lock-held (lock)
            (let ((bucket (gethash key buckets)))
              (unless bucket
                (setf bucket (cons (float burst) now)
                      (gethash key buckets) bucket))
              (let* ((tokens (car bucket))
                     (last-time (cdr bucket))
                     (elapsed (- now last-time))
                     (refilled (min (float burst)
                                    (+ tokens (* elapsed requests-per-second)))))
                (if (>= refilled 1.0)
                    (progn
                      (setf (car bucket) (- refilled 1.0)
                            (cdr bucket) now
                            allowed t))
                    (setf (car bucket) refilled
                          (cdr bucket) now)))))
          (if allowed
              (funcall handler env)
              (list 429
                    '(:content-type "text/plain"
                      :retry-after "1")
                    '("Too Many Requests"))))))))

;;; -------------------------------------------------------
;;; Built-in middleware: CORS
;;; -------------------------------------------------------

(defun make-cors-middleware (&key (allowed-origins '("*"))
                                  (allowed-methods '("GET" "POST" "OPTIONS"))
                                  (allowed-headers '("Content-Type" "X-CSRF-Token"))
                                  (max-age 86400))
  "Return a middleware that adds CORS headers to responses.
ALLOWED-ORIGINS: list of origin strings, or '(\"*\") for any origin.
ALLOWED-METHODS: list of HTTP method strings.
ALLOWED-HEADERS: list of header name strings.
MAX-AGE: preflight cache duration in seconds (default 86400)."
  (lambda (handler)
    (lambda (env)
      (let ((origin (let ((headers (getf env :headers)))
                      (when headers (gethash "origin" headers)))))
        (flet ((cors-headers ()
                 (let ((allow-origin (if (member "*" allowed-origins :test #'string=)
                                         "*"
                                         (or (and origin
                                                  (member origin allowed-origins
                                                          :test #'string=)
                                                  origin)
                                             ""))))
                   (list :access-control-allow-origin allow-origin
                         :access-control-allow-methods
                         (format nil "~{~A~^, ~}" allowed-methods)
                         :access-control-allow-headers
                         (format nil "~{~A~^, ~}" allowed-headers)
                         :access-control-max-age (format nil "~D" max-age)))))
          ;; Handle preflight OPTIONS
          (if (eq (getf env :request-method) :options)
              (list 204 (cors-headers) '(""))
              (let ((response (funcall handler env)))
                (if (listp response)
                    (list (first response)
                          (append (second response) (cors-headers))
                          (third response))
                    response))))))))
