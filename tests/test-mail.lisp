;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Mail system tests

(in-package #:fluxion.db.tests)

(def-suite :mail-suite
  :description "Mail system tests"
  :in :db-suite)

(in-suite :mail-suite)

;;; -------------------------------------------------------
;;; Null backend
;;; -------------------------------------------------------

(test mail-null-backend-succeeds
  "Null backend silently accepts messages"
  (let ((fluxion.mail:*backend* (fluxion.mail:make-null-mail-backend)))
    (is (eq t (fluxion.mail:send "user@example.com" "Test" "Hello")))))

;;; -------------------------------------------------------
;;; Log backend
;;; -------------------------------------------------------

(defmacro with-log-mail (&body body)
  `(let* ((stream (make-string-output-stream))
          (fluxion.mail:*backend* (fluxion.mail:make-log-mail-backend
                                   :stream stream)))
     ,@body))

(test mail-log-backend-records
  "Log backend records messages in its log"
  (with-log-mail
    (fluxion.mail:send "user@example.com" "Welcome" "Hello!")
    (let ((log (fluxion.mail:backend-log fluxion.mail:*backend*)))
      (is (= 1 (length log)))
      (let ((msg (first log)))
        (is (string= "user@example.com" (cdr (assoc :to msg))))
        (is (string= "Welcome" (cdr (assoc :subject msg))))
        (is (string= "Hello!" (cdr (assoc :body msg))))))))

(test mail-log-backend-writes-stream
  "Log backend writes to its output stream"
  (with-log-mail
    (fluxion.mail:send "bob@example.com" "Test" "Body")
    (let ((output (get-output-stream-string
                   (slot-value fluxion.mail:*backend* 'fluxion.mail::stream))))
      (is (search "bob@example.com" output))
      (is (search "Test" output)))))

(test mail-html-flag
  "HTML flag is recorded"
  (with-log-mail
    (fluxion.mail:send "u@e.com" "Report" "<h1>Hi</h1>" :html-p t)
    (let ((msg (first (fluxion.mail:backend-log fluxion.mail:*backend*))))
      (is (eq t (cdr (assoc :html-p msg)))))))

;;; -------------------------------------------------------
;;; From address
;;; -------------------------------------------------------

(test mail-default-from
  "Default from address is *from*"
  (with-log-mail
    (let ((fluxion.mail:*from* "admin@myapp.com"))
      (fluxion.mail:send "u@e.com" "Test" "Body")
      (let ((output (get-output-stream-string
                     (slot-value fluxion.mail:*backend* 'fluxion.mail::stream))))
        (is (search "admin@myapp.com" output))))))

(test mail-override-from
  "From address can be overridden per message"
  (with-log-mail
    (fluxion.mail:send "u@e.com" "Test" "Body" :from "other@myapp.com")
    (let ((msg (first (fluxion.mail:backend-log fluxion.mail:*backend*))))
      (is (string= "other@myapp.com" (cdr (assoc :from msg)))))))

;;; -------------------------------------------------------
;;; On-send hook
;;; -------------------------------------------------------

(test mail-on-send-hook-fires
  "on-send hook is called before sending"
  (with-log-mail
    (let ((hook-called nil))
      (let ((fluxion.mail:*on-send*
              (lambda (to subject body &key from html-p headers)
                (declare (ignore to subject body from html-p headers))
                (setf hook-called t)
                t)))
        (fluxion.mail:send "u@e.com" "Test" "Body")
        (is (eq t hook-called))
        (is (= 1 (length (fluxion.mail:backend-log fluxion.mail:*backend*))))))))

(test mail-on-send-hook-aborts
  "on-send hook returning NIL aborts the send"
  (with-log-mail
    (let ((fluxion.mail:*on-send*
            (lambda (to subject body &key from html-p headers)
              (declare (ignore to subject body from html-p headers))
              nil)))
      (fluxion.mail:send "u@e.com" "Test" "Body")
      (is (= 0 (length (fluxion.mail:backend-log fluxion.mail:*backend*)))))))

;;; -------------------------------------------------------
;;; Multiple recipients
;;; -------------------------------------------------------

(test mail-multiple-recipients
  "Send to multiple recipients"
  (with-log-mail
    (fluxion.mail:send '("a@e.com" "b@e.com") "Group" "Hello all")
    (let ((msg (first (fluxion.mail:backend-log fluxion.mail:*backend*))))
      (is (= 2 (length (cdr (assoc :to msg))))))))
