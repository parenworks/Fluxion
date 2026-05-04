;;;; -*- encoding:utf-8 -*-
;;;; Tests for convergence safety (iteration cap, rational guard, tolerance)

(in-package #:fluxion.tests)
(in-suite convergence-suite)

;;; -------------------------------------------------------
;;; Solution 1: Iteration cap triggers on divergent cycle
;;; -------------------------------------------------------

(test propagation-limit-divergent-cycle
  "A computed cell feedback loop that cannot converge signals
PROPAGATION-LIMIT-EXCEEDED rather than looping forever."
  ;; Newton's method for sqrt(2): a(n+1) = (a(n) + 2/a(n)) / 2
  ;; Fixed point is irrational, so exact rationals never converge.
  ;; We use computed cell b = newton(a), with a feedback watcher b->a,
  ;; which cycles through the tx-flush queue.
  ;; Cap at 10 rounds: rational numerators double in size each step,
  ;; so 100 rounds would produce numbers with 2^100 digits.
  (let* ((fluxion.cells:*max-propagation-rounds* 10)
         (a (fluxion.cells:make-cell 10))
         (b (fluxion.cells:make-computed
             (lambda () (/ (+ (fluxion.cells:cell-value a)
                               (/ 2 (fluxion.cells:cell-value a)))
                            2)))))
    ;; Feedback: when b recomputes, write the new value back to a
    (fluxion.cells:watch b
      (lambda (nv ov) (declare (ignore ov))
        (setf (fluxion.cells:cell-value a) nv)))
    (signals fluxion.cells:propagation-limit-exceeded
      (fluxion.cells:with-transaction
        (setf (fluxion.cells:cell-value a) 1)))))

(test propagation-limit-condition-slots
  "The PROPAGATION-LIMIT-EXCEEDED condition carries rounds and remaining info."
  (let* ((fluxion.cells:*max-propagation-rounds* 10)
         (a (fluxion.cells:make-cell 10))
         (b (fluxion.cells:make-computed
             (lambda () (/ (+ (fluxion.cells:cell-value a)
                               (/ 2 (fluxion.cells:cell-value a)))
                            2)))))
    (fluxion.cells:watch b
      (lambda (nv ov) (declare (ignore ov))
        (setf (fluxion.cells:cell-value a) nv)))
    (handler-case
        (fluxion.cells:with-transaction
          (setf (fluxion.cells:cell-value a) 1))
      (fluxion.cells:propagation-limit-exceeded (c)
        (is (= 11 (fluxion.cells:propagation-limit-rounds c)))
        (is (plusp (fluxion.cells:propagation-limit-remaining c)))))))

(test propagation-limit-custom-cap
  "A lower *max-propagation-rounds* triggers earlier."
  (let* ((fluxion.cells:*max-propagation-rounds* 5)
         (a (fluxion.cells:make-cell 10))
         (b (fluxion.cells:make-computed
             (lambda () (/ (+ (fluxion.cells:cell-value a)
                               (/ 2 (fluxion.cells:cell-value a)))
                            2)))))
    (fluxion.cells:watch b
      (lambda (nv ov) (declare (ignore ov))
        (setf (fluxion.cells:cell-value a) nv)))
    (handler-case
        (fluxion.cells:with-transaction
          (setf (fluxion.cells:cell-value a) 1))
      (fluxion.cells:propagation-limit-exceeded (c)
        (is (= 6 (fluxion.cells:propagation-limit-rounds c)))))))

(test propagation-limit-nil-disables
  "Setting *max-propagation-rounds* to NIL disables the cap.
We test with a cycle that converges quickly (identity) to ensure no error."
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-cell 1))
         (fluxion.cells:*max-propagation-rounds* nil))
    (fluxion.cells:make-propagator
     :inputs (list a) :fn #'identity :outputs (list b))
    (fluxion.cells:make-propagator
     :inputs (list b) :fn #'identity :outputs (list a))
    (finishes
      (fluxion.cells:with-transaction
        (setf (fluxion.cells:cell-value a) 42)))
    (is (= 42 (fluxion.cells:cell-value a)))
    (is (= 42 (fluxion.cells:cell-value b)))))

;;; -------------------------------------------------------
;;; Solution 2: Tolerance-based equality halts propagation
;;; -------------------------------------------------------

(test tolerance-convergence
  "A divergent-in-rationals cycle converges with an approximate :test.
Uses Newton sqrt(2) with double-float, tolerance test, and feedback watcher."
  (let* ((tol (lambda (a b)
                (and (numberp a) (numberp b)
                     (< (abs (- a b)) 1d-12))))
         (a (fluxion.cells:make-cell 10.0d0 :test tol))
         (b (fluxion.cells:make-computed
             (lambda () (/ (+ (fluxion.cells:cell-value a)
                               (/ 2.0d0 (fluxion.cells:cell-value a)))
                            2.0d0))
             :test tol)))
    (fluxion.cells:watch b
      (lambda (nv ov) (declare (ignore ov))
        (setf (fluxion.cells:cell-value a) nv)))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value a) 1.0d0))
    ;; Result should be close to sqrt(2)
    (is (< (abs (- (fluxion.cells:cell-value a) (sqrt 2.0d0))) 1d-10))))

(test tolerance-convergence-within-cap
  "Tolerance convergence completes well within the propagation cap."
  (let* ((feedback-count 0)
         (tol (lambda (a b)
                (and (numberp a) (numberp b)
                     (< (abs (- a b)) 1d-12))))
         (a (fluxion.cells:make-cell 10.0d0 :test tol))
         (b (fluxion.cells:make-computed
             (lambda () (/ (+ (fluxion.cells:cell-value a)
                               (/ 2.0d0 (fluxion.cells:cell-value a)))
                            2.0d0))
             :test tol)))
    (fluxion.cells:watch b
      (lambda (nv ov) (declare (ignore ov))
        (incf feedback-count)
        (setf (fluxion.cells:cell-value a) nv)))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value a) 1.0d0))
    ;; Newton's method converges very fast for sqrt(2); should need < 10 feedback rounds
    (is (< feedback-count 20))))

;;; -------------------------------------------------------
;;; Solution 3: Rational size guard
;;; -------------------------------------------------------

(test rational-too-large-p-small
  "Small rationals are not flagged."
  (is (not (fluxion.cells:rational-too-large-p 1/3)))
  (is (not (fluxion.cells:rational-too-large-p 0)))
  (is (not (fluxion.cells:rational-too-large-p 42)))
  (is (not (fluxion.cells:rational-too-large-p -100/7))))

(test rational-too-large-p-large
  "Rationals with huge numerator or denominator are flagged."
  (is (fluxion.cells:rational-too-large-p (/ (expt 2 200) 1)))
  (is (fluxion.cells:rational-too-large-p (/ 1 (expt 2 200)))))

(test rational-too-large-p-custom-limit
  "Custom limit controls the threshold."
  (is (not (fluxion.cells:rational-too-large-p 100/1 1000)))
  (is (fluxion.cells:rational-too-large-p 10001/1 1000))
  (is (fluxion.cells:rational-too-large-p 1/10001 1000)))

(test rational-too-large-p-non-rational
  "Non-rational values return NIL."
  (is (not (fluxion.cells:rational-too-large-p 3.14)))
  (is (not (fluxion.cells:rational-too-large-p "hello")))
  (is (not (fluxion.cells:rational-too-large-p nil))))

(test rational-growth-detection
  "Newton sqrt(2) iterations produce exponentially growing rationals."
  (let ((v 1))
    (dotimes (i 10)
      (setf v (/ (+ v (/ 2 v)) 2)))
    ;; After 10 iterations, numerator should be > 500 bits
    (is (> (integer-length (numerator v)) 500))
    ;; And it should be flagged by the guard
    (is (fluxion.cells:rational-too-large-p v))))

;;; -------------------------------------------------------
;;; Regression: normal propagators still converge in one round
;;; -------------------------------------------------------

(test single-round-convergence
  "Standard bidirectional temperature converter converges immediately.
The iteration cap does not interfere with normal use."
  (let ((c (fluxion.cells:make-cell 0))
        (f (fluxion.cells:make-cell 32)))
    (fluxion.cells:make-propagator
     :inputs (list c)
     :fn (lambda (c) (+ (* c 9/5) 32))
     :outputs (list f))
    (fluxion.cells:make-propagator
     :inputs (list f)
     :fn (lambda (f) (* (- f 32) 5/9))
     :outputs (list c))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value c) 100))
    (is (= (fluxion.cells:cell-value f) 212))
    (is (= (fluxion.cells:cell-value c) 100))))

(test single-round-exact-rational
  "Exact rational propagators converge perfectly."
  (let ((c (fluxion.cells:make-cell 0))
        (f (fluxion.cells:make-cell 32)))
    (fluxion.cells:make-propagator
     :inputs (list c)
     :fn (lambda (x) (+ (* x 9/5) 32))
     :outputs (list f))
    (fluxion.cells:make-propagator
     :inputs (list f)
     :fn (lambda (x) (* (- x 32) 5/9))
     :outputs (list c))
    ;; 37 C = 493/5 F
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value c) 37))
    (is (= 493/5 (fluxion.cells:cell-value f)))
    ;; 100 F = 340/9 C
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value f) 100))
    (is (= 340/9 (fluxion.cells:cell-value c)))))

(test computed-chain-with-cap
  "Computed cell chains work normally with the iteration cap active."
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-computed
             (lambda () (* 2 (fluxion.cells:cell-value a)))))
         (c (fluxion.cells:make-computed
             (lambda () (+ 10 (fluxion.cells:cell-value b))))))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value a) 5))
    (is (= 10 (fluxion.cells:cell-value b)))
    (is (= 20 (fluxion.cells:cell-value c)))))

(test diamond-with-cap
  "Diamond dependency with iteration cap active resolves without glitch."
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-computed
             (lambda () (* 10 (fluxion.cells:cell-value a)))))
         (c (fluxion.cells:make-computed
             (lambda () (+ 100 (fluxion.cells:cell-value a)))))
         (d (fluxion.cells:make-computed
             (lambda () (list (fluxion.cells:cell-value b)
                              (fluxion.cells:cell-value c)))))
         (log nil))
    (fluxion.cells:watch d
      (lambda (nv ov) (declare (ignore ov)) (push nv log)))
    (fluxion.cells:with-transaction
      (setf (fluxion.cells:cell-value a) 2))
    ;; D fires exactly once with consistent state
    (is (= 1 (length log)))
    (is (equal '(20 102) (first log)))))
