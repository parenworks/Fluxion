;;;; -*- encoding:utf-8 -*-
;;;; Tests for propagators

(in-package #:fluxion.tests)
(in-suite propagators-suite)

(test propagator-basic
  "A propagator fires its function and writes the result to the output."
  (let* ((a (fluxion.cells:make-cell 5))
         (b (fluxion.cells:make-cell 0)))
    (fluxion.cells:make-propagator
     :inputs (list a)
     :fn (lambda (x) (* x 2))
     :outputs (list b))
    ;; Initial fire on creation
    (is (= 10 (fluxion.cells:cell-value b)))
    ;; Change input
    (setf (fluxion.cells:cell-value a) 7)
    (is (= 14 (fluxion.cells:cell-value b)))))

(test propagator-multiple-inputs
  "A propagator can read from multiple inputs."
  (let* ((a (fluxion.cells:make-cell 3))
         (b (fluxion.cells:make-cell 4))
         (c (fluxion.cells:make-cell 0)))
    (fluxion.cells:make-propagator
     :inputs (list a b)
     :fn (lambda (x y) (+ x y))
     :outputs (list c))
    (is (= 7 (fluxion.cells:cell-value c)))
    (setf (fluxion.cells:cell-value a) 10)
    (is (= 14 (fluxion.cells:cell-value c)))))

(test propagator-bidirectional
  "Two propagators form a bidirectional constraint."
  (let* ((celsius (fluxion.cells:make-cell 0))
         (fahrenheit (fluxion.cells:make-cell 32)))
    (fluxion.cells:make-propagator
     :inputs (list celsius)
     :fn (lambda (c) (+ (* c 9/5) 32))
     :outputs (list fahrenheit))
    (fluxion.cells:make-propagator
     :inputs (list fahrenheit)
     :fn (lambda (f) (* (- f 32) 5/9))
     :outputs (list celsius))
    ;; Set celsius, fahrenheit updates
    (setf (fluxion.cells:cell-value celsius) 100)
    (is (= 212 (fluxion.cells:cell-value fahrenheit)))
    ;; Set fahrenheit, celsius updates
    (setf (fluxion.cells:cell-value fahrenheit) 32)
    (is (= 0 (fluxion.cells:cell-value celsius)))))

(test propagator-exact-arithmetic
  "Bidirectional propagators converge exactly with rationals."
  (let* ((c (fluxion.cells:make-cell 0))
         (f (fluxion.cells:make-cell 32)))
    (fluxion.cells:make-propagator
     :inputs (list c)
     :fn (lambda (x) (+ (* x 9/5) 32))
     :outputs (list f))
    (fluxion.cells:make-propagator
     :inputs (list f)
     :fn (lambda (x) (* (- x 32) 5/9))
     :outputs (list c))
    ;; 37 C should be exactly 493/5 F
    (setf (fluxion.cells:cell-value c) 37)
    (is (= 493/5 (fluxion.cells:cell-value f)))
    ;; Going back: set F to 100, C should be exact
    (setf (fluxion.cells:cell-value f) 100)
    (is (= 340/9 (fluxion.cells:cell-value c)))))

(test propagator-no-infinite-loop
  "The re-entrance guard prevents infinite loops."
  ;; If the guard failed, this would hang forever.
  ;; Just verifying it completes without error.
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-cell 1)))
    (fluxion.cells:make-propagator
     :inputs (list a) :fn #'identity :outputs (list b))
    (fluxion.cells:make-propagator
     :inputs (list b) :fn #'identity :outputs (list a))
    (setf (fluxion.cells:cell-value a) 42)
    (is (= 42 (fluxion.cells:cell-value b)))
    (is (= 42 (fluxion.cells:cell-value a)))))

(test propagator-remove
  "remove-propagator disconnects the propagator from its inputs."
  (let* ((a (fluxion.cells:make-cell 1))
         (b (fluxion.cells:make-cell 0))
         (p (fluxion.cells:make-propagator
             :inputs (list a)
             :fn (lambda (x) (* x 10))
             :outputs (list b))))
    (is (= 10 (fluxion.cells:cell-value b)))
    (fluxion.cells:remove-propagator p)
    (setf (fluxion.cells:cell-value a) 5)
    ;; b should NOT have changed since propagator was removed
    (is (= 10 (fluxion.cells:cell-value b)))))

(test propagator-with-name
  "Propagators accept an optional name."
  (let* ((a (fluxion.cells:make-cell 0))
         (b (fluxion.cells:make-cell 0))
         (p (fluxion.cells:make-propagator
             :inputs (list a) :fn #'identity :outputs (list b)
             :name "test-prop")))
    (is (string= "test-prop" (fluxion.cells:propagator-name p)))))
