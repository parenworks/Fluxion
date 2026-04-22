;;;; -*- encoding:utf-8 -*-
;;;; Tests for computed cells

(in-package #:fluxion.tests)
(in-suite computed-suite)

(test computed-basic
  "A computed cell derives its value from a thunk."
  (let* ((a (fluxion.cells:make-cell 10))
         (doubled (fluxion.cells:make-computed
                   (lambda ()
                     (* 2 (fluxion.cells:cell-value a))))))
    (is (= 20 (fluxion.cells:cell-value doubled)))))

(test computed-recomputes-on-dependency-change
  "Changing a dependency recomputes the computed cell."
  (let* ((a (fluxion.cells:make-cell 5))
         (c (fluxion.cells:make-computed
             (lambda ()
               (+ 1 (fluxion.cells:cell-value a))))))
    (is (= 6 (fluxion.cells:cell-value c)))
    (setf (fluxion.cells:cell-value a) 10)
    (is (= 11 (fluxion.cells:cell-value c)))))

(test computed-multiple-dependencies
  "A computed cell can depend on multiple cells."
  (let* ((a (fluxion.cells:make-cell 2))
         (b (fluxion.cells:make-cell 3))
         (sum (fluxion.cells:make-computed
               (lambda ()
                 (+ (fluxion.cells:cell-value a)
                    (fluxion.cells:cell-value b))))))
    (is (= 5 (fluxion.cells:cell-value sum)))
    (setf (fluxion.cells:cell-value a) 10)
    (is (= 13 (fluxion.cells:cell-value sum)))
    (setf (fluxion.cells:cell-value b) 7)
    (is (= 17 (fluxion.cells:cell-value sum)))))

(test computed-chain
  "Computed cells can depend on other computed cells."
  (let* ((base (fluxion.cells:make-cell 1))
         (doubled (fluxion.cells:make-computed
                   (lambda () (* 2 (fluxion.cells:cell-value base)))))
         (quadrupled (fluxion.cells:make-computed
                      (lambda () (* 2 (fluxion.cells:cell-value doubled))))))
    (is (= 2 (fluxion.cells:cell-value doubled)))
    (is (= 4 (fluxion.cells:cell-value quadrupled)))
    (setf (fluxion.cells:cell-value base) 5)
    (is (= 10 (fluxion.cells:cell-value doubled)))
    (is (= 20 (fluxion.cells:cell-value quadrupled)))))

(test computed-with-watcher
  "Watchers on computed cells fire when the computed value changes."
  (let* ((a (fluxion.cells:make-cell 1))
         (c (fluxion.cells:make-computed
             (lambda () (* 10 (fluxion.cells:cell-value a)))))
         (log nil))
    (fluxion.cells:watch c
      (lambda (new old)
        (push (list old new) log)))
    (setf (fluxion.cells:cell-value a) 2)
    (is (= 1 (length log)))
    (is (equal '(10 20) (first log)))))

(test computed-no-spurious-notify
  "If the computed result is the same, watchers are not called."
  (let* ((a (fluxion.cells:make-cell 5))
         (clamped (fluxion.cells:make-computed
                   (lambda ()
                     (min 10 (fluxion.cells:cell-value a)))))
         (count 0))
    (fluxion.cells:watch clamped
      (lambda (n o) (declare (ignore n o)) (incf count)))
    ;; clamped is 5. Change a to 3, clamped becomes 3 -> fires.
    (setf (fluxion.cells:cell-value a) 3)
    (is (= 1 count))
    ;; Change a to 15, clamped becomes 10 -> fires.
    (setf (fluxion.cells:cell-value a) 15)
    (is (= 2 count))
    ;; Change a to 20, clamped stays 10 -> should NOT fire.
    (setf (fluxion.cells:cell-value a) 20)
    (is (= 2 count))))

(test computed-string-value
  "Computed cells work with string values."
  (let* ((name (fluxion.cells:make-cell "world"))
         (greeting (fluxion.cells:make-computed
                    (lambda ()
                      (format nil "Hello, ~A!" (fluxion.cells:cell-value name))))))
    (is (string= "Hello, world!" (fluxion.cells:cell-value greeting)))
    (setf (fluxion.cells:cell-value name) "Lisp")
    (is (string= "Hello, Lisp!" (fluxion.cells:cell-value greeting)))))
