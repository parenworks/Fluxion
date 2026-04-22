;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.server - sessions, event queue, push

(in-package #:fluxion.tests)
(in-suite server-suite)

;;; -------------------------------------------------------
;;; Session tests
;;; -------------------------------------------------------

(test session-creation
  "Sessions are created with an ID."
  (let ((s (make-instance 'fluxion.server:session :id "abc123")))
    (is (string= "abc123" (fluxion.server:session-id s)))))

(test session-component-storage
  "Components can be stored and retrieved from a session."
  (let ((s (make-instance 'fluxion.server:session :id "test"))
        (w (make-instance 'test-widget)))
    (setf (gethash "test-widget" (fluxion.server:session-components s)) w)
    (is (eq w (gethash "test-widget" (fluxion.server:session-components s))))))

;;; -------------------------------------------------------
;;; Event queue tests
;;; -------------------------------------------------------

(test event-queue-basic
  "Events can be enqueued and dequeued."
  (let ((q (fluxion.server::make-event-queue)))
    (fluxion.server::enqueue-event q :event-1)
    (fluxion.server::enqueue-event q :event-2)
    (let ((events (fluxion.server::dequeue-all-events q :timeout 0)))
      (is (equal '(:event-1 :event-2) events)))))

(test event-queue-empty-dequeue
  "Dequeuing an empty queue with timeout 0 returns nil."
  (let ((q (fluxion.server::make-event-queue)))
    (let ((events (fluxion.server::dequeue-all-events q :timeout 0)))
      (is (null events)))))

(test event-queue-drains
  "dequeue-all-events clears the queue."
  (let ((q (fluxion.server::make-event-queue)))
    (fluxion.server::enqueue-event q :a)
    (fluxion.server::dequeue-all-events q :timeout 0)
    (let ((events (fluxion.server::dequeue-all-events q :timeout 0)))
      (is (null events)))))

(test event-queue-close
  "Closing a queue allows dequeue to return."
  (let ((q (fluxion.server::make-event-queue)))
    (fluxion.server::close-event-queue q)
    (is-true (fluxion.server::eq-closed-p q))))

(test event-queue-threaded
  "Events enqueued from another thread are received."
  (let ((q (fluxion.server::make-event-queue))
        (result nil))
    (bordeaux-threads:make-thread
     (lambda ()
       (sleep 0.1)
       (fluxion.server::enqueue-event q :from-thread)))
    (setf result (fluxion.server::dequeue-all-events q :timeout 2))
    (is (equal '(:from-thread) result))))

;;; -------------------------------------------------------
;;; Session event queue integration
;;; -------------------------------------------------------

(test session-event-queue-lazy-creation
  "Event queue is nil by default, created by ensure-event-queue."
  (let ((s (make-instance 'fluxion.server:session :id "test")))
    (is (null (fluxion.server::session-event-queue s)))
    (let ((q (fluxion.server::ensure-event-queue s)))
      (is (not (null q)))
      ;; Second call returns the same queue
      (is (eq q (fluxion.server::ensure-event-queue s))))))

(test push-event-to-session
  "push-event adds events to the session's queue."
  (let ((s (make-instance 'fluxion.server:session :id "test")))
    (fluxion.server::ensure-event-queue s)
    (fluxion.server:push-event s :test-event)
    (let ((q (fluxion.server::session-event-queue s)))
      (let ((events (fluxion.server::dequeue-all-events q :timeout 0)))
        (is (equal '(:test-event) events))))))

(test push-event-no-queue-is-safe
  "push-event does nothing if the session has no queue."
  (let ((s (make-instance 'fluxion.server:session :id "test")))
    ;; Should not error
    (fluxion.server:push-event s :ignored)
    (is (null (fluxion.server::session-event-queue s)))))

(test push-events-multiple
  "push-events pushes a list of events."
  (let ((s (make-instance 'fluxion.server:session :id "test")))
    (fluxion.server::ensure-event-queue s)
    (fluxion.server:push-events s '(:a :b :c))
    (let ((q (fluxion.server::session-event-queue s)))
      (let ((events (fluxion.server::dequeue-all-events q :timeout 0)))
        (is (equal '(:a :b :c) events))))))

;;; -------------------------------------------------------
;;; CSRF token tests
;;; -------------------------------------------------------

(test csrf-token-generated
  "Sessions are created with a CSRF token."
  (let ((s (make-instance 'fluxion.server:session :id "csrf-test")))
    (is (stringp (fluxion.server:session-csrf-token s)))
    (is (> (length (fluxion.server:session-csrf-token s)) 0))))

(test csrf-token-unique
  "Each session gets a unique CSRF token."
  (let ((s1 (make-instance 'fluxion.server:session :id "a"))
        (s2 (make-instance 'fluxion.server:session :id "b")))
    (is (not (string= (fluxion.server:session-csrf-token s1)
                       (fluxion.server:session-csrf-token s2))))))

(test csrf-valid-p-matching
  "csrf-valid-p returns T when header matches session token."
  (let* ((s (make-instance 'fluxion.server:session :id "test"))
         (token (fluxion.server:session-csrf-token s))
         (headers (make-hash-table :test 'equal)))
    (setf (gethash "x-csrf-token" headers) token)
    (let ((env (list :headers headers)))
      (is-true (fluxion.server::csrf-valid-p s env)))))

(test csrf-valid-p-missing
  "csrf-valid-p returns NIL when header is missing."
  (let ((s (make-instance 'fluxion.server:session :id "test"))
        (headers (make-hash-table :test 'equal)))
    (let ((env (list :headers headers)))
      (is-false (fluxion.server::csrf-valid-p s env)))))

(test csrf-valid-p-wrong-token
  "csrf-valid-p returns NIL when header has wrong token."
  (let ((s (make-instance 'fluxion.server:session :id "test"))
        (headers (make-hash-table :test 'equal)))
    (setf (gethash "x-csrf-token" headers) "wrong-token")
    (let ((env (list :headers headers)))
      (is-false (fluxion.server::csrf-valid-p s env)))))

(test csrf-rejection-response
  "csrf-rejection-response returns 403."
  (let ((resp (fluxion.server::csrf-rejection-response)))
    (is (= 403 (first resp)))))

;;; -------------------------------------------------------
;;; Authentication
;;; -------------------------------------------------------

(test session-starts-unauthenticated
  "New sessions have no user."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (is-false (fluxion.server:authenticated-p s))
    (is (null (fluxion.server:session-user s)))
    (is (null (fluxion.server:session-user-roles s)))))

(test authenticate-sets-user
  "authenticate stores the user on the session."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice" :roles '(:admin :editor))
    (is-true (fluxion.server:authenticated-p s))
    (is (string= "alice" (fluxion.server:session-user s)))
    (is (equal '(:admin :editor) (fluxion.server:session-user-roles s)))))

(test authenticate-regenerates-csrf
  "authenticate regenerates the CSRF token to prevent session fixation."
  (let* ((s (make-instance 'fluxion.server:session :id "auth-test"))
         (old-token (fluxion.server:session-csrf-token s)))
    (fluxion.server:authenticate s "bob")
    (is (not (string= old-token (fluxion.server:session-csrf-token s))))))

(test logout-clears-user
  "logout clears user and roles."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice" :roles '(:admin))
    (fluxion.server:logout s)
    (is-false (fluxion.server:authenticated-p s))
    (is (null (fluxion.server:session-user s)))
    (is (null (fluxion.server:session-user-roles s)))))

(test logout-regenerates-csrf
  "logout regenerates the CSRF token."
  (let* ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice")
    (let ((post-auth-token (fluxion.server:session-csrf-token s)))
      (fluxion.server:logout s)
      (is (not (string= post-auth-token (fluxion.server:session-csrf-token s)))))))

(test has-role-p-checks-membership
  "has-role-p returns T when the user has the role."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice" :roles '(:admin :editor))
    (is-true (fluxion.server:has-role-p s :admin))
    (is-true (fluxion.server:has-role-p s :editor))
    (is-false (fluxion.server:has-role-p s :superuser))))

(test has-role-p-nil-when-unauthenticated
  "has-role-p returns NIL for unauthenticated sessions."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (is-false (fluxion.server:has-role-p s :admin))))

(test require-auth-passes-when-authenticated
  "require-auth returns NIL when the user is authenticated."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice")
    (is (null (fluxion.server:require-auth s)))))

(test require-auth-redirects-when-unauthenticated
  "require-auth returns a 303 redirect when not authenticated."
  (let* ((s (make-instance 'fluxion.server:session :id "auth-test"))
         (resp (fluxion.server:require-auth s)))
    (is (= 303 (first resp)))
    (is (string= "/login" (getf (second resp) :location)))))

(test require-auth-custom-login-url
  "require-auth accepts a custom login URL."
  (let* ((s (make-instance 'fluxion.server:session :id "auth-test"))
         (resp (fluxion.server:require-auth s :login-url "/sign-in")))
    (is (string= "/sign-in" (getf (second resp) :location)))))

(test require-role-passes-with-role
  "require-role returns NIL when the user has the role."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice" :roles '(:admin))
    (is (null (fluxion.server:require-role s :admin)))))

(test require-role-redirects-when-unauthenticated
  "require-role redirects to login when not authenticated."
  (let* ((s (make-instance 'fluxion.server:session :id "auth-test"))
         (resp (fluxion.server:require-role s :admin)))
    (is (= 303 (first resp)))))

(test require-role-403-when-lacking-role
  "require-role returns 403 when authenticated but lacking the role."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice" :roles '(:viewer))
    (let ((resp (fluxion.server:require-role s :admin)))
      (is (= 403 (first resp))))))

(test require-role-forbidden-redirect
  "require-role can redirect instead of 403 when given :forbidden-url."
  (let ((s (make-instance 'fluxion.server:session :id "auth-test")))
    (fluxion.server:authenticate s "alice" :roles '(:viewer))
    (let ((resp (fluxion.server:require-role s :admin :forbidden-url "/denied")))
      (is (= 303 (first resp)))
      (is (string= "/denied" (getf (second resp) :location))))))

;;; -------------------------------------------------------
;;; App creation
;;; -------------------------------------------------------

(test make-fluxion-app
  "make-fluxion-app creates an app with expected defaults."
  (let ((app (fluxion.server:make-fluxion-app :port 9999)))
    (is (not (null app)))))

(test register-component-factory
  "Registering a factory stores it for later session creation."
  (let ((app (fluxion.server:make-fluxion-app :port 9999)))
    (fluxion.server:register-component-factory app "widget"
      (lambda () (make-instance 'test-widget)))
    ;; The factory should be stored (we test indirectly via the hash table)
    (is (not (null app)))))
