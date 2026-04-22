;;;; -*- encoding:utf-8 -*-
;;;; Tests for glitch-free transactions (v0.6)

(in-package #:fluxion.tests)
(in-suite transactions-suite)

;;; -------------------------------------------------------
;;; Height tracking
;;; -------------------------------------------------------

(test cell-height-base
  "Base cells have height 0."
  (let ((c (fluxion.cells:make-cell 1)))
    (is (= 0 (fluxion.cells:cell-height c)))))

(test computed-height-one-level
  "A computed depending on base cells has height 1."
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-computed
             (lambda () (* 2 (fluxion.cells:cell-value a))))))
    (is (= 1 (fluxion.cells:cell-height b)))))

(test computed-height-chain
  "Heights increase along a dependency chain."
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-computed
             (lambda () (* 2 (fluxion.cells:cell-value a)))))
         (c (fluxion.cells:make-computed
             (lambda () (+ 1 (fluxion.cells:cell-value b))))))
    (is (= 0 (fluxion.cells:cell-height a)))
    (is (= 1 (fluxion.cells:cell-height b)))
    (is (= 2 (fluxion.cells:cell-height c)))))

;;; -------------------------------------------------------
;;; Diamond glitch - the core test
;;; -------------------------------------------------------

(test diamond-glitch-without-transaction
  "Without a transaction, D sees a glitch (recomputes twice)."
  (let* ((log nil)
         (a (fluxion.cells:make-cell 1 :name "A"))
         (b (fluxion.cells:make-computed
             (lambda () (* 10 (fluxion.cells:cell-value a)))
             :name "B"))
         (c (fluxion.cells:make-computed
             (lambda () (+ 100 (fluxion.cells:cell-value a)))
             :name "C"))
         (d (fluxion.cells:make-computed
             (lambda () (list (fluxion.cells:cell-value b)
                              (fluxion.cells:cell-value c)))
             :name "D")))
    (fluxion.cells:watch d
      (lambda (nv ov)
        (declare (ignore ov))
        (push nv log)))
    (setf (fluxion.cells:cell-value a) 2)
    ;; D fires more than once - the glitch
    (is (> (length log) 1))
    ;; Final value is correct
    (is (equal '(20 102) (fluxion.cells:cell-value d)))))

(test diamond-glitch-with-transaction
  "With a transaction, D recomputes exactly once with consistent state."
  (let* ((log nil)
         (a (fluxion.cells:make-cell 1 :name "A"))
         (b (fluxion.cells:make-computed
             (lambda () (* 10 (fluxion.cells:cell-value a)))
             :name "B"))
         (c (fluxion.cells:make-computed
             (lambda () (+ 100 (fluxion.cells:cell-value a)))
             :name "C"))
         (d (fluxion.cells:make-computed
             (lambda () (list (fluxion.cells:cell-value b)
                              (fluxion.cells:cell-value c)))
             :name "D")))
    (fluxion.cells:watch d
      (lambda (nv ov)
        (declare (ignore ov))
        (push nv log)))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value a) 2))
    ;; D fires exactly once - no glitch
    (is (= 1 (length log)))
    ;; The single observation is consistent
    (is (equal '(20 102) (first log)))
    ;; Final value is correct
    (is (equal '(20 102) (fluxion.cells:cell-value d)))))

;;; -------------------------------------------------------
;;; Wider diamond (multiple intermediate nodes)
;;; -------------------------------------------------------

(test wide-diamond-transaction
  "Transaction handles a 4-way fan-out correctly."
  (let* ((a (fluxion.cells:make-cell 0))
         (b1 (fluxion.cells:make-computed
              (lambda () (+ 1 (fluxion.cells:cell-value a)))))
         (b2 (fluxion.cells:make-computed
              (lambda () (+ 2 (fluxion.cells:cell-value a)))))
         (b3 (fluxion.cells:make-computed
              (lambda () (+ 3 (fluxion.cells:cell-value a)))))
         (d (fluxion.cells:make-computed
             (lambda () (+ (fluxion.cells:cell-value b1)
                           (fluxion.cells:cell-value b2)
                           (fluxion.cells:cell-value b3)))))
         (log nil))
    (fluxion.cells:watch d
      (lambda (nv ov) (declare (ignore ov)) (push nv log)))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value a) 10))
    ;; D recomputes once: (10+1) + (10+2) + (10+3) = 36
    (is (= 1 (length log)))
    (is (= 36 (first log)))))

;;; -------------------------------------------------------
;;; Nested transactions
;;; -------------------------------------------------------

(test nested-transactions
  "Nested transactions are absorbed by the outermost."
  (let* ((a (fluxion.cells:make-cell 0))
         (b (fluxion.cells:make-computed
             (lambda () (* 2 (fluxion.cells:cell-value a)))))
         (log nil))
    (fluxion.cells:watch b
      (lambda (nv ov) (declare (ignore ov)) (push nv log)))
    (fluxion.cells:with-transaction
      (fluxion.cells:with-transaction
        (setf (fluxion.cells:cell-value a) 5))
      ;; Inner transaction doesn't flush yet
      (is (null log))
      (setf (fluxion.cells:cell-value a) 10))
    ;; Only the final value reaches the watcher
    (is (= 1 (length log)))
    (is (= 20 (first log)))))

;;; -------------------------------------------------------
;;; Multi-source transaction
;;; -------------------------------------------------------

(test multi-source-transaction
  "Transaction batches changes to multiple source cells."
  (let* ((x (fluxion.cells:make-cell 1))
         (y (fluxion.cells:make-cell 2))
         (sum (fluxion.cells:make-computed
               (lambda () (+ (fluxion.cells:cell-value x)
                             (fluxion.cells:cell-value y)))))
         (log nil))
    (fluxion.cells:watch sum
      (lambda (nv ov) (declare (ignore ov)) (push nv log)))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value x) 10)
      (setf (fluxion.cells:cell-value y) 20))
    ;; sum recomputes once: 10 + 20 = 30
    (is (= 1 (length log)))
    (is (= 30 (first log)))))

;;; -------------------------------------------------------
;;; Propagator within transaction
;;; -------------------------------------------------------

(test propagator-wraps-in-transaction
  "Propagators use transactions internally to prevent glitches."
  (let* ((input (fluxion.cells:make-cell 1))
         (output (fluxion.cells:make-cell 0))
         (derived (fluxion.cells:make-computed
                   (lambda () (* 3 (fluxion.cells:cell-value output)))))
         (log nil))
    (fluxion.cells:make-propagator
     :inputs (list input) :outputs (list output)
     :fn (lambda (v) (* 2 v)))
    (fluxion.cells:watch derived
      (lambda (nv ov) (declare (ignore ov)) (push nv log)))
    ;; Change input, propagator fires, sets output, derived recomputes
    (setf (fluxion.cells:cell-value input) 5)
    ;; derived = 3 * (2 * 5) = 30
    (is (= 30 (fluxion.cells:cell-value derived)))))
