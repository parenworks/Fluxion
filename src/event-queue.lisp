;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Thread-safe event queue for SSE push

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Event queue (for persistent SSE push)
;;; -------------------------------------------------------

(defgeneric eq-closed-p (queue)
  (:documentation "Whether the event queue has been closed."))

(defclass event-queue ()
  ((head    :initform nil
            :accessor eq-events
            :documentation "Head of the singly-linked event list.")
   (tail    :initform nil
            :accessor eq-tail
            :documentation "Last cons of the event list, for O(1) enqueue.")
   (count   :initform 0
            :accessor eq-count
            :type fixnum
            :documentation "Number of events currently in the queue.")
   (max-size :initarg :max-size
             :accessor eq-max-size
             :initform 1024
             :type (or fixnum null)
             :documentation "Maximum events before dropping oldest. NIL for unbounded.")
   (lock    :initform (bt:make-lock "event-queue")
            :accessor eq-lock)
   (condvar :initform (bt:make-condition-variable :name "event-queue-cv")
            :accessor eq-condvar)
   (closed-p :initform nil
             :accessor eq-closed-p))
  (:documentation "Thread-safe event queue with O(1) enqueue, blocking dequeue, and optional bounded size."))

(defmethod print-object ((q event-queue) stream)
  (print-unreadable-object (q stream :type t :identity t)
    (format stream "~D event~:P~:[~; CLOSED~]~@[ max=~D~]"
            (eq-count q) (eq-closed-p q) (eq-max-size q))))

(defun make-event-queue (&key (max-size 1024))
  "Create a new event queue. MAX-SIZE limits buffered events (NIL for unbounded)."
  (make-instance 'event-queue :max-size max-size))

(defun enqueue-event (queue event)
  "Add EVENT to QUEUE in O(1) and wake any waiting reader.
When the queue is at max-size, drops the oldest event."
  (bt:with-lock-held ((eq-lock queue))
    ;; Drop oldest if at capacity
    (let ((max (eq-max-size queue)))
      (when (and max (>= (eq-count queue) max))
        (setf (eq-events queue) (cdr (eq-events queue)))
        (decf (eq-count queue))
        (unless (eq-events queue)
          (setf (eq-tail queue) nil))))
    ;; Append new event
    (let ((new-cons (list event)))
      (if (eq-tail queue)
          (setf (cdr (eq-tail queue)) new-cons)
          (setf (eq-events queue) new-cons))
      (setf (eq-tail queue) new-cons))
    (incf (eq-count queue))
    (bt:condition-notify (eq-condvar queue))))

(defun dequeue-all-events (queue &key (timeout 15))
  "Block until events are available or TIMEOUT seconds elapse.
Returns the list of events (may be empty on timeout)."
  (bt:with-lock-held ((eq-lock queue))
    (when (and (null (eq-events queue))
               (not (eq-closed-p queue)))
      (bt:condition-wait (eq-condvar queue) (eq-lock queue)
                         :timeout timeout))
    (prog1 (eq-events queue)
      (setf (eq-events queue) nil)
      (setf (eq-tail queue) nil)
      (setf (eq-count queue) 0))))

(defun close-event-queue (queue)
  "Mark QUEUE as closed and wake any waiting reader."
  (bt:with-lock-held ((eq-lock queue))
    (setf (eq-closed-p queue) t)
    (bt:condition-notify (eq-condvar queue))))
