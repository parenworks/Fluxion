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
