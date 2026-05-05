;;;; -*- encoding:utf-8 -*-
;;;; Tests for the middleware / hook system

(in-package #:fluxion.tests)
(in-suite middleware-suite)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defun make-echo-handler ()
  "A trivial Clack handler that echoes back the request path and method."
  (lambda (env)
    (list 200
          '(:content-type "text/plain")
          (list (format nil "~A ~A"
                        (getf env :request-method)
                        (getf env :path-info "/"))))))

(defun make-mw-test-env (&key (method :get) (path "/") headers)
  "Build a minimal Clack-style env plist for testing."
  (let ((h (or headers (make-hash-table :test 'equal))))
    (list :request-method method
          :path-info path
          :headers h)))

;;; -------------------------------------------------------
;;; Middleware chain mechanics
;;; -------------------------------------------------------

(test middleware-empty-chain
  "With no middleware, wrap-handler returns the original handler."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler))
         (wrapped (fluxion.server:wrap-handler handler app))
         (response (funcall wrapped (make-mw-test-env :path "/hello"))))
    (is (= 200 (first response)))
    (is (string= "GET /hello" (first (third response))))))

(test middleware-single-wrap
  "A single middleware wraps the handler."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    ;; Middleware that adds an X-Test header to every response
    (fluxion.server:add-middleware app
      (lambda (next)
        (lambda (env)
          (let ((response (funcall next env)))
            (list (first response)
                  (append (second response) '(:x-test "yes"))
                  (third response)))))
      :name :test-header)
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env))))
      (is (= 200 (first response)))
      (is (string= "yes" (getf (second response) :x-test))))))

(test middleware-ordering
  "Middleware executes in registration order (first = outermost)."
  (let* ((app (fluxion.server:make-fluxion-app))
         (log nil)
         (handler (lambda (env)
                    (declare (ignore env))
                    (push :handler log)
                    '(200 () ("ok")))))
    ;; First registered = outermost = runs first on request, last on response
    (fluxion.server:add-middleware app
      (lambda (next)
        (lambda (env)
          (push :outer-before log)
          (let ((r (funcall next env)))
            (push :outer-after log)
            r)))
      :name :outer)
    (fluxion.server:add-middleware app
      (lambda (next)
        (lambda (env)
          (push :inner-before log)
          (let ((r (funcall next env)))
            (push :inner-after log)
            r)))
      :name :inner)
    (let ((wrapped (fluxion.server:wrap-handler handler app)))
      (funcall wrapped (make-mw-test-env)))
    ;; Log is in reverse push order
    (is (equal '(:outer-after :inner-after :handler :inner-before :outer-before)
               log))))

(test middleware-remove
  "Middleware can be removed by name."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (lambda (next)
        (lambda (env)
          (declare (ignore env next))
          '(403 () ("blocked"))))
      :name :blocker)
    ;; Verify it blocks
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env))))
      (is (= 403 (first response))))
    ;; Remove and verify pass-through
    (fluxion.server:remove-middleware app :blocker)
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env))))
      (is (= 200 (first response))))))

(test middleware-clear
  "clear-middleware removes all middleware."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (lambda (next)
        (lambda (env) (declare (ignore env next)) '(403 () ("no"))))
      :name :a)
    (fluxion.server:add-middleware app
      (lambda (next)
        (lambda (env) (declare (ignore env next)) '(503 () ("no"))))
      :name :b)
    (fluxion.server:clear-middleware app)
    (is (null (fluxion.server:app-middleware app)))
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env))))
      (is (= 200 (first response))))))

(test middleware-short-circuit
  "Middleware can short-circuit and skip the handler entirely."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler-called nil)
         (handler (lambda (env)
                    (declare (ignore env))
                    (setf handler-called t)
                    '(200 () ("ok")))))
    (fluxion.server:add-middleware app
      (lambda (next)
        (declare (ignore next))
        (lambda (env)
          (declare (ignore env))
          '(401 () ("Unauthorized"))))
      :name :auth-guard)
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env))))
      (is (= 401 (first response)))
      (is (null handler-called)))))

;;; -------------------------------------------------------
;;; Built-in: request logger
;;; -------------------------------------------------------

(test request-logger-output
  "make-request-logger logs method, path, status, and timing."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler))
         (log-output (make-string-output-stream)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-request-logger :stream log-output)
      :name :logger)
    (let ((wrapped (fluxion.server:wrap-handler handler app)))
      (funcall wrapped (make-mw-test-env :method :post :path "/action/test/click")))
    (let ((log-str (get-output-stream-string log-output)))
      (is (search "POST" log-str))
      (is (search "/action/test/click" log-str))
      (is (search "200" log-str))
      (is (search "ms" log-str)))))

(test request-logger-skip-health
  "make-request-logger with :skip-health T omits GET /health."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler))
         (log-output (make-string-output-stream)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-request-logger :stream log-output :skip-health t)
      :name :logger)
    (let ((wrapped (fluxion.server:wrap-handler handler app)))
      (funcall wrapped (make-mw-test-env :method :get :path "/health"))
      (funcall wrapped (make-mw-test-env :method :get :path "/other")))
    (let ((log-str (get-output-stream-string log-output)))
      (is (null (search "/health" log-str)))
      (is (search "/other" log-str)))))

;;; -------------------------------------------------------
;;; Built-in: rate limiter
;;; -------------------------------------------------------

(test rate-limiter-allows-within-burst
  "Requests within burst limit are allowed."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-rate-limiter :requests-per-second 100 :burst 5)
      :name :limiter)
    (let ((wrapped (fluxion.server:wrap-handler handler app)))
      ;; First 5 requests should all succeed (burst = 5)
      (dotimes (i 5)
        (let ((response (funcall wrapped (make-mw-test-env))))
          (is (= 200 (first response))))))))

(test rate-limiter-rejects-over-burst
  "Requests over the burst limit return 429."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-rate-limiter :requests-per-second 1 :burst 2)
      :name :limiter)
    (let ((wrapped (fluxion.server:wrap-handler handler app)))
      ;; Use up the burst
      (funcall wrapped (make-mw-test-env))
      (funcall wrapped (make-mw-test-env))
      ;; Third request should be rejected
      (let ((response (funcall wrapped (make-mw-test-env))))
        (is (= 429 (first response)))))))

(test rate-limiter-per-client
  "Per-client rate limiting tracks clients independently."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-rate-limiter
       :requests-per-second 1 :burst 1
       :key-fn (lambda (env) (getf env :path-info "/")))
      :name :limiter)
    (let ((wrapped (fluxion.server:wrap-handler handler app)))
      ;; Client A uses up its budget
      (funcall wrapped (make-mw-test-env :path "/a"))
      (let ((r (funcall wrapped (make-mw-test-env :path "/a"))))
        (is (= 429 (first r))))
      ;; Client B still has budget
      (let ((r (funcall wrapped (make-mw-test-env :path "/b"))))
        (is (= 200 (first r)))))))

;;; -------------------------------------------------------
;;; Built-in: CORS
;;; -------------------------------------------------------

(test cors-preflight
  "OPTIONS preflight returns 204 with CORS headers."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-cors-middleware)
      :name :cors)
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env :method :options))))
      (is (= 204 (first response)))
      (is (string= "*" (getf (second response) :access-control-allow-origin))))))

(test cors-normal-request
  "Normal requests get CORS headers appended."
  (let* ((app (fluxion.server:make-fluxion-app))
         (handler (make-echo-handler)))
    (fluxion.server:add-middleware app
      (fluxion.server:make-cors-middleware)
      :name :cors)
    (let* ((wrapped (fluxion.server:wrap-handler handler app))
           (response (funcall wrapped (make-mw-test-env))))
      (is (= 200 (first response)))
      (is (string= "*" (getf (second response) :access-control-allow-origin))))))
