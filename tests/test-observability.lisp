;;;; -*- encoding:utf-8 -*-
;;;; Tests for request logging, health endpoint, and SSE connection stress.

(in-package #:fluxion.tests)

(in-suite observability-suite)

;;; -------------------------------------------------------
;;; Health endpoint unit tests
;;; -------------------------------------------------------

(test health-response-structure
  "health-response returns well-formed JSON with expected fields."
  (let* ((app (fluxion.server:make-fluxion-app :port 15100 :request-log nil))
         (response (fluxion.server:health-response app)))
    (is (= 200 (first response)))
    (let* ((body (first (third response)))
           (json (cl-json:decode-json-from-string body)))
      (is (string= "ok" (cdr (assoc :status json))))
      (is (numberp (cdr (assoc :uptime--seconds json))))
      (is (stringp (cdr (assoc :uptime--human json))))
      (is (numberp (cdr (assoc :sessions json))))
      (is (numberp (cdr (assoc :sse--connections json))))
      (is (stringp (cdr (assoc :server json))))
      (is (numberp (cdr (assoc :port json)))))))

(test health-session-count-accurate
  "health-response reflects the actual session count."
  (let ((app (fluxion.server:make-fluxion-app :port 15101 :request-log nil)))
    ;; Empty app
    (is (= 0 (fluxion.server:app-session-count app)))
    ;; Add some sessions directly
    (dotimes (i 5)
      (setf (gethash (format nil "test-~D" i) (fluxion.server:app-sessions app))
            (make-instance 'fluxion.server:session :id (format nil "test-~D" i))))
    (is (= 5 (fluxion.server:app-session-count app)))
    (let* ((response (fluxion.server:health-response app))
           (body (first (third response)))
           (json (cl-json:decode-json-from-string body)))
      (is (= 5 (cdr (assoc :sessions json)))))))

(test health-uptime-increases
  "Uptime increases after started-at is set."
  (let ((app (fluxion.server:make-fluxion-app :port 15102 :request-log nil)))
    (is (= 0 (fluxion.server:app-uptime-seconds app)))
    ;; Simulate start
    (setf (fluxion.server:app-started-at app) (- (get-universal-time) 42))
    (is (>= (fluxion.server:app-uptime-seconds app) 42))))

(test health-sse-connection-count
  "SSE connection count reflects sessions with active event queues."
  (let ((app (fluxion.server:make-fluxion-app :port 15103 :request-log nil)))
    (dotimes (i 3)
      (let ((s (make-instance 'fluxion.server:session :id (format nil "sse-~D" i))))
        (setf (gethash (format nil "sse-~D" i) (fluxion.server:app-sessions app)) s)
        ;; Only first 2 get event queues
        (when (< i 2)
          (fluxion.server:ensure-event-queue s))))
    (is (= 2 (fluxion.server:app-sse-connection-count app)))))

;;; -------------------------------------------------------
;;; Request logging tests
;;; -------------------------------------------------------

(test log-timestamp-format
  "format-log-timestamp returns a well-formed timestamp string."
  (let ((ts (fluxion.server:format-log-timestamp)))
    (is (= 19 (length ts)))
    (is (char= #\- (char ts 4)))
    (is (char= #\- (char ts 7)))
    (is (char= #\Space (char ts 10)))
    (is (char= #\: (char ts 13)))
    (is (char= #\: (char ts 16)))))

(test log-request-output
  "log-request writes a structured log line to *standard-output*."
  (let ((output (with-output-to-string (*standard-output*)
                  (fluxion.server:log-request :get "/health" 200 1.5))))
    (is (search "GET /health 200 1.5ms" output))))

;;; -------------------------------------------------------
;;; SSE connection stress test
;;; -------------------------------------------------------

(test sse-queue-stress-200-sessions
  "Create 200 sessions with event queues, push events, then close them all."
  (let* ((app (fluxion.server:make-fluxion-app :port 15104 :request-log nil))
         (n 200)
         (sessions nil))
    ;; Create sessions with event queues
    (dotimes (i n)
      (let* ((sid (format nil "stress-~D" i))
             (s (make-instance 'fluxion.server:session :id sid)))
        (setf (gethash sid (fluxion.server:app-sessions app)) s)
        (fluxion.server:ensure-event-queue s)
        (push s sessions)))
    (is (= n (fluxion.server:app-sse-connection-count app)))
    ;; Push 10 events to each session concurrently
    (let ((threads nil))
      (dolist (s sessions)
        (push (bordeaux-threads:make-thread
               (lambda ()
                 (dotimes (_ 10)
                   (fluxion.server:push-event
                    s (fluxion.events:make-patch-event "#x" "<p>ok</p>")))))
              threads))
      (dolist (th threads)
        (bordeaux-threads:join-thread th)))
    ;; Close all queues
    (dolist (s sessions)
      (fluxion.server:close-event-queue (fluxion.server::session-event-queue s)))
    ;; Verify all queues are closed
    (is (= 0 (fluxion.server:app-sse-connection-count app)))))

(test sse-concurrent-push-and-drain
  "Push events from producer threads while consumer threads drain them."
  (let* ((n-sessions 50)
         (n-events 100)
         (app (fluxion.server:make-fluxion-app :port 15105 :request-log nil))
         (sessions nil)
         (total-received (list 0))
         (lock (bordeaux-threads:make-lock "counter")))
    ;; Create sessions
    (dotimes (i n-sessions)
      (let* ((sid (format nil "cd-~D" i))
             (s (make-instance 'fluxion.server:session :id sid)))
        (setf (gethash sid (fluxion.server:app-sessions app)) s)
        (fluxion.server:ensure-event-queue s)
        (push s sessions)))
    ;; Start consumer threads (drain queues)
    (let ((consumers
            (mapcar (lambda (s)
                      (bordeaux-threads:make-thread
                       (lambda ()
                         (let ((count 0)
                               (q (fluxion.server::session-event-queue s)))
                           (loop until (fluxion.server::eq-closed-p q) do
                             (let ((events (fluxion.server::dequeue-all-events q :timeout 0.1)))
                               (incf count (length events))))
                           (bordeaux-threads:with-lock-held (lock)
                             (incf (car total-received) count))))))
                    sessions))
          ;; Start producer threads
          (producers
            (mapcar (lambda (s)
                      (bordeaux-threads:make-thread
                       (lambda ()
                         (dotimes (_ n-events)
                           (fluxion.server:push-event
                            s (fluxion.events:make-patch-event "#y" "<p>v</p>"))))))
                    sessions)))
      ;; Wait for producers to finish
      (dolist (th producers)
        (bordeaux-threads:join-thread th))
      ;; Close all queues to signal consumers
      (dolist (s sessions)
        (fluxion.server:close-event-queue (fluxion.server::session-event-queue s)))
      ;; Wait for consumers to finish
      (dolist (th consumers)
        (bordeaux-threads:join-thread th)))
    ;; Every event should have been received
    (is (= (* n-sessions n-events) (car total-received)))))

(test sse-reap-while-streaming
  "Sessions can be reaped while their event queues are being drained."
  (let* ((app (fluxion.server:make-fluxion-app :port 15106 :session-ttl 1 :request-log nil))
         (n 50)
         (sessions nil))
    ;; Create sessions in the past
    (dotimes (i n)
      (let* ((sid (format nil "reap-sse-~D" i))
             (s (make-instance 'fluxion.server:session :id sid)))
        (setf (fluxion.server::session-last-accessed-at s) (- (get-universal-time) 100))
        (setf (gethash sid (fluxion.server:app-sessions app)) s)
        (fluxion.server:ensure-event-queue s)
        (push s sessions)))
    ;; Start consumer threads that block on queues
    (let ((consumers
            (mapcar (lambda (s)
                      (bordeaux-threads:make-thread
                       (lambda ()
                         (let ((q (fluxion.server::session-event-queue s)))
                           (loop until (fluxion.server::eq-closed-p q) do
                             (fluxion.server::dequeue-all-events q :timeout 0.5))))))
                    sessions)))
      ;; Reap all sessions (should close queues, unblocking consumers)
      (let ((reaped (fluxion.server:reap-sessions app)))
        (is (= n reaped)))
      ;; All consumer threads should terminate
      (dolist (th consumers)
        (bordeaux-threads:join-thread th))
      ;; No sessions or SSE connections left
      (is (= 0 (fluxion.server:app-session-count app)))
      (is (= 0 (fluxion.server:app-sse-connection-count app))))))
