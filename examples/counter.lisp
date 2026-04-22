;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Example - Counter
;;;;
;;;; The "hello world" of Fluxion.  Demonstrates:
;;;;   - Defining a CLOS component
;;;;   - Rendering with Spinneret
;;;;   - Reactive cells (auto-patching on state change)
;;;;   - Computed cells (auto-derived values)
;;;;   - Handling actions via defaction
;;;;
;;;; Usage:
;;;;   (ql:quickload :fluxion/examples)
;;;;   (fluxion.examples.counter:start-counter)
;;;;   ;; Open http://localhost:5000

(defpackage #:fluxion.examples.counter
  (:use #:cl)
  (:export #:start-counter
           #:stop-counter))

(in-package #:fluxion.examples.counter)

;;; -------------------------------------------------------
;;; Component
;;; -------------------------------------------------------

(defclass counter (fluxion.components:component)
  ((count :accessor counter-count-cell
          :documentation "A reactive cell holding the count value.")
   (label :accessor counter-label-cell
          :documentation "A computed cell deriving a display label from count."))
  (:default-initargs :id "counter"))

(defmethod initialize-instance :after ((c counter) &key)
  (setf (counter-count-cell c) (fluxion.cells:make-cell 0 :name "count"))
  ;; Computed cell: derives a label from the count, auto-tracks dependency
  (setf (counter-label-cell c)
        (fluxion.cells:make-computed
         (let ((cell (counter-count-cell c)))
           (lambda ()
             (let ((n (fluxion.cells:cell-value cell)))
               (format nil "Count: ~D~A" n
                       (cond ((zerop n) " (zero)")
                             ((plusp n) " (positive)")
                             (t         " (negative)"))))))
         :name "label"))
  ;; Connect the computed label to the component - changes auto-patch
  (fluxion.cells:connect (counter-label-cell c) c))

(defun counter-count (counter)
  "Read the counter's current count."
  (fluxion.cells:cell-value (counter-count-cell counter)))

(defun (setf counter-count) (value counter)
  "Set the counter's count. Triggers auto-patch via the cell."
  (setf (fluxion.cells:cell-value (counter-count-cell counter)) value))

(defun counter-label (counter)
  "Read the derived label (computed from count)."
  (fluxion.cells:cell-value (counter-label-cell counter)))

(defmethod fluxion.components:render ((c counter))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id c)
          :class "counter-component"
      (:h2 "Counter")
      (:p :class "count-display"
          (counter-label c))
      (:div :class "counter-buttons"
        (:button :data-on-click "/action/counter/increment" "Increment")
        (:button :data-on-click "/action/counter/decrement" "Decrement")
        (:button :data-on-click "/action/counter/reset"     "Reset")))))

;;; -------------------------------------------------------
;;; Actions (via defaction - CLOS dispatch)
;;; -------------------------------------------------------

;; Actions just modify the cell - the connected watcher handles patching.
;; Return :no-patch to suppress defaction's default patch (the cell handles it).

(fluxion.components:defaction counter :increment (c)
  (incf (counter-count c))
  '())

(fluxion.components:defaction counter :decrement (c)
  (decf (counter-count c))
  '())

(fluxion.components:defaction counter :reset (c)
  (setf (counter-count c) 0)
  '())

;;; -------------------------------------------------------
;;; Page
;;; -------------------------------------------------------

(defun render-counter-page (counter)
  (fluxion.render:render-page
   :title "Fluxion Counter Example"
   :body-html
   (concatenate 'string
    "<style>
       body { font-family: system-ui, sans-serif; max-width: 600px; margin: 2rem auto; padding: 0 1rem; }
       .counter-component { border: 1px solid #ddd; border-radius: 8px; padding: 1.5rem; }
       .count-display { font-size: 2rem; font-weight: bold; }
       .counter-buttons { display: flex; gap: 0.5rem; }
       button { padding: 0.5rem 1rem; border: 1px solid #999; border-radius: 4px;
                background: #f5f5f5; cursor: pointer; font-size: 1rem; }
       button:hover { background: #e0e0e0; }
       h1 { color: #333; }
     </style>
     <h1>Fluxion</h1>
     <p>Live server-rendered interfaces for Common Lisp.</p>"
    (fluxion.components:render counter))))

;;; -------------------------------------------------------
;;; Application setup
;;; -------------------------------------------------------

(defvar *app* nil)

(defun start-counter (&key (port 5000))
  (when *app*
    (fluxion.server:stop *app*))

  (setf *app* (fluxion.server:make-fluxion-app
               :port port
               :static-dir (asdf:system-relative-pathname "fluxion" "static/")))

  ;; Register a factory so each session gets its own counter instance
  (fluxion.server:register-component-factory *app* "counter"
    (lambda () (make-instance 'counter)))

  ;; Build the client runtime JS
  (fluxion.client:build-client)

  ;; Start the server - page-handler now receives (app session env)
  (fluxion.server:start *app*
    (lambda (app session env)
      (declare (ignore app env))
      (let ((counter (fluxion.server:session-component session "counter")))
        (list 200
              '(:content-type "text/html")
              (list (render-counter-page counter)))))
    :port port)

  (format t "~%Fluxion counter example running at http://localhost:~D~%" port)
  *app*)

(defun stop-counter ()
  (when *app*
    (fluxion.server:stop *app*)
    (setf *app* nil)
    (format t "Fluxion counter stopped.~%")))
