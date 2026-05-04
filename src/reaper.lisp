;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Session reaper thread management

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Session reaper
;;; -------------------------------------------------------

(defun reap-sessions (app)
  "Remove expired sessions from APP. Closes event queues so SSE
threads unblock and terminate cleanly. Returns the number reaped."
  (let ((ttl (app-session-ttl app))
        (reaped 0)
        (queues-to-close nil))
    (bt:with-lock-held ((app-session-lock app))
      (let ((to-remove nil))
        (maphash (lambda (sid session)
                   (when (session-expired-p session ttl)
                     (push sid to-remove)
                     (let ((q (session-event-queue session)))
                       (when q (push q queues-to-close)))))
                 (app-sessions app))
        (dolist (sid to-remove)
          (remhash sid (app-sessions app))
          (incf reaped))))
    ;; Close queues outside the session lock to avoid deadlock
    (dolist (q queues-to-close)
      (ignore-errors (close-event-queue q)))
    reaped))

(defun start-session-reaper (app)
  "Start the background session reaper thread for APP."
  (stop-session-reaper app)
  (setf (app-reaper-stop-flag app) nil)
  (setf (app-reaper-thread app)
        (bt:make-thread
         (lambda ()
           (loop
             (handler-case
                 (sleep (app-reaper-interval app))
               (condition () nil))
             (when (app-reaper-stop-flag app)
               (return))
             (handler-case
                 (let ((n (reap-sessions app)))
                   (when (plusp n)
                     (format t "[fluxion] Reaped ~D expired session~:P~%" n)))
               (error (e)
                 (format t "[fluxion] Session reaper error: ~A~%" e)))))
         :name "fluxion-session-reaper")))

(defun stop-session-reaper (app)
  "Stop the background session reaper thread gracefully.
Sets the stop flag, interrupts the sleeping thread, and waits briefly."
  (when (app-reaper-thread app)
    (setf (app-reaper-stop-flag app) t)
    (let ((thread (app-reaper-thread app)))
      (when (bt:thread-alive-p thread)
        ;; Interrupt the thread so it wakes from sleep immediately
        (ignore-errors (bt:interrupt-thread thread (lambda () nil)))
        ;; Wait up to 2 seconds for it to exit
        (loop repeat 20
              while (bt:thread-alive-p thread)
              do (sleep 0.1))))
    (setf (app-reaper-thread app) nil)))
