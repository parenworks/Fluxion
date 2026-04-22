;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.protocol

(in-package #:fluxion.tests)
(in-suite protocol-suite)

(test sse-event-creation
  "Creating an SSE event stores type and data."
  (let ((e (make-instance 'fluxion.protocol:sse-event
                          :type "test-event"
                          :data '(("key" . "value")))))
    (is (string= "test-event" (fluxion.protocol:event-type e)))
    (is (equal '(("key" . "value")) (fluxion.protocol:event-data e)))
    (is (null (fluxion.protocol:event-id e)))
    (is (null (fluxion.protocol:event-retry e)))))

(test sse-event-with-id-and-retry
  "SSE event can carry optional id and retry fields."
  (let ((e (make-instance 'fluxion.protocol:sse-event
                          :type "t" :data nil :id "42" :retry 3000)))
    (is (string= "42" (fluxion.protocol:event-id e)))
    (is (= 3000 (fluxion.protocol:event-retry e)))))

(test format-sse-event-basic
  "format-sse-event produces valid SSE text."
  (let* ((e (make-instance 'fluxion.protocol:sse-event
                           :type "fluxion-patch"
                           :data '(("selector" . "#foo"))))
         (text (fluxion.protocol:format-sse-event e)))
    (is (search "event: fluxion-patch" text))
    (is (search "data: " text))
    ;; Must end with double newline (blank line terminates SSE event)
    (is (alexandria:ends-with-subseq (format nil "~%~%") text))))

(test format-sse-event-with-id
  "format-sse-event includes the id field when present."
  (let* ((e (make-instance 'fluxion.protocol:sse-event
                           :type "t" :data nil :id "99"))
         (text (fluxion.protocol:format-sse-event e)))
    (is (search "id: 99" text))))

(test format-sse-event-with-retry
  "format-sse-event includes the retry field when present."
  (let* ((e (make-instance 'fluxion.protocol:sse-event
                           :type "t" :data nil :retry 5000))
         (text (fluxion.protocol:format-sse-event e)))
    (is (search "retry: 5000" text))))

(test write-sse-event-to-stream
  "write-sse-event writes to a stream and produces the same output as format-sse-event."
  (let* ((e (make-instance 'fluxion.protocol:sse-event
                           :type "fluxion-patch"
                           :data '(("selector" . "#bar"))))
         (formatted (fluxion.protocol:format-sse-event e))
         (written (with-output-to-string (s)
                    (fluxion.protocol:write-sse-event e s))))
    (is (string= formatted written))))
