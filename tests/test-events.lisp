;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.events

(in-package #:fluxion.tests)
(in-suite events-suite)

(test make-patch-event-defaults
  "make-patch-event creates a morph patch by default."
  (let ((e (fluxion.events:make-patch-event "#widget" "<div>hi</div>")))
    (is (string= "fluxion-patch" (fluxion.protocol:event-type e)))
    (let ((data (fluxion.protocol:event-data e)))
      (is (equal "#widget" (cdr (assoc "selector" data :test #'string=))))
      (is (equal "morph" (cdr (assoc "mode" data :test #'string=))))
      (is (equal "<div>hi</div>" (cdr (assoc "fragment" data :test #'string=)))))))

(test make-patch-event-replace-mode
  "make-patch-event accepts a custom mode."
  (let* ((e (fluxion.events:make-patch-event "#x" "<p/>" :mode "replace"))
         (data (fluxion.protocol:event-data e)))
    (is (equal "replace" (cdr (assoc "mode" data :test #'string=))))))

(test make-remove-event
  "make-remove-event stores the selector."
  (let* ((e (fluxion.events:make-remove-event "#old"))
         (data (fluxion.protocol:event-data e)))
    (is (string= "fluxion-remove" (fluxion.protocol:event-type e)))
    (is (equal "#old" (cdr (assoc "selector" data :test #'string=))))))

(test make-append-event
  "make-append-event stores selector and fragment."
  (let* ((e (fluxion.events:make-append-event "#list" "<li>new</li>"))
         (data (fluxion.protocol:event-data e)))
    (is (string= "fluxion-append" (fluxion.protocol:event-type e)))
    (is (equal "#list" (cdr (assoc "selector" data :test #'string=))))
    (is (equal "<li>new</li>" (cdr (assoc "fragment" data :test #'string=))))))

(test make-prepend-event
  "make-prepend-event stores selector and fragment."
  (let* ((e (fluxion.events:make-prepend-event "#list" "<li>first</li>"))
         (data (fluxion.protocol:event-data e)))
    (is (string= "fluxion-prepend" (fluxion.protocol:event-type e)))
    (is (equal "<li>first</li>" (cdr (assoc "fragment" data :test #'string=))))))

(test make-signal-event
  "make-signal-event wraps an alist of signals."
  (let* ((signals '(("count" . 42) ("name" . "test")))
         (e (fluxion.events:make-signal-event signals))
         (data (fluxion.protocol:event-data e)))
    (is (string= "fluxion-signals" (fluxion.protocol:event-type e)))
    (is (equal signals (cdr (assoc "signals" data :test #'string=))))))

(test make-script-event
  "make-script-event stores the script string."
  (let* ((e (fluxion.events:make-script-event "alert('hi')"))
         (data (fluxion.protocol:event-data e)))
    (is (string= "fluxion-script" (fluxion.protocol:event-type e)))
    (is (equal "alert('hi')" (cdr (assoc "script" data :test #'string=))))))

(test make-redirect-event
  "make-redirect-event stores the URL."
  (let* ((e (fluxion.events:make-redirect-event "/home"))
         (data (fluxion.protocol:event-data e)))
    (is (string= "fluxion-redirect" (fluxion.protocol:event-type e)))
    (is (equal "/home" (cdr (assoc "url" data :test #'string=))))))

(test events-roundtrip-through-sse
  "Events can be formatted as SSE text and contain the expected JSON."
  (let* ((e (fluxion.events:make-patch-event "#app" "<div>hello</div>"))
         (text (fluxion.protocol:format-sse-event e)))
    (is (search "event: fluxion-patch" text))
    (is (search "selector" text))
    (is (search "fragment" text))
    (is (search "hello" text))))
