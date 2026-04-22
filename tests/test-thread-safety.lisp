;;;; -*- encoding:utf-8 -*-
;;;; Fluxion tests - Thread safety for the cell graph
;;;;
;;;; These tests verify that concurrent reads and writes to cells
;;;; produce correct results under contention.

(in-package #:fluxion.tests)

(in-suite thread-safety-suite)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defun make-threads (n fn)
  "Spawn N threads each running FN. Returns a list of threads."
  (loop for i below n
        collect (bt:make-thread (lambda () (funcall fn))
                                :name (format nil "test-thread-~D" i))))

(defun join-all (threads)
  "Join all threads and return."
  (dolist (th threads)
    (bt:join-thread th)))

;;; -------------------------------------------------------
;;; Tests
;;; -------------------------------------------------------

(test concurrent-writers-single-cell
  "Multiple threads writing to one cell should not corrupt state."
  (let ((c (fluxion.cells:make-cell 0 :name "counter"))
        (n-threads 8)
        (n-writes 1000))
    (let ((threads
            (loop for i below n-threads
                  collect (bt:make-thread
                           (lambda ()
                             (dotimes (_ n-writes)
                               (fluxion.cells:with-cell-lock
                                 (let ((v (fluxion.cells:cell-value c)))
                                   (setf (fluxion.cells:cell-value c) (1+ v))))))
                           :name (format nil "writer-~D" i)))))
      (join-all threads))
    (is (= (* n-threads n-writes) (fluxion.cells:cell-value c)))))

(test concurrent-writers-with-transaction
  "Multiple threads using with-transaction on the same cell."
  (let ((c (fluxion.cells:make-cell 0 :name "tx-counter"))
        (n-threads 8)
        (n-writes 500))
    (let ((threads
            (loop for i below n-threads
                  collect (bt:make-thread
                           (lambda ()
                             (dotimes (_ n-writes)
                               (fluxion.cells:with-transaction
                                 (let ((v (fluxion.cells:cell-value c)))
                                   (setf (fluxion.cells:cell-value c) (1+ v))))))
                           :name (format nil "tx-writer-~D" i)))))
      (join-all threads))
    (is (= (* n-threads n-writes) (fluxion.cells:cell-value c)))))

(test concurrent-read-write
  "Readers never see a partially updated state."
  (let ((a (fluxion.cells:make-cell 0 :name "a"))
        (b (fluxion.cells:make-cell 0 :name "b"))
        (bad-reads (list 0))
        (stop-flag (list nil))
        (n-writes 2000))
    ;; Writer: always sets a and b to the same value inside a transaction
    (let ((writer (bt:make-thread
                   (lambda ()
                     (dotimes (i n-writes)
                       (fluxion.cells:with-transaction
                         (setf (fluxion.cells:cell-value a) i)
                         (setf (fluxion.cells:cell-value b) i)))
                     (setf (car stop-flag) t))
                   :name "writer"))
          ;; Reader: checks a == b under the lock
          (readers (loop for r below 4
                         collect (bt:make-thread
                                  (lambda ()
                                    (loop until (car stop-flag) do
                                      (fluxion.cells:with-cell-lock
                                        (let ((va (slot-value a 'fluxion.cells::value))
                                              (vb (slot-value b 'fluxion.cells::value)))
                                          (unless (= va vb)
                                            (incf (car bad-reads)))))))
                                  :name (format nil "reader-~D" r)))))
      (bt:join-thread writer)
      (join-all readers))
    (is (= 0 (car bad-reads)))))

(test concurrent-watchers-fire-correctly
  "Watchers accumulate the correct total even under concurrent writes."
  (let ((c (fluxion.cells:make-cell 0 :name "watched" :test (constantly nil)))
        (fire-count (list 0))
        (lock (bt:make-lock "fire-lock"))
        (n-threads 4)
        (n-writes 500))
    (fluxion.cells:watch c
      (lambda (new old)
        (declare (ignore new old))
        (bt:with-lock-held (lock)
          (incf (car fire-count)))))
    (let ((threads
            (loop for i below n-threads
                  collect (bt:make-thread
                           (lambda ()
                             (dotimes (j n-writes)
                               (setf (fluxion.cells:cell-value c) j)))
                           :name (format nil "watcher-writer-~D" i)))))
      (join-all threads))
    (is (= (* n-threads n-writes) (car fire-count)))))

(test concurrent-computed-cell
  "Computed cells recompute correctly under concurrent source writes."
  (let* ((a (fluxion.cells:make-cell 0 :name "src-a"))
         (b (fluxion.cells:make-cell 0 :name "src-b"))
         (sum (fluxion.cells:make-computed
               (lambda ()
                 (+ (fluxion.cells:cell-value a)
                    (fluxion.cells:cell-value b)))
               :name "sum"))
         (n-writes 1000))
    (declare (ignore sum))
    ;; Two threads writing to a and b respectively
    (let ((t1 (bt:make-thread
               (lambda ()
                 (dotimes (i n-writes)
                   (setf (fluxion.cells:cell-value a) i)))
               :name "src-a-writer"))
          (t2 (bt:make-thread
               (lambda ()
                 (dotimes (i n-writes)
                   (setf (fluxion.cells:cell-value b) i)))
               :name "src-b-writer")))
      (bt:join-thread t1)
      (bt:join-thread t2))
    ;; After both finish, sum must equal a + b
    (is (= (+ (fluxion.cells:cell-value a)
              (fluxion.cells:cell-value b))
            (fluxion.cells:cell-value sum)))))

(test concurrent-transaction-isolation
  "Computed cells derived from multiple sources see consistent state
even when multiple threads write to the sources concurrently.
This is the correct FRP pattern: observe via computed cells, not
plain watchers, when you need multi-cell consistency."
  (let* ((a (fluxion.cells:make-cell 0 :name "iso-a"))
         (b (fluxion.cells:make-cell 0 :name "iso-b"))
         (diff (fluxion.cells:make-computed
                (lambda ()
                  (- (fluxion.cells:cell-value a)
                     (fluxion.cells:cell-value b)))
                :name "diff"))
         (mismatches (list 0))
         (lock (bt:make-lock "mismatch-lock")))
    ;; Watch the computed cell: it should always be 0 after a transaction
    ;; that sets a and b to the same value
    (fluxion.cells:watch diff
      (lambda (new old)
        (declare (ignore old))
        (unless (zerop new)
          (bt:with-lock-held (lock)
            (incf (car mismatches))))))
    ;; Two threads each set a=v, b=v inside a transaction
    (let ((threads
            (loop for t-id below 2
                  collect (bt:make-thread
                           (lambda ()
                             (dotimes (i 500)
                               (let ((v (+ (* t-id 1000) i)))
                                 (fluxion.cells:with-transaction
                                   (setf (fluxion.cells:cell-value a) v)
                                   (setf (fluxion.cells:cell-value b) v)))))
                           :name (format nil "iso-writer-~D" t-id)))))
      (join-all threads))
    (is (= 0 (car mismatches)))))

(test watch-unwatch-under-contention
  "Adding and removing watchers while other threads write doesn't crash."
  (let ((c (fluxion.cells:make-cell 0 :name "churn" :test (constantly nil)))
        (n-cycles 200))
    ;; Writer thread
    (let ((writer (bt:make-thread
                   (lambda ()
                     (dotimes (i (* n-cycles 5))
                       (setf (fluxion.cells:cell-value c) i)))
                   :name "churn-writer"))
          ;; Watcher churn thread
          (churner (bt:make-thread
                    (lambda ()
                      (dotimes (_ n-cycles)
                        (let ((w (fluxion.cells:watch c
                                   (lambda (n o) (declare (ignore n o))))))
                          (fluxion.cells:unwatch c w))))
                    :name "watcher-churner")))
      (bt:join-thread writer)
      (bt:join-thread churner))
    ;; If we get here without crashing, the test passes
    (is (numberp (fluxion.cells:cell-value c)))))
