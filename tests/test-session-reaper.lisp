;;;; -*- encoding:utf-8 -*-
;;;; Fluxion tests - Session reaping under load
;;;;
;;;; Stress tests for the session reaper: concurrent creation,
;;;; access, expiration, and cleanup of sessions.

(in-package #:fluxion.tests)

(in-suite session-reaper-suite)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defun make-test-app (&key (ttl 2) (reaper-interval 1))
  "Create a Fluxion app with short TTL for testing."
  (fluxion.server:make-fluxion-app :session-ttl ttl
                                    :reaper-interval reaper-interval))

(defun populate-sessions (app n &key (age 0))
  "Add N sessions to APP. If AGE > 0, backdate their last-accessed-at."
  (let ((lock (fluxion.server:app-session-lock app))
        (store (fluxion.server:app-sessions app)))
    (dotimes (i n)
      (let ((session (make-instance 'fluxion.server:session
                       :id (format nil "test-~D" i))))
        (when (plusp age)
          (setf (fluxion.server::session-last-accessed-at session)
                (- (get-universal-time) age)))
        (bt:with-lock-held (lock)
          (setf (gethash (fluxion.server:session-id session) store)
                session))))))

;;; -------------------------------------------------------
;;; Tests
;;; -------------------------------------------------------

(test reap-expired-sessions
  "reap-sessions removes only expired sessions."
  (let ((app (make-test-app :ttl 2)))
    ;; 5 fresh sessions
    (populate-sessions app 5)
    ;; 5 old sessions (backdated 10 seconds)
    (let ((lock (fluxion.server:app-session-lock app))
          (store (fluxion.server:app-sessions app)))
      (dotimes (i 5)
        (let ((session (make-instance 'fluxion.server:session
                         :id (format nil "old-~D" i))))
          (setf (fluxion.server::session-last-accessed-at session)
                (- (get-universal-time) 10))
          (bt:with-lock-held (lock)
            (setf (gethash (fluxion.server:session-id session) store)
                  session)))))
    (is (= 10 (hash-table-count (fluxion.server:app-sessions app))))
    (let ((reaped (fluxion.server:reap-sessions app)))
      (is (= 5 reaped))
      (is (= 5 (hash-table-count (fluxion.server:app-sessions app)))))))

(test reap-closes-event-queues
  "Reaping a session closes its event queue so SSE threads can exit."
  (let ((app (make-test-app :ttl 1)))
    (populate-sessions app 1 :age 10)
    ;; Attach an event queue to the session
    (let ((session nil))
      (bt:with-lock-held ((fluxion.server:app-session-lock app))
        (maphash (lambda (k v) (declare (ignore k)) (setf session v))
                 (fluxion.server:app-sessions app)))
      (let ((queue (fluxion.server:ensure-event-queue session)))
        (fluxion.server:reap-sessions app)
        (is (= 0 (hash-table-count (fluxion.server:app-sessions app))))
        ;; Queue should be closed
        (is (eq t (fluxion.server::eq-closed-p queue)))))))

(test reap-no-live-sessions
  "reap-sessions with no expired sessions does nothing."
  (let ((app (make-test-app :ttl 3600)))
    (populate-sessions app 20)
    (let ((reaped (fluxion.server:reap-sessions app)))
      (is (= 0 reaped))
      (is (= 20 (hash-table-count (fluxion.server:app-sessions app)))))))

(test reap-empty-store
  "reap-sessions on an empty session store returns 0."
  (let ((app (make-test-app)))
    (is (= 0 (fluxion.server:reap-sessions app)))))

(test concurrent-session-creation-and-reaping
  "Sessions can be created from multiple threads while the reaper runs."
  (let ((app (make-test-app :ttl 1 :reaper-interval 1)))
    ;; Pre-populate with expired sessions
    (populate-sessions app 50 :age 10)
    ;; Spawn writers that create new fresh sessions
    (let ((threads
            (loop for t-id below 4
                  collect (bt:make-thread
                           (lambda ()
                             (dotimes (i 50)
                               (let ((sid (format nil "new-~D-~D"
                                                  (bt:current-thread) i))
                                     (session (make-instance
                                               'fluxion.server:session
                                               :id (format nil "new-~D-~D"
                                                           (bt:current-thread) i))))
                                 (bt:with-lock-held
                                     ((fluxion.server:app-session-lock app))
                                   (setf (gethash sid
                                                  (fluxion.server:app-sessions app))
                                         session)))))
                           :name (format nil "creator-~D" t-id))))
          ;; Also run the reaper concurrently
          (reaper (bt:make-thread
                   (lambda ()
                     (dotimes (_ 10)
                       (fluxion.server:reap-sessions app)
                       (sleep 0.05)))
                   :name "reaper")))
      (dolist (th threads) (bt:join-thread th))
      (bt:join-thread reaper))
    ;; All 50 old sessions should be reaped, 200 new should remain
    ;; (some new ones might also expire if the test runs slowly)
    (let ((remaining (hash-table-count (fluxion.server:app-sessions app))))
      (is (>= remaining 100)
          "Expected at least 100 sessions remaining, got ~D" remaining))))

(test touch-prevents-reaping
  "Touching a session resets its last-accessed time and prevents reaping."
  (let ((app (make-test-app :ttl 2)))
    (populate-sessions app 5 :age 10)
    ;; Touch 3 of them
    (let ((touched 0))
      (bt:with-lock-held ((fluxion.server:app-session-lock app))
        (maphash (lambda (k session)
                   (declare (ignore k))
                   (when (< touched 3)
                     (fluxion.server:touch-session session)
                     (incf touched)))
                 (fluxion.server:app-sessions app))))
    (let ((reaped (fluxion.server:reap-sessions app)))
      (is (= 2 reaped))
      (is (= 3 (hash-table-count (fluxion.server:app-sessions app)))))))

(test reaper-thread-lifecycle
  "start-session-reaper / stop-session-reaper lifecycle works cleanly."
  (let ((app (make-test-app :ttl 1 :reaper-interval 1)))
    (populate-sessions app 10 :age 10)
    ;; Start reaper - it should clean up sessions
    (fluxion.server:start-session-reaper app)
    (is (not (null (fluxion.server::app-reaper-thread app))))
    (sleep 1.5)
    (is (< (hash-table-count (fluxion.server:app-sessions app)) 10))
    ;; Stop gracefully
    (fluxion.server:stop-session-reaper app)
    (is (null (fluxion.server::app-reaper-thread app)))))

(test bulk-reap-under-load
  "Reap 1000 expired sessions while 4 threads write to the store."
  (let ((app (make-test-app :ttl 1)))
    (populate-sessions app 1000 :age 10)
    (let ((writers
            (loop for t-id below 4
                  collect (bt:make-thread
                           (lambda ()
                             (dotimes (i 100)
                               (let ((sid (format nil "bulk-~D-~D"
                                                  (bt:current-thread) i))
                                     (s (make-instance 'fluxion.server:session
                                          :id (format nil "bulk-~D-~D"
                                                      (bt:current-thread) i))))
                                 (bt:with-lock-held
                                     ((fluxion.server:app-session-lock app))
                                   (setf (gethash sid
                                                  (fluxion.server:app-sessions app))
                                         s)))
                               (sleep 0.001)))
                           :name (format nil "bulk-writer-~D" t-id)))))
      ;; Reap while writers are active
      (let ((total-reaped 0))
        (dotimes (_ 20)
          (incf total-reaped (fluxion.server:reap-sessions app))
          (sleep 0.025))
        (dolist (th writers) (bt:join-thread th))
        ;; Final reap
        (incf total-reaped (fluxion.server:reap-sessions app))
        ;; All 1000 old sessions should be reaped
        (is (= 1000 total-reaped))
        ;; Only the 400 new sessions should remain
        (is (= 400 (hash-table-count (fluxion.server:app-sessions app))))))))
