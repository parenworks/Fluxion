;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.server router

(in-package #:fluxion.tests)
(in-suite router-suite)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defun make-test-env (method path)
  "Create a minimal Clack-like ENV plist for testing."
  (let ((headers (make-hash-table :test 'equal)))
    (list :request-method method
          :path-info path
          :headers headers)))

(defun ok-handler (app session env &key params)
  "A simple handler that returns 200 with the params as body."
  (declare (ignore app session env))
  (list 200
        '(:content-type "text/plain")
        (list (format nil "~S" params))))

;;; -------------------------------------------------------
;;; Pattern parsing
;;; -------------------------------------------------------

(test parse-pattern-simple
  "Parsing a simple path produces literal segments."
  (let ((segs (fluxion.server::parse-pattern "/users/list")))
    (is (equal '("users" "list") segs))))

(test parse-pattern-with-params
  "Parsing a path with :params produces keyword segments."
  (let ((segs (fluxion.server::parse-pattern "/users/:id/posts")))
    (is (equal '("users" :id "posts") segs))))

(test parse-pattern-root
  "Parsing root path produces empty list."
  (let ((segs (fluxion.server::parse-pattern "/")))
    (is (null segs))))

(test parse-pattern-single-param
  "Parsing /:slug produces a single keyword."
  (let ((segs (fluxion.server::parse-pattern "/:slug")))
    (is (equal '(:slug) segs))))

;;; -------------------------------------------------------
;;; Route matching
;;; -------------------------------------------------------

(test match-route-exact
  "Exact literal path matches."
  (let ((route (make-instance 'fluxion.server::route
                              :method :get
                              :pattern "/about"
                              :segments (fluxion.server::parse-pattern "/about")
                              :handler #'ok-handler)))
    (multiple-value-bind (matched params)
        (fluxion.server::match-route route "/about" :get)
      (is-true matched)
      (is (null params)))))

(test match-route-with-param
  "Path with parameter extracts the value."
  (let ((route (make-instance 'fluxion.server::route
                              :method :get
                              :pattern "/users/:id"
                              :segments (fluxion.server::parse-pattern "/users/:id")
                              :handler #'ok-handler)))
    (multiple-value-bind (matched params)
        (fluxion.server::match-route route "/users/42" :get)
      (is-true matched)
      (is (string= "42" (cdr (assoc :id params)))))))

(test match-route-multiple-params
  "Multiple parameters are extracted."
  (let ((route (make-instance 'fluxion.server::route
                              :method :get
                              :pattern "/users/:uid/posts/:pid"
                              :segments (fluxion.server::parse-pattern "/users/:uid/posts/:pid")
                              :handler #'ok-handler)))
    (multiple-value-bind (matched params)
        (fluxion.server::match-route route "/users/alice/posts/7" :get)
      (is-true matched)
      (is (string= "alice" (cdr (assoc :uid params))))
      (is (string= "7" (cdr (assoc :pid params)))))))

(test match-route-wrong-method
  "Wrong HTTP method does not match."
  (let ((route (make-instance 'fluxion.server::route
                              :method :post
                              :pattern "/submit"
                              :segments (fluxion.server::parse-pattern "/submit")
                              :handler #'ok-handler)))
    (is-false (fluxion.server::match-route route "/submit" :get))))

(test match-route-any-method
  ":any method matches any HTTP method."
  (let ((route (make-instance 'fluxion.server::route
                              :method :any
                              :pattern "/health"
                              :segments (fluxion.server::parse-pattern "/health")
                              :handler #'ok-handler)))
    (is-true (fluxion.server::match-route route "/health" :get))
    (is-true (fluxion.server::match-route route "/health" :post))))

(test match-route-wrong-path
  "Non-matching path does not match."
  (let ((route (make-instance 'fluxion.server::route
                              :method :get
                              :pattern "/about"
                              :segments (fluxion.server::parse-pattern "/about")
                              :handler #'ok-handler)))
    (is-false (fluxion.server::match-route route "/contact" :get))))

(test match-route-wrong-length
  "Different segment count does not match."
  (let ((route (make-instance 'fluxion.server::route
                              :method :get
                              :pattern "/users/:id"
                              :segments (fluxion.server::parse-pattern "/users/:id")
                              :handler #'ok-handler)))
    (is-false (fluxion.server::match-route route "/users" :get))
    (is-false (fluxion.server::match-route route "/users/1/extra" :get))))

(test match-route-root
  "Root path matches root pattern."
  (let ((route (make-instance 'fluxion.server::route
                              :method :get
                              :pattern "/"
                              :segments (fluxion.server::parse-pattern "/")
                              :handler #'ok-handler)))
    (is-true (fluxion.server::match-route route "/" :get))))

;;; -------------------------------------------------------
;;; Router dispatch
;;; -------------------------------------------------------

(test router-basic-dispatch
  "Router dispatches to the correct handler."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (fluxion.server:add-route r :get "/hello"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("hello"))))
    (let ((resp (fluxion.server:dispatch-route r app session
                  (make-test-env :get "/hello"))))
      (is (= 200 (first resp)))
      (is (string= "hello" (first (third resp)))))))

(test router-404-default
  "Router returns 404 when no route matches."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (let ((resp (fluxion.server:dispatch-route r app session
                  (make-test-env :get "/nope"))))
      (is (= 404 (first resp))))))

(test router-custom-not-found
  "Router calls custom not-found handler."
  (let ((r (fluxion.server:make-router
             :not-found-handler (lambda (app session env)
                                  (declare (ignore app session env))
                                  (list 404 nil '("custom 404")))))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (let ((resp (fluxion.server:dispatch-route r app session
                  (make-test-env :get "/nope"))))
      (is (string= "custom 404" (first (third resp)))))))

(test router-params-passed
  "Router passes extracted path params to the handler."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt"))
        (captured-params nil))
    (fluxion.server:add-route r :get "/items/:id"
      (lambda (app session env &key params)
        (declare (ignore app session env))
        (setf captured-params params)
        (list 200 nil '("ok"))))
    (fluxion.server:dispatch-route r app session
      (make-test-env :get "/items/99"))
    (is (string= "99" (cdr (assoc :id captured-params))))))

(test router-first-match-wins
  "When multiple routes could match, the first registered one wins."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (fluxion.server:add-route r :get "/test"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("first"))))
    (fluxion.server:add-route r :get "/test"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("second"))))
    (let ((resp (fluxion.server:dispatch-route r app session
                  (make-test-env :get "/test"))))
      (is (string= "first" (first (third resp)))))))

(test router-guard-blocks
  "Route guard can block dispatch and return its own response."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (fluxion.server:add-route r :get "/secret"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("secret content")))
      :guard (lambda (session)
               (declare (ignore session))
               (list 401 nil '("not allowed"))))
    (let ((resp (fluxion.server:dispatch-route r app session
                  (make-test-env :get "/secret"))))
      (is (= 401 (first resp))))))

(test router-guard-passes
  "Route guard returning NIL lets the handler run."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (fluxion.server:add-route r :get "/public"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("welcome")))
      :guard (lambda (session)
               (declare (ignore session))
               nil))
    (let ((resp (fluxion.server:dispatch-route r app session
                  (make-test-env :get "/public"))))
      (is (= 200 (first resp))))))

(test router-handler-bridge
  "router-handler returns a callable page-handler."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (fluxion.server:add-route r :get "/"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("home"))))
    (let* ((handler (fluxion.server:router-handler r))
           (resp (funcall handler app session (make-test-env :get "/"))))
      (is (= 200 (first resp))))))

(test router-method-isolation
  "GET route does not match POST and vice versa."
  (let ((r (fluxion.server:make-router))
        (app (fluxion.server:make-fluxion-app))
        (session (make-instance 'fluxion.server:session :id "rt")))
    (fluxion.server:add-route r :get "/form"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("get"))))
    (fluxion.server:add-route r :post "/form"
      (lambda (app session env &key params)
        (declare (ignore app session env params))
        (list 200 nil '("post"))))
    (let ((get-resp (fluxion.server:dispatch-route r app session
                      (make-test-env :get "/form")))
          (post-resp (fluxion.server:dispatch-route r app session
                       (make-test-env :post "/form"))))
      (is (string= "get" (first (third get-resp))))
      (is (string= "post" (first (third post-resp)))))))
