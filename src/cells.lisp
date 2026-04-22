;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Reactive cells
;;;;
;;;; A cell is a container for a single value that notifies watchers
;;;; when it changes.  This is the foundation for the reactive layer:
;;;;
;;;;   v0.3 - cells with watchers (this file)
;;;;   v0.4 - computed cells (auto-derived values)
;;;;   v0.5 - propagator network (general dependency graph)

(in-package #:fluxion.cells)

;;; -------------------------------------------------------
;;; Pending events (dynamic collection during action handling)
;;; -------------------------------------------------------

(defvar *pending-events* nil
  "When bound to a list, cell-triggered watchers append SSE events here.
Bound by the action dispatch machinery so that cell changes during an
action automatically produce patch events in the response.")

(defun collect-event (event)
  "Append EVENT to *pending-events* if we are inside an action dispatch."
  (when *pending-events*
    (push event (car *pending-events*))))

(defun collect-events (events)
  "Append a list of EVENTS to *pending-events*."
  (when *pending-events*
    (dolist (e events)
      (push e (car *pending-events*)))))

(defun drain-pending-events ()
  "Return and clear all pending events collected during this action.
Returns them in the order they were collected."
  (when *pending-events*
    (prog1 (nreverse (car *pending-events*))
      (setf (car *pending-events*) nil))))

;;; -------------------------------------------------------
;;; Cell class
;;; -------------------------------------------------------

(defclass cell ()
  ((value    :initarg :value
             :initform nil
             :documentation "The current value held by this cell.")
   (name     :initarg :name
             :accessor cell-name
             :initform nil
             :type (or null string symbol)
             :documentation "Optional name for debugging.")
   (watchers :initform nil
             :accessor cell-watchers
             :documentation "List of functions called with (new-value old-value) on change.")
   (equalfn  :initarg :test
             :accessor cell-test
             :initform #'equal
             :documentation "Comparison function to detect value changes."))
  (:documentation "A reactive value container that notifies watchers on change."))

(defun make-cell (value &key name (test #'equal))
  "Create a new cell with initial VALUE."
  (make-instance 'cell :value value :name name :test test))

(defmethod print-object ((c cell) stream)
  (print-unreadable-object (c stream :type t :identity t)
    (when (cell-name c)
      (format stream "~A " (cell-name c)))
    (format stream "~S" (slot-value c 'value))))

;;; -------------------------------------------------------
;;; Reading and writing
;;; -------------------------------------------------------

(defun cell-value (cell)
  "Read the current value of CELL."
  (slot-value cell 'value))

(defun (setf cell-value) (new-value cell)
  "Set CELL to NEW-VALUE. Notifies watchers if the value changed."
  (let ((old-value (slot-value cell 'value)))
    (unless (funcall (cell-test cell) old-value new-value)
      (setf (slot-value cell 'value) new-value)
      (notify-watchers cell new-value old-value)))
  new-value)

;;; -------------------------------------------------------
;;; Watchers
;;; -------------------------------------------------------

(defun watch (cell fn)
  "Register FN as a watcher on CELL.
FN is called with (new-value old-value) whenever the cell changes.
Returns FN."
  (pushnew fn (cell-watchers cell))
  fn)

(defun unwatch (cell fn)
  "Remove FN from CELL's watchers."
  (setf (cell-watchers cell) (remove fn (cell-watchers cell)))
  fn)

(defun notify-watchers (cell new-value old-value)
  "Call all watchers of CELL with the new and old values."
  (dolist (fn (cell-watchers cell))
    (funcall fn new-value old-value)))

;;; -------------------------------------------------------
;;; Component integration
;;; -------------------------------------------------------

(defun connect (cell component &key (mode "morph"))
  "Connect CELL to COMPONENT so that changes auto-patch.
When CELL's value changes, COMPONENT is re-rendered and a patch event
is collected into *pending-events* (if bound).
Returns the watcher function (useful for later disconnection)."
  (let ((watcher (lambda (new-value old-value)
                   (declare (ignore new-value old-value))
                   (fluxion.components:mark-dirty component)
                   (let ((events (fluxion.components:patch-component component :mode mode)))
                     (collect-events events)))))
    (watch cell watcher)
    watcher))

(defun disconnect (cell watcher)
  "Remove a previously connected watcher from CELL."
  (unwatch cell watcher))
