;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Example - Counter
;;;;
;;;; The "hello world" of Fluxion.  Demonstrates:
;;;;   - defcomponent macro (one-form component definition)
;;;;   - Cell-backed slots with auto-patching
;;;;   - Handling actions via defaction
;;;;   - Server-push via persistent SSE (live clock)
;;;;   - Router-based page serving
;;;;   - data-disable-during-request for click deduplication
;;;;
;;;; Usage:
;;;;   (ql:quickload :fluxion/examples)
;;;;   (fluxion.examples.counter:start-counter)
;;;;   ;; Open http://localhost:5000

(defpackage #:fluxion.examples.counter
  (:use #:cl #:fluxion)
  (:export #:start-counter
           #:stop-counter))

(in-package #:fluxion.examples.counter)

;;; -------------------------------------------------------
;;; Component (defined with defcomponent macro)
;;; -------------------------------------------------------
;;; The :cell t option makes the count slot cell-backed.
;;; defcomponent generates the class, the cell setup, the
;;; accessor functions, and the render method in one form.

(defcomponent counter
  :id "counter"
  :slots ((count :cell t :initform 0 :accessor counter-count))
  :render (let ((n (counter-count self)))
            (spinneret:with-html-string
              (:div :id (component-id self)
                    :class "counter-component"
                (:h2 "Counter")
                (:p :class "count-display"
                    (format nil "Count: ~D~A" n
                            (cond ((zerop n) " (zero)")
                                  ((plusp n) " (positive)")
                                  (t         " (negative)"))))
                (:div :class "counter-buttons"
                  (:button :data-on-click "/action/counter/increment"
                           :data-disable-during-request t
                           "Increment")
                  (:button :data-on-click "/action/counter/decrement"
                           :data-disable-during-request t
                           "Decrement")
                  (:button :data-on-click "/action/counter/reset"
                           :data-disable-during-request t
                           "Reset"))))))

;;; -------------------------------------------------------
;;; Actions (via defaction - CLOS dispatch)
;;; -------------------------------------------------------

;; Actions just modify the cell - the connected watcher handles patching.
;; Return :no-patch to suppress defaction's default patch (the cell handles it).

(defaction counter :increment (c)
  (incf (counter-count c))
  '())

(defaction counter :decrement (c)
  (decf (counter-count c))
  '())

(defaction counter :reset (c)
  (setf (counter-count c) 0)
  '())

;;; -------------------------------------------------------
;;; Live clock (server-push demo)
;;; -------------------------------------------------------
;;; This component is updated by a background thread that
;;; pushes the server time to all sessions every second.
;;; No user interaction triggers these updates.

(defcomponent server-clock
  :id "server-clock"
  :slots ((time-str :cell t :initform "" :accessor clock-time))
  :render (spinneret:with-html-string
            (:div :id (component-id self)
                  :class "clock-component"
              (:span :class "clock-label" "Server time: ")
              (:span :class "clock-value" (clock-time self)))))

(defvar *clock-thread* nil)
(defvar *clock-stop-flag* nil)

(defun stop-clock-ticker ()
  "Signal the clock ticker to stop and wait for it to finish."
  (setf *clock-stop-flag* t)
  (when (and *clock-thread* (bordeaux-threads:thread-alive-p *clock-thread*))
    (bordeaux-threads:join-thread *clock-thread*))
  (setf *clock-thread* nil))

(defun start-clock-ticker (app)
  "Start a background thread that pushes server time to all sessions every second."
  (stop-clock-ticker)
  (setf *clock-stop-flag* nil)
  (setf *clock-thread*
        (bordeaux-threads:make-thread
         (lambda ()
           (loop
             (sleep 1)
             (when (or *clock-stop-flag*
                       (null (app-handler app)))
               (return))
             (handler-case
                 (let ((now (multiple-value-bind (s min h) (get-decoded-time)
                              (format nil "~2,'0D:~2,'0D:~2,'0D" h min s))))
                   ;; Push to all sessions
                   (bordeaux-threads:with-lock-held ((app-session-lock app))
                     (maphash (lambda (sid session)
                                (declare (ignore sid))
                                (let ((clock (session-component session "server-clock")))
                                  (when clock
                                    (setf (clock-time clock) now)
                                    (push-component-patch session clock))))
                              (app-sessions app))))
               (error () nil))))
         :name "fluxion-clock-ticker")))

;;; -------------------------------------------------------
;;; Page
;;; -------------------------------------------------------

(defun render-counter-page (counter clock &key csrf-token)
  (render-page
   :title "Fluxion Counter Example"
   :csrf-token csrf-token
   :body-html
   (concatenate 'string
    "<style>
       body { font-family: system-ui, sans-serif; max-width: 600px; margin: 2rem auto; padding: 0 1rem;
              background: #1e1e2e; color: #cdd6f4; }
       .counter-component { border: 1px solid #45475a; border-radius: 8px; padding: 1.5rem;
                            background: #313244; }
       .count-display { font-size: 2rem; font-weight: bold; color: #cdd6f4; }
       .counter-buttons { display: flex; gap: 0.5rem; }
       button { padding: 0.5rem 1rem; border: 1px solid #585b70; border-radius: 4px;
                background: #45475a; color: #cdd6f4; cursor: pointer; font-size: 1rem; }
       button:hover { background: #585b70; }
       button:disabled { opacity: 0.5; cursor: not-allowed; }
       h1 { color: #89b4fa; }
       p { color: #bac2de; }
       .clock-component { margin-top: 1rem; padding: 0.75rem 1rem; border: 1px solid #45475a;
                          border-radius: 8px; background: #313244; }
       .clock-label { color: #a6adc8; }
       .clock-value { color: #a6e3a1; font-weight: bold; font-family: monospace; font-size: 1.1rem; }
     </style>
     <h1>Fluxion</h1>
     <p>Live server-rendered interfaces for Common Lisp.</p>"
    (render counter)
    (render clock))))

;;; -------------------------------------------------------
;;; Application setup (router-based)
;;; -------------------------------------------------------

(defvar *app* nil)
(defvar *router* (make-router))

(defroute *router* :get "/" (app session env &key params)
  (declare (ignore app env params))
  (let ((counter (session-component session "counter"))
        (clock   (session-component session "server-clock")))
    (list 200
          '(:content-type "text/html")
          (list (render-counter-page counter clock
                 :csrf-token (session-csrf-token session))))))

(defun start-counter (&key (port 5000))
  (when *app*
    (stop *app*))

  (setf *app* (make-fluxion-app
               :port port
               :static-dir (asdf:system-relative-pathname "fluxion" "static/")))

  ;; Register factories so each session gets its own instances
  (register-component-factory *app* "counter"
    (lambda () (make-instance 'counter)))
  (register-component-factory *app* "server-clock"
    (lambda () (make-instance 'server-clock)))

  ;; Build the client runtime JS
  (fluxion.client:build-client)

  ;; Start the server with the router
  (start *app* (router-handler *router*) :port port)

  ;; Start the background clock ticker (server-push demo)
  (start-clock-ticker *app*)

  (format t "~%Fluxion counter example running at http://localhost:~D~%" port)
  *app*)

(defun stop-counter ()
  (stop-clock-ticker)
  (when *app*
    (stop *app*)
    (setf *app* nil)
    (format t "Fluxion counter stopped.~%")))
