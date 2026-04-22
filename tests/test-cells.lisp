;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.cells - basic cells and watchers

(in-package #:fluxion.tests)
(in-suite cells-suite)

(test make-cell-basic
  "make-cell creates a cell with the given value."
  (let ((c (fluxion.cells:make-cell 42)))
    (is (= 42 (fluxion.cells:cell-value c)))))

(test make-cell-with-name
  "make-cell accepts an optional name."
  (let ((c (fluxion.cells:make-cell 0 :name "counter")))
    (is (string= "counter" (fluxion.cells:cell-name c)))))

(test cell-setf-value
  "Setting a cell's value updates it."
  (let ((c (fluxion.cells:make-cell 1)))
    (setf (fluxion.cells:cell-value c) 99)
    (is (= 99 (fluxion.cells:cell-value c)))))

(test cell-watcher-fires-on-change
  "A watcher is called when the cell value changes."
  (let ((c (fluxion.cells:make-cell 0))
        (log nil))
    (fluxion.cells:watch c
      (lambda (new old)
        (push (list new old) log)))
    (setf (fluxion.cells:cell-value c) 5)
    (is (= 1 (length log)))
    (is (equal '(5 0) (first log)))))

(test cell-watcher-not-fired-for-equal-value
  "Watcher is not called if the new value is equal to the old."
  (let ((c (fluxion.cells:make-cell "hello"))
        (count 0))
    (fluxion.cells:watch c
      (lambda (new old)
        (declare (ignore new old))
        (incf count)))
    (setf (fluxion.cells:cell-value c) "hello")
    (is (= 0 count))))

(test cell-custom-test
  "Custom equality test controls when watchers fire."
  (let ((c (fluxion.cells:make-cell 1.0 :test #'=))
        (count 0))
    (fluxion.cells:watch c
      (lambda (new old)
        (declare (ignore new old))
        (incf count)))
    ;; Same numeric value, different object
    (setf (fluxion.cells:cell-value c) 1.0)
    (is (= 0 count))
    ;; Different value
    (setf (fluxion.cells:cell-value c) 2.0)
    (is (= 1 count))))

(test cell-multiple-watchers
  "Multiple watchers all fire."
  (let ((c (fluxion.cells:make-cell 0))
        (a-fired nil)
        (b-fired nil))
    (fluxion.cells:watch c (lambda (n o) (declare (ignore n o)) (setf a-fired t)))
    (fluxion.cells:watch c (lambda (n o) (declare (ignore n o)) (setf b-fired t)))
    (setf (fluxion.cells:cell-value c) 1)
    (is-true a-fired)
    (is-true b-fired)))

(test cell-unwatch
  "Removing a watcher prevents it from firing."
  (let ((c (fluxion.cells:make-cell 0))
        (count 0))
    (let ((fn (fluxion.cells:watch c
               (lambda (n o) (declare (ignore n o)) (incf count)))))
      (setf (fluxion.cells:cell-value c) 1)
      (is (= 1 count))
      (fluxion.cells:unwatch c fn)
      (setf (fluxion.cells:cell-value c) 2)
      (is (= 1 count)))))

(test cell-watcher-sequence
  "Watchers fire in order for multiple changes."
  (let ((c (fluxion.cells:make-cell 0))
        (log nil))
    (fluxion.cells:watch c
      (lambda (new old) (push (cons old new) log)))
    (setf (fluxion.cells:cell-value c) 1)
    (setf (fluxion.cells:cell-value c) 2)
    (setf (fluxion.cells:cell-value c) 3)
    (is (= 3 (length log)))
    ;; log is in reverse order due to push
    (is (equal '((0 . 1) (1 . 2) (2 . 3)) (nreverse log)))))

(test cell-nil-value
  "Cell can hold nil and transition to/from nil."
  (let ((c (fluxion.cells:make-cell nil))
        (log nil))
    (fluxion.cells:watch c
      (lambda (new old) (push (list old new) log)))
    (setf (fluxion.cells:cell-value c) 42)
    (setf (fluxion.cells:cell-value c) nil)
    (is (= 2 (length log)))))

(test pending-events-collection
  "Events are collected into *pending-events* during action dispatch."
  (let ((fluxion.cells:*pending-events* (list nil)))
    (fluxion.cells:collect-event :ev1)
    (fluxion.cells:collect-event :ev2)
    (let ((events (fluxion.cells:drain-pending-events)))
      (is (equal '(:ev1 :ev2) events)))))

(test pending-events-not-collected-outside-dispatch
  "collect-event does nothing when *pending-events* is not bound."
  (let ((fluxion.cells:*pending-events* nil))
    (fluxion.cells:collect-event :nope)
    (is (null (fluxion.cells:drain-pending-events)))))
