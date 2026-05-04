;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - SSE/JSON event protocol

(in-package #:fluxion.protocol)

;;; -------------------------------------------------------
;;; Event type constants
;;; -------------------------------------------------------

(alexandria:define-constant +patch-elements+   "fluxion-patch"   :test #'equal
  :documentation "SSE event type string for DOM patch operations.")
(alexandria:define-constant +remove-elements+  "fluxion-remove"  :test #'equal
  :documentation "SSE event type string for DOM element removal.")
(alexandria:define-constant +append-elements+  "fluxion-append"  :test #'equal
  :documentation "SSE event type string for appending child elements.")
(alexandria:define-constant +prepend-elements+ "fluxion-prepend" :test #'equal
  :documentation "SSE event type string for prepending child elements.")
(alexandria:define-constant +patch-signals+    "fluxion-signals" :test #'equal
  :documentation "SSE event type string for updating client-side signals.")
(alexandria:define-constant +execute-script+   "fluxion-script"  :test #'equal
  :documentation "SSE event type string for executing JavaScript on the client.")
(alexandria:define-constant +redirect+         "fluxion-redirect" :test #'equal
  :documentation "SSE event type string for browser navigation.")

;;; -------------------------------------------------------
;;; SSE event structure
;;; -------------------------------------------------------

(defgeneric event-type (event)
  (:documentation "The SSE event type field (e.g. \"fluxion-patch\", \"fluxion-script\")."))

(defgeneric event-data (event)
  (:documentation "The event payload (alist), JSON-encoded when formatted."))

(defgeneric event-id (event)
  (:documentation "Optional SSE event ID. The browser uses this for reconnection (Last-Event-ID)."))

(defgeneric event-retry (event)
  (:documentation "Optional SSE retry interval in milliseconds. Tells the browser how long to wait before reconnecting."))

(defclass sse-event ()
  ((event-type :initarg :type
               :accessor event-type
               :type string
               :documentation "The SSE event type field.")
   (event-data :initarg :data
               :accessor event-data
               :documentation "The event payload, will be JSON-encoded.")
   (event-id   :initarg :id
               :accessor event-id
               :initform nil
               :documentation "Optional SSE event ID.")
   (event-retry :initarg :retry
                :accessor event-retry
                :initform nil
                :documentation "Optional SSE retry interval in milliseconds.")))

(defmethod print-object ((event sse-event) stream)
  (print-unreadable-object (event stream :type t)
    (format stream "~A" (event-type event))))

;;; -------------------------------------------------------
;;; SSE formatting
;;; -------------------------------------------------------

(defun encode-json-data (data)
  "Encode DATA as a JSON string using cl-json."
  (cl-json:encode-json-to-string data))

(defun format-sse-event (event)
  "Format an SSE-EVENT as a string suitable for text/event-stream output."
  (with-output-to-string (s)
    (write-sse-event event s)))

(defun write-sse-event (event stream)
  "Write an SSE-EVENT to STREAM in text/event-stream format."
  (when (event-id event)
    (format stream "id: ~A~%" (event-id event)))
  (when (event-retry event)
    (format stream "retry: ~A~%" (event-retry event)))
  (format stream "event: ~A~%" (event-type event))
  ;; Encode the data payload as JSON, then write as SSE data lines.
  ;; Each line of the JSON string becomes a separate data: line.
  (let ((json-string (encode-json-data (event-data event))))
    (loop for line in (split-lines json-string)
          do (format stream "data: ~A~%" line)))
  ;; SSE events are terminated by a blank line
  (format stream "~%")
  (force-output stream))

(defun split-lines (string)
  "Split STRING into a list of lines."
  (loop with start = 0
        for pos = (position #\Newline string :start start)
        collect (subseq string start (or pos (length string)))
        while pos
        do (setf start (1+ pos))))
