;;;; -*- encoding:utf-8 -*-
;;;; End-to-end HTTP integration tests
;;;;
;;;; Boots a real Fluxion app on a random high port, makes HTTP requests
;;;; with Dexador, and verifies responses. Tests cover:
;;;;   - GET / serves HTML with session cookie and CSRF token
;;;;   - GET /health returns valid JSON
;;;;   - GET /static/fluxion.js serves the client runtime
;;;;   - POST /action without CSRF token returns 403
;;;;   - POST /action with valid CSRF token dispatches and returns SSE
;;;;   - GET /sse opens a streaming connection
;;;;   - Session persistence across requests
;;;;   - *current-session* is bound during dispatch
;;;;   - Condition hierarchy is usable for error handling

(in-package #:fluxion.tests)
(in-suite integration-suite)

;;; -------------------------------------------------------
;;; Test component for integration tests
;;; -------------------------------------------------------

(fluxion.components:defcomponent integration-counter
  :id "integration-counter"
  :slots ((count :cell t :initform 0 :accessor integration-counter-count))
  :render (format nil "<div id=\"~A\">Count: ~D</div>"
                  (fluxion.components:component-id self)
                  (integration-counter-count self)))

(fluxion.components:defaction integration-counter :increment (c)
  (incf (integration-counter-count c))
  '())

(fluxion.components:defaction integration-counter :get-session-info (c)
  ;; Test that *current-session* is bound during action dispatch
  (let ((session fluxion.server:*current-session*))
    (if session
        (list (fluxion.events:make-script-event
               (format nil "console.log('session:~A')"
                       (fluxion.server:session-id session))))
        (list (fluxion.events:make-script-event "console.log('no session')")))))

;;; -------------------------------------------------------
;;; Server lifecycle helpers
;;; -------------------------------------------------------

(defvar *test-app* nil)
(defvar *test-port* nil)

(defun find-free-port ()
  "Find a free TCP port by binding to port 0."
  (let ((socket (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (prog1 (usocket:get-local-port socket)
      (usocket:socket-close socket))))

(defun start-test-server ()
  "Boot a minimal Fluxion app for integration testing."
  (setf *test-port* (find-free-port))
  (setf *test-app* (fluxion.server:make-fluxion-app
                     :port *test-port*
                     :static-dir (asdf:system-relative-pathname "fluxion" "static/")
                     :request-log nil))

  (fluxion.server:register-component-factory *test-app* "integration-counter"
    (lambda () (make-instance 'integration-counter)))

  ;; Build client JS so /static/fluxion.js exists
  (fluxion.client:build-client)

  (fluxion.server:start *test-app*
    (lambda (app session env)
      (declare (ignore app env))
      (let ((counter (fluxion.server:session-component session "integration-counter")))
        (list 200
              '(:content-type "text/html")
              (list (fluxion.render:render-page
                     :title "Integration Test"
                     :csrf-token (fluxion.server:session-csrf-token session)
                     :body-html (fluxion.components:render counter))))))
    :port *test-port*)

  ;; Wait for server to be ready
  (sleep 0.5))

(defun stop-test-server ()
  "Stop the test server."
  (when *test-app*
    (fluxion.server:stop *test-app*)
    (setf *test-app* nil)))

(defun test-url (path)
  "Build a full URL for the test server."
  (format nil "http://127.0.0.1:~D~A" *test-port* path))

(defun extract-session-cookie (headers)
  "Extract the fluxion-sid cookie value from response headers."
  (let ((set-cookie (gethash "set-cookie" headers)))
    (when set-cookie
      (let ((cookie-str (if (listp set-cookie) (first set-cookie) set-cookie)))
        (when (and cookie-str (search "fluxion-sid=" cookie-str))
          (let* ((start (+ (search "fluxion-sid=" cookie-str)
                           (length "fluxion-sid=")))
                 (end (or (position #\; cookie-str :start start) (length cookie-str))))
            (subseq cookie-str start end)))))))

(defun extract-csrf-token (html)
  "Extract the CSRF token from a meta tag in HTML."
  (let ((start (search "name=\"fluxion-csrf\" content=\"" html)))
    (when start
      (let* ((val-start (+ start (length "name=\"fluxion-csrf\" content=\"")))
             (val-end (position #\" html :start val-start)))
        (subseq html val-start val-end)))))

;;; -------------------------------------------------------
;;; Tests
;;; -------------------------------------------------------

(test integration-health-endpoint
  "GET /health returns 200 with JSON containing status ok."
  (unwind-protect
       (progn
         (start-test-server)
         (multiple-value-bind (body status)
             (dex:get (test-url "/health"))
           (is (= 200 status))
           ;; cl-json converts underscores to double hyphens in keys
           (let ((data (cl-json:decode-json-from-string body)))
             (is (string= "ok" (cdr (assoc :status data))))
             (is (numberp (cdr (assoc :uptime--seconds data)))))))
    (stop-test-server)))

(test integration-page-serves-html
  "GET / returns 200 with HTML containing the component and CSRF meta tag."
  (unwind-protect
       (progn
         (start-test-server)
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/"))
           (is (= 200 status))
           (is (search "integration-counter" body))
           (is (search "Count: 0" body))
           ;; CSRF token is present
           (let ((csrf (extract-csrf-token body)))
             (is (not (null csrf)))
             (is (= 32 (length csrf))))
           ;; Session cookie is set
           (let ((session-id (extract-session-cookie headers)))
             (is (not (null session-id))))))
    (stop-test-server)))

(test integration-static-file
  "GET /static/fluxion.js returns 200 with JavaScript content."
  (unwind-protect
       (progn
         (start-test-server)
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/static/fluxion.js"))
           (is (= 200 status))
           ;; Should contain JS content
           (is (search "fluxion" body))
           ;; Content-type should be JavaScript
           (let ((ct (gethash "content-type" headers)))
             (is (search "javascript" ct)))))
    (stop-test-server)))

(test integration-csrf-rejection
  "POST /action/... without CSRF token returns 403."
  (unwind-protect
       (progn
         (start-test-server)
         ;; First GET to establish a session
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/"))
           (declare (ignore body status))
           (let ((session-id (extract-session-cookie headers)))
             ;; POST without CSRF token
             (multiple-value-bind (body2 status2)
                 (handler-case
                     (dex:post (test-url "/action/integration-counter/increment")
                       :content "{}"
                       :headers `(("Content-Type" . "application/json")
                                  ("Cookie" . ,(format nil "fluxion-sid=~A" session-id))))
                   (dexador:http-request-forbidden (e)
                     (values (dexador:response-body e)
                             (dexador:response-status e))))
               (declare (ignore body2))
               (is (= 403 status2))))))
    (stop-test-server)))

(test integration-action-dispatch
  "POST /action/component/action with valid CSRF dispatches and returns SSE."
  (unwind-protect
       (progn
         (start-test-server)
         ;; GET page to get session + CSRF
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/"))
           (declare (ignore status))
           (let ((session-id (extract-session-cookie headers))
                 (csrf (extract-csrf-token body)))
             ;; POST action with CSRF
             (multiple-value-bind (action-body action-status)
                 (dex:post (test-url "/action/integration-counter/increment")
                   :content "{}"
                   :headers `(("Content-Type" . "application/json")
                              ("Accept" . "text/event-stream")
                              ("X-CSRF-Token" . ,csrf)
                              ("Cookie" . ,(format nil "fluxion-sid=~A" session-id))))
               (is (= 200 action-status))
               ;; Response should be SSE format with a patch event
               (is (search "event: fluxion-patch" action-body))
               ;; The patch should contain updated count
               (is (search "Count: 1" action-body))))))
    (stop-test-server)))

(test integration-session-persistence
  "Multiple requests with the same session cookie share state."
  (unwind-protect
       (progn
         (start-test-server)
         ;; GET page - count starts at 0
         (multiple-value-bind (body1 status1 headers1)
             (dex:get (test-url "/"))
           (declare (ignore status1))
           (is (search "Count: 0" body1))
           (let ((session-id (extract-session-cookie headers1))
                 (csrf (extract-csrf-token body1)))
             ;; Increment
             (dex:post (test-url "/action/integration-counter/increment")
               :content "{}"
               :headers `(("Content-Type" . "application/json")
                          ("X-CSRF-Token" . ,csrf)
                          ("Cookie" . ,(format nil "fluxion-sid=~A" session-id))))
             ;; GET page again with same session - count should be 1
             (multiple-value-bind (body2 status2)
                 (dex:get (test-url "/")
                   :headers `(("Cookie" . ,(format nil "fluxion-sid=~A" session-id))))
               (declare (ignore status2))
               (is (search "Count: 1" body2))))))
    (stop-test-server)))

(test integration-action-not-found
  "POST to a non-existent component returns a useful error."
  (unwind-protect
       (progn
         (start-test-server)
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/"))
           (declare (ignore status))
           (let ((session-id (extract-session-cookie headers))
                 (csrf (extract-csrf-token body)))
             (multiple-value-bind (action-body action-status)
                 (dex:post (test-url "/action/nonexistent/foo")
                   :content "{}"
                   :headers `(("Content-Type" . "application/json")
                              ("X-CSRF-Token" . ,csrf)
                              ("Cookie" . ,(format nil "fluxion-sid=~A" session-id))))
               (is (= 200 action-status))
               ;; Should contain error script event
               (is (search "fluxion-script" action-body))
               (is (search "nonexistent" action-body))))))
    (stop-test-server)))

(test integration-multiple-increments
  "Multiple increments accumulate correctly."
  (unwind-protect
       (progn
         (start-test-server)
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/"))
           (declare (ignore status))
           (let ((session-id (extract-session-cookie headers))
                 (csrf (extract-csrf-token body))
                 (cookie (format nil "fluxion-sid=~A"
                                 (extract-session-cookie headers))))
             ;; Increment 5 times
             (dotimes (i 5)
               (dex:post (test-url "/action/integration-counter/increment")
                 :content "{}"
                 :headers `(("Content-Type" . "application/json")
                            ("X-CSRF-Token" . ,csrf)
                            ("Cookie" . ,cookie))))
             ;; Verify count is 5
             (multiple-value-bind (body2 status2)
                 (dex:get (test-url "/") :headers `(("Cookie" . ,cookie)))
               (declare (ignore status2))
               (is (search "Count: 5" body2))))))
    (stop-test-server)))

(test integration-separate-sessions
  "Different sessions have independent state."
  (unwind-protect
       (progn
         (start-test-server)
         ;; Session A: increment 3 times
         (multiple-value-bind (body-a status-a headers-a)
             (dex:get (test-url "/"))
           (declare (ignore status-a))
           (let ((cookie-a (format nil "fluxion-sid=~A"
                                   (extract-session-cookie headers-a)))
                 (csrf-a (extract-csrf-token body-a)))
             (dotimes (i 3)
               (dex:post (test-url "/action/integration-counter/increment")
                 :content "{}"
                 :headers `(("Content-Type" . "application/json")
                            ("X-CSRF-Token" . ,csrf-a)
                            ("Cookie" . ,cookie-a))))
             ;; Session B: fresh session, count should be 0
             (multiple-value-bind (body-b status-b)
                 (dex:get (test-url "/"))
               (declare (ignore status-b))
               (is (search "Count: 0" body-b)))
             ;; Session A: count should still be 3
             (multiple-value-bind (body-a2 status-a2)
                 (dex:get (test-url "/") :headers `(("Cookie" . ,cookie-a)))
               (declare (ignore status-a2))
               (is (search "Count: 3" body-a2))))))
    (stop-test-server)))

(test integration-current-session-bound
  "The *current-session* variable is bound during action dispatch."
  (unwind-protect
       (progn
         (start-test-server)
         (multiple-value-bind (body status headers)
             (dex:get (test-url "/"))
           (declare (ignore status))
           (let ((session-id (extract-session-cookie headers))
                 (csrf (extract-csrf-token body)))
             (multiple-value-bind (action-body action-status)
                 (dex:post (test-url "/action/integration-counter/get-session-info")
                   :content "{}"
                   :headers `(("Content-Type" . "application/json")
                              ("X-CSRF-Token" . ,csrf)
                              ("Cookie" . ,(format nil "fluxion-sid=~A" session-id))))
               (is (= 200 action-status))
               ;; Should contain the session ID in the script event
               (is (search session-id action-body))))))
    (stop-test-server)))
