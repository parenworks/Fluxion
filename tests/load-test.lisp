;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Load Test
;;;;
;;;; Combined internal harness and HTTP stack load test.
;;;; Run with: sbcl --load tests/load-test.lisp
;;;;
;;;; Tests:
;;;;   1. Cell engine throughput (concurrent writers, computed cells, watchers)
;;;;   2. Session management at scale (create, access, reap)
;;;;   3. SSE event push throughput (broadcast to many sessions)
;;;;   4. HTTP stack under load (concurrent GET/POST via dexador)
;;;;   5. Memory stability (before/after comparison, GC pressure)

(ql:quickload '("fluxion" "fluxion/tests" "dexador" "bordeaux-threads") :silent t)

(defpackage #:fluxion.load-test
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:cells #:fluxion.cells)
                    (#:server #:fluxion.server)
                    (#:events #:fluxion.events)
                    (#:components #:fluxion.components)
                    (#:render #:fluxion.render)))

(in-package #:fluxion.load-test)

;;; -------------------------------------------------------
;;; Utilities
;;; -------------------------------------------------------

(defun timestamp ()
  (multiple-value-bind (s min h) (get-decoded-time)
    (format nil "~2,'0D:~2,'0D:~2,'0D" h min s)))

(defun report (label &rest args)
  (format t "[~A] ~A~%" (timestamp) (apply #'format nil label args)))

(defun mem-mb ()
  "Current dynamic space usage in MB."
  (/ (sb-kernel:dynamic-usage) 1024.0 1024.0))

(defun gc-and-mem ()
  "Force GC and return memory in MB."
  (sb-ext:gc :full t)
  (mem-mb))

(defmacro timed (label &body body)
  "Execute BODY, print elapsed time, return the result."
  (let ((start (gensym)) (result (gensym)) (elapsed (gensym)))
    `(let ((,start (get-internal-real-time)))
       (let ((,result (progn ,@body)))
         (let ((,elapsed (/ (- (get-internal-real-time) ,start)
                            (float internal-time-units-per-second))))
           (report "~A: ~,3Fs" ,label ,elapsed)
           ,result)))))

(defun join-all (threads)
  (dolist (th threads) (bt:join-thread th)))

;;; -------------------------------------------------------
;;; Test 1: Cell engine throughput
;;; -------------------------------------------------------

(defun test-cell-throughput ()
  (report "=== Test 1: Cell Engine Throughput ===")
  (let ((n-threads 8)
        (n-writes 10000))
    ;; Raw writes
    (let ((c (cells:make-cell 0 :name "perf-counter")))
      (timed (format nil "  ~:D writes across ~D threads (with-cell-lock)"
                     (* n-threads n-writes) n-threads)
        (join-all
         (loop for i below n-threads
               collect (bt:make-thread
                        (lambda ()
                          (dotimes (_ n-writes)
                            (cells:with-cell-lock
                              (let ((v (cells:cell-value c)))
                                (setf (cells:cell-value c) (1+ v))))))
                        :name (format nil "w-~D" i)))))
      (report "  Final value: ~:D (expected ~:D)" (cells:cell-value c) (* n-threads n-writes)))

    ;; Transaction writes
    (let ((a (cells:make-cell 0 :name "tx-a"))
          (b (cells:make-cell 0 :name "tx-b")))
      (timed (format nil "  ~:D transactions across ~D threads"
                     (* n-threads n-writes) n-threads)
        (join-all
         (loop for i below n-threads
               collect (bt:make-thread
                        (lambda ()
                          (dotimes (j n-writes)
                            (cells:with-transaction
                              (setf (cells:cell-value a) j)
                              (setf (cells:cell-value b) j))))
                        :name (format nil "tx-~D" i))))))

    ;; Computed cell recomputation throughput
    (let* ((src (cells:make-cell 0 :name "src"))
           (c1 (cells:make-computed (lambda () (* 2 (cells:cell-value src))) :name "c1"))
           (c2 (cells:make-computed (lambda () (+ 100 (cells:cell-value src))) :name "c2"))
           (c3 (cells:make-computed (lambda () (+ (cells:cell-value c1)
                                                   (cells:cell-value c2))) :name "c3"))
           (fire-count 0)
           (lock (bt:make-lock "fc")))
      (declare (ignore c3))
      (cells:watch c3 (lambda (n o) (declare (ignore n o))
                         (bt:with-lock-held (lock) (incf fire-count))))
      (timed (format nil "  ~:D source writes with 3-level computed chain" (* n-threads 5000))
        (join-all
         (loop for i below n-threads
               collect (bt:make-thread
                        (lambda ()
                          (dotimes (j 5000)
                            (cells:with-transaction
                              (setf (cells:cell-value src) j))))
                        :name (format nil "comp-~D" i)))))
      (report "  Watcher fired ~:D times" fire-count))))

;;; -------------------------------------------------------
;;; Test 2: Session management at scale
;;; -------------------------------------------------------

(defun test-session-scale ()
  (report "=== Test 2: Session Management at Scale ===")
  (let ((app (server:make-fluxion-app :session-ttl 5 :reaper-interval 1))
        (n-sessions 5000))
    ;; Mass creation
    (timed (format nil "  Create ~:D sessions" n-sessions)
      (dotimes (i n-sessions)
        (let ((s (make-instance 'server:session
                   :id (format nil "load-~D" i))))
          (bt:with-lock-held ((server:app-session-lock app))
            (setf (gethash (server:session-id s) (server:app-sessions app)) s)))))
    (report "  Session count: ~:D" (hash-table-count (server:app-sessions app)))

    ;; Concurrent access
    (timed "  Concurrent touch from 8 threads"
      (join-all
       (loop for t-id below 8
             collect (bt:make-thread
                      (lambda ()
                        (dotimes (i (/ n-sessions 8))
                          (let ((sid (format nil "load-~D" (+ i (* t-id (/ n-sessions 8))))))
                            (bt:with-lock-held ((server:app-session-lock app))
                              (let ((s (gethash sid (server:app-sessions app))))
                                (when s (server:touch-session s)))))))
                      :name (format nil "touch-~D" t-id)))))

    ;; Backdate half and reap
    (bt:with-lock-held ((server:app-session-lock app))
      (let ((count 0))
        (maphash (lambda (k session)
                   (declare (ignore k))
                   (when (< count (/ n-sessions 2))
                     (setf (fluxion.server::session-last-accessed-at session)
                           (- (get-universal-time) 100))
                     (incf count)))
                 (server:app-sessions app))))
    (let ((reaped 0))
      (timed (format nil "  Reap ~:D expired sessions" (/ n-sessions 2))
        (setf reaped (server:reap-sessions app)))
      (report "  Reaped: ~:D, remaining: ~:D" reaped (hash-table-count (server:app-sessions app))))))

;;; -------------------------------------------------------
;;; Test 3: SSE event push throughput
;;; -------------------------------------------------------

(defun test-sse-push-throughput ()
  (report "=== Test 3: SSE Event Push Throughput ===")
  (let ((app (server:make-fluxion-app))
        (n-sessions 500)
        (n-events 100)
        (sessions nil))
    ;; Create sessions with event queues
    (timed (format nil "  Create ~:D sessions with event queues" n-sessions)
      (dotimes (i n-sessions)
        (let ((s (make-instance 'server:session
                   :id (format nil "sse-~D" i))))
          (server:ensure-event-queue s)
          (bt:with-lock-held ((server:app-session-lock app))
            (setf (gethash (server:session-id s) (server:app-sessions app)) s))
          (push s sessions))))
    ;; Broadcast events to all sessions
    (let ((event (events:make-patch-event "#test" "<div id='test'>updated</div>")))
      (timed (format nil "  Broadcast ~:D events to ~:D sessions (~:D total)"
                     n-events n-sessions (* n-events n-sessions))
        (dotimes (_ n-events)
          (dolist (s sessions)
            (server:push-event s event)))))
    ;; Clean up
    (dolist (s sessions)
      (let ((q (fluxion.server::session-event-queue s)))
        (when q (server:close-event-queue q))))))

;;; -------------------------------------------------------
;;; Test 4: HTTP stack under load
;;; -------------------------------------------------------

(defclass load-test-widget (components:component)
  ((counter :initform 0 :accessor widget-counter))
  (:default-initargs :id "load-widget"))

(defmethod components:render ((w load-test-widget))
  (format nil "<div id='~A'><p>Count: ~D</p></div>"
          (components:component-id w) (widget-counter w)))

(defmethod components:handle-action ((w load-test-widget) (action (eql :bump)) params)
  (declare (ignore params))
  (incf (widget-counter w))
  nil)

(defvar *load-test-app* nil)
(defvar *load-test-port* 5299)

(defun start-load-test-server ()
  (setf *load-test-app* (server:make-fluxion-app :port *load-test-port*))
  (server:register-component-factory *load-test-app* "load-widget"
    (lambda () (make-instance 'load-test-widget)))
  (server:start *load-test-app*
    (lambda (app session env)
      (declare (ignore app env))
      (let ((w (server:session-component session "load-widget")))
        (list 200 '(:content-type "text/html")
              (list (render:render-page
                     :title "Load Test"
                     :csrf-token (server:session-csrf-token session)
                     :body-html (components:render w))))))))

(defun stop-load-test-server ()
  (when *load-test-app*
    (server:stop *load-test-app*)
    (setf *load-test-app* nil)))

(defun test-http-stack ()
  (report "=== Test 4: HTTP Stack Under Load ===")
  (start-load-test-server)
  (sleep 0.5)
  (let ((base-url (format nil "http://127.0.0.1:~D" *load-test-port*))
        (n-clients 8)
        (n-requests 200)
        (errors (list 0))
        (err-lock (bt:make-lock "err")))
    (unwind-protect
         (progn
           ;; Concurrent GET requests
           (timed (format nil "  ~:D concurrent GET / requests across ~D threads"
                          (* n-clients n-requests) n-clients)
             (join-all
              (loop for i below n-clients
                    collect (bt:make-thread
                             (lambda ()
                               (dotimes (_ n-requests)
                                 (handler-case
                                     (dex:get (format nil "~A/" base-url))
                                   (error ()
                                     (bt:with-lock-held (err-lock)
                                       (incf (car errors)))))))
                             :name (format nil "get-~D" i)))))
           (report "  GET errors: ~D / ~:D" (car errors) (* n-clients n-requests))
           (report "  Active sessions: ~:D"
                   (hash-table-count (server:app-sessions *load-test-app*)))

           ;; Concurrent POST action requests
           ;; Each thread gets its own session + CSRF token
           (setf (car errors) 0)
           (let ((cookie-jar (cl-cookie:make-cookie-jar)))
             ;; Get a session and extract the CSRF token
             (multiple-value-bind (body status)
                 (dex:get (format nil "~A/" base-url) :cookie-jar cookie-jar)
               (declare (ignore status))
               (let ((csrf-token
                       (let ((pos (search "content=\"" body
                                          :start2 (or (search "fluxion-csrf" body) 0))))
                         (when pos
                           (let ((start (+ pos 9)))
                             (subseq body start (position #\" body :start start)))))))
                 (when csrf-token
                   (timed (format nil "  ~:D concurrent POST /action/load-widget/bump"
                                  (* n-clients n-requests))
                     (join-all
                      (loop for i below n-clients
                            collect (bt:make-thread
                                     (lambda ()
                                       (dotimes (_ n-requests)
                                         (handler-case
                                             (dex:post (format nil "~A/action/load-widget/bump" base-url)
                                                       :cookie-jar cookie-jar
                                                       :headers `(("Content-Type" . "application/json")
                                                                  ("Accept" . "text/event-stream")
                                                                  ("X-CSRF-Token" . ,csrf-token))
                                                       :content "{}")
                                           (error ()
                                             (bt:with-lock-held (err-lock)
                                               (incf (car errors)))))))
                                     :name (format nil "post-~D" i)))))
                   (report "  POST errors: ~D / ~:D" (car errors) (* n-clients n-requests)))))))
      (stop-load-test-server))))

;;; -------------------------------------------------------
;;; Test 5: Memory stability
;;; -------------------------------------------------------

(defun test-memory-stability ()
  (report "=== Test 5: Memory Stability ===")
  (let ((before (gc-and-mem)))
    (report "  Before: ~,1F MB" before)

    ;; Churn: create and destroy lots of cells, sessions, events
    (dotimes (_ 10)
      (let ((cells nil)
            (app (server:make-fluxion-app :session-ttl 1)))
        ;; Create 1000 cells with watchers
        (dotimes (i 1000)
          (let ((c (cells:make-cell i)))
            (cells:watch c (lambda (n o) (declare (ignore n o))))
            (push c cells)))
        ;; Write to all cells
        (dolist (c cells)
          (setf (cells:cell-value c) (random 1000)))
        ;; Create 500 sessions with queues, then reap
        (dotimes (i 500)
          (let ((s (make-instance 'server:session :id (format nil "mem-~D" i))))
            (setf (fluxion.server::session-last-accessed-at s)
                  (- (get-universal-time) 100))
            (server:ensure-event-queue s)
            (bt:with-lock-held ((server:app-session-lock app))
              (setf (gethash (server:session-id s) (server:app-sessions app)) s))))
        (server:reap-sessions app)))

    (let ((after (gc-and-mem)))
      (report "  After 10 churn cycles (10K cells, 5K sessions each): ~,1F MB" after)
      (report "  Delta: ~,1F MB" (- after before))
      (if (< (- after before) 10.0)
          (report "  PASS: memory stable (< 10 MB growth)")
          (report "  WARN: ~,1F MB growth - investigate potential leak" (- after before))))))

;;; -------------------------------------------------------
;;; Main
;;; -------------------------------------------------------

(defun run-load-tests ()
  (format t "~%========================================~%")
  (format t " Fluxion Load Test~%")
  (format t "========================================~%~%")
  (let ((start-mem (gc-and-mem))
        (start-time (get-internal-real-time)))
    (report "Starting memory: ~,1F MB" start-mem)
    (terpri)

    (test-cell-throughput)
    (terpri)
    (test-session-scale)
    (terpri)
    (test-sse-push-throughput)
    (terpri)
    (test-http-stack)
    (terpri)
    (test-memory-stability)

    (let ((elapsed (/ (- (get-internal-real-time) start-time)
                      (float internal-time-units-per-second)))
          (end-mem (gc-and-mem)))
      (format t "~%========================================~%")
      (report "Total time: ~,1Fs" elapsed)
      (report "Final memory: ~,1F MB (delta ~,1F MB)" end-mem (- end-mem start-mem))
      (format t "========================================~%"))))

;; Run when loaded
(run-load-tests)
