;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Event constructors

(in-package #:fluxion.events)

;;; -------------------------------------------------------
;;; Convenience constructors for SSE events
;;; -------------------------------------------------------
;;; Each constructor returns an SSE-EVENT with a JSON-encodable
;;; payload as its data.  The payload is an alist so that cl-json
;;; serialises it as a JSON object.

(defun make-patch-event (selector fragment &key (mode "morph") id)
  "Create a patch-elements event.
SELECTOR is a CSS selector string.
FRAGMENT is the HTML string to patch into the DOM.
MODE is one of \"morph\", \"replace\", \"inner\" (default: \"morph\")."
  (make-instance 'sse-event
    :type +patch-elements+
    :id id
    :data `(("selector" . ,selector)
            ("mode"     . ,mode)
            ("fragment" . ,fragment))))

(defun make-remove-event (selector &key id)
  "Create a remove-elements event.
SELECTOR is a CSS selector for the element(s) to remove."
  (make-instance 'sse-event
    :type +remove-elements+
    :id id
    :data `(("selector" . ,selector))))

(defun make-append-event (selector fragment &key id)
  "Create an append-elements event.
Appends FRAGMENT as a child of the element matching SELECTOR."
  (make-instance 'sse-event
    :type +append-elements+
    :id id
    :data `(("selector" . ,selector)
            ("fragment" . ,fragment))))

(defun make-prepend-event (selector fragment &key id)
  "Create a prepend-elements event.
Prepends FRAGMENT as a child of the element matching SELECTOR."
  (make-instance 'sse-event
    :type +prepend-elements+
    :id id
    :data `(("selector" . ,selector)
            ("fragment" . ,fragment))))

(defun make-signal-event (signals &key id)
  "Create a patch-signals event.
SIGNALS is an alist of signal-name / value pairs to update on the client."
  (make-instance 'sse-event
    :type +patch-signals+
    :id id
    :data `(("signals" . ,signals))))

(defun make-script-event (script &key id)
  "Create an execute-script event.
SCRIPT is a JavaScript string to evaluate on the client."
  (make-instance 'sse-event
    :type +execute-script+
    :id id
    :data `(("script" . ,script))))

(defun make-redirect-event (url &key id)
  "Create a redirect event.
URL is the location to navigate to."
  (make-instance 'sse-event
    :type +redirect+
    :id id
    :data `(("url" . ,url))))
