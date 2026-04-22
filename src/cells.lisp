;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Reactive cells
;;;;
;;;; A cell is a container for a single value that notifies watchers
;;;; when it changes.  This is the foundation for the reactive layer:
;;;;
;;;;   v0.3 - cells with watchers
;;;;   v0.4 - computed cells with automatic dependency tracking
;;;;   v0.5 - propagators (this file)

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

(defvar *tracking-reads* nil
  "When bound to a list, cell reads are recorded here for dependency tracking.
Used by computed cells to discover their dependencies.")

(defun cell-value (cell)
  "Read the current value of CELL.
When called inside a computed cell's thunk, records the read for dependency tracking."
  (when *tracking-reads*
    (pushnew cell (car *tracking-reads*)))
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

;;; -------------------------------------------------------
;;; Computed cells
;;; -------------------------------------------------------

(defclass computed-cell (cell)
  ((thunk        :initarg :thunk
                 :accessor computed-thunk
                 :documentation "Zero-argument function that computes the value.")
   (dependencies :initform nil
                 :accessor computed-dependencies
                 :documentation "List of cells this computed depends on.")
   (update-fn    :initform nil
                 :accessor computed-update-fn
                 :documentation "The watcher function installed on dependencies."))
  (:documentation "A cell whose value is derived from other cells.
The thunk is re-run whenever a dependency changes, and watchers on
this cell are notified if the computed value changes."))

(defun make-computed (thunk &key name (test #'equal))
  "Create a computed cell. THUNK is a zero-argument function that reads
other cells to produce a value. Dependencies are tracked automatically."
  (let ((c (make-instance 'computed-cell :thunk thunk :name name :test test)))
    (recompute c)
    c))

(defun recompute (computed)
  "Recalculate COMPUTED's value by running its thunk.
Discovers dependencies via *tracking-reads* and rewires watchers."
  (let* ((*tracking-reads* (list nil))
         (new-value (funcall (computed-thunk computed)))
         (new-deps (car *tracking-reads*))
         (old-deps (computed-dependencies computed)))
    ;; Unwire old dependencies that are no longer read
    (let ((update-fn (or (computed-update-fn computed)
                         (let ((fn (lambda (nv ov)
                                     (declare (ignore nv ov))
                                     (recompute computed))))
                           (setf (computed-update-fn computed) fn)
                           fn))))
      (dolist (dep old-deps)
        (unless (member dep new-deps)
          (unwatch dep update-fn)))
      ;; Wire new dependencies
      (dolist (dep new-deps)
        (unless (member dep old-deps)
          (watch dep update-fn)))
      (setf (computed-dependencies computed) new-deps))
    ;; Update the value and notify watchers if changed
    (let ((old-value (slot-value computed 'value)))
      (unless (funcall (cell-test computed) old-value new-value)
        (setf (slot-value computed 'value) new-value)
        (notify-watchers computed new-value old-value)))
    new-value))

;;; -------------------------------------------------------
;;; Propagators
;;; -------------------------------------------------------
;;; A propagator connects input cells to output cells via a function.
;;; When any input changes, the function fires and writes results to
;;; the outputs.  The cell equality check prevents infinite loops in
;;; bidirectional networks - propagation stops when values converge.
;;;
;;; CL's exact rational arithmetic makes bidirectional numeric
;;; propagators converge perfectly (no floating-point oscillation).

(defclass propagator ()
  ((name     :initarg :name
             :accessor propagator-name
             :initform nil
             :documentation "Optional name for debugging.")
   (inputs   :initarg :inputs
             :accessor propagator-inputs
             :documentation "List of input cells.")
   (outputs  :initarg :outputs
             :accessor propagator-outputs
             :documentation "List of output cells.")
   (fn       :initarg :fn
             :accessor propagator-fn
             :documentation "Function: receives input values as arguments, returns output value(s).")
   (installed-watchers :initform nil
                       :accessor propagator-installed-watchers
                       :documentation "Watcher functions installed on input cells.")
   (active-p :initform nil
             :accessor propagator-active-p
             :documentation "Re-entrance guard. Prevents direct cycles."))
  (:documentation "A propagator connects input cells to output cells.
When any input cell changes, the function is applied to all input values
and the result(s) written to the output cell(s)."))

(defun make-propagator (&key inputs fn outputs name)
  "Create and activate a propagator.
FN receives the current values of INPUTS as arguments.
For a single output, FN returns one value.
For multiple outputs, FN returns a list of values."
  (let ((p (make-instance 'propagator
                          :inputs inputs :fn fn :outputs outputs :name name)))
    (install-propagator p)
    (fire-propagator p)
    p))

(defmethod print-object ((p propagator) stream)
  (print-unreadable-object (p stream :type t :identity t)
    (when (propagator-name p)
      (format stream "~A " (propagator-name p)))
    (format stream "~D->~D"
            (length (propagator-inputs p))
            (length (propagator-outputs p)))))

(defun install-propagator (propagator)
  "Install watchers on all input cells so the propagator fires on change."
  (let ((watcher (lambda (new-value old-value)
                   (declare (ignore new-value old-value))
                   (fire-propagator propagator))))
    (dolist (input (propagator-inputs propagator))
      (watch input watcher))
    (setf (propagator-installed-watchers propagator) (list watcher))))

(defun fire-propagator (propagator)
  "Run the propagator: read inputs, apply function, write outputs.
Returns immediately if this propagator is already firing (re-entrance guard)."
  (when (propagator-active-p propagator)
    (return-from fire-propagator))
  (setf (propagator-active-p propagator) t)
  (unwind-protect
      (let* ((input-values (mapcar #'cell-value (propagator-inputs propagator)))
             (result (apply (propagator-fn propagator) input-values))
             (outputs (propagator-outputs propagator)))
        (if (= (length outputs) 1)
            (setf (cell-value (first outputs)) result)
            (loop for cell in outputs
                  for value in (if (listp result) result (list result))
                  do (setf (cell-value cell) value))))
    (setf (propagator-active-p propagator) nil)))

(defun remove-propagator (propagator)
  "Remove the propagator's watchers from its input cells."
  (dolist (watcher (propagator-installed-watchers propagator))
    (dolist (input (propagator-inputs propagator))
      (unwatch input watcher)))
  (setf (propagator-installed-watchers propagator) nil))
