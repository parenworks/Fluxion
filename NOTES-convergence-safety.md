# Convergence Safety in Lattice

## The Problem

Rational arithmetic guarantees exact round-trip convergence for single-step
bidirectional propagators (e.g. C-to-F and F-to-C). But if a propagator cycle
implements an iterative computation where the fixed point is irrational, exact
rational equality will never be satisfied.

Example (raised by selwyn-froggitt on IRC, 2026-04-25):

    a(n+1) = (a(n) + 2/a(n)) / 2

This is Newton's method for sqrt(2). Every step is rational-in, rational-out,
but the sequence converges to an irrational limit. Exact equality is never
reached, so propagation never halts. Worse, the numerators and denominators
grow exponentially, eventually exhausting memory.

## Why It Is Unlikely in Practice

Typical web UI propagators are single-step rational operations:

- Currency/unit conversion (multiply/divide by a constant)
- Percentage calculations (price * rate)
- Layout constraints (width = parent - padding)
- Form derivations (total = qty * unit_price)

These converge in one pass. The problematic case requires a cycle where the
function's fixed point is irrational, which is hard to create accidentally
with UI constraints.

## Possible Solutions

### 1. Max propagation rounds (iteration cap)

Add a configurable limit to the `tx-flush` loop. If the queue keeps refilling
beyond N iterations (e.g. 100), signal a condition rather than looping forever.
This prevents both infinite loops and OOM from unbounded rational growth.

```lisp
(defvar *max-propagation-rounds* 100
  "Maximum number of flush iterations per transaction before signalling an error.")

(defun tx-flush (tx)
  (loop with rounds = 0 while (tx-queue tx) do
    (when (> (incf rounds) *max-propagation-rounds*)
      (error 'propagation-limit-exceeded
             :rounds rounds
             :remaining (length (tx-queue tx))))
    (let ((sorted (sort (tx-queue tx) #'< :key #'cell-height)))
      (setf (tx-queue tx) nil)
      (clrhash (tx-seen tx))
      (dolist (cell sorted)
        (typecase cell
          (computed-cell (recompute cell))
          (t (notify-watchers cell
                              (slot-value cell 'value)
                              (slot-value cell 'value))))))))
```

### 2. Custom equality test with tolerance

Already supported via the `:test` keyword on `make-cell` and `make-computed`.
For any propagator that might produce asymptotically converging values, use an
approximate equality test:

```lisp
(make-cell 0.0
  :test (lambda (a b)
          (< (abs (- a b)) 1e-10)))
```

### 3. Rational size guard

Detect when rational numerators/denominators exceed a threshold and either
coerce to float or signal a condition:

```lisp
(defun rational-too-large-p (value &optional (limit (expt 2 128)))
  (and (rationalp value)
       (or (> (abs (numerator value)) limit)
           (> (abs (denominator value)) limit))))
```

This could be checked in `(setf cell-value)` or as an optional cell guard.

## Recommended Approach

Implement solution 1 (iteration cap) as a baseline safety net. It costs almost
nothing and catches all runaway propagation regardless of cause. Solutions 2
and 3 are available for specific cases where developers know they need them.

## Tests to Write

### Test: iteration cap triggers on divergent cycle

Wire up the Newton sqrt(2) recurrence as a propagator cycle. Verify that
`tx-flush` signals `propagation-limit-exceeded` rather than looping forever.

```lisp
(deftest test-propagation-limit ()
  (let* ((a (make-cell 1)))
    (make-propagator
     :inputs (list a)
     :fn (lambda (x) (/ (+ x (/ 2 x)) 2))
     :outputs (list a))
    (signals propagation-limit-exceeded
      (with-transaction
        (setf (cell-value a) 1)))))
```

### Test: rational growth detection

Start with a rational cell, run several iterations of the sqrt(2) recurrence,
verify that numerator/denominator size grows as expected.

```lisp
(deftest test-rational-growth ()
  (let ((v 1))
    (dotimes (i 10)
      (setf v (/ (+ v (/ 2 v)) 2)))
    (is (> (integer-length (numerator v)) 500))))
```

### Test: tolerance-based equality halts propagation

Same sqrt(2) cycle but with an approximate `:test`. Verify propagation halts
within a small number of rounds and the result is close to sqrt(2).

```lisp
(deftest test-tolerance-convergence ()
  (let* ((a (make-cell 1.0d0
              :test (lambda (a b) (< (abs (- a b)) 1d-12)))))
    (make-propagator
     :inputs (list a)
     :fn (lambda (x) (/ (+ x (/ 2.0d0 x)) 2.0d0))
     :outputs (list a))
    (with-transaction
      (setf (cell-value a) 1.0d0))
    (is (< (abs (- (cell-value a) (sqrt 2.0d0))) 1d-10))))
```

### Test: normal bidirectional propagators still converge in one round

Ensure the iteration cap does not interfere with standard use cases. The
temperature converter should complete in exactly one flush iteration.

```lisp
(deftest test-single-round-convergence ()
  (let ((c (make-cell 0))
        (f (make-cell 32)))
    (make-propagator :inputs (list c) :fn (lambda (c) (+ (* c 9/5) 32)) :outputs (list f))
    (make-propagator :inputs (list f) :fn (lambda (f) (* (- f 32) 5/9)) :outputs (list c))
    (with-transaction
      (setf (cell-value c) 100))
    (is (= (cell-value f) 212))
    (is (= (cell-value c) 100))))
```
