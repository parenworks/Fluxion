;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Example - Temperature Converter
;;;;
;;;; Demonstrates bidirectional propagation:
;;;;   - Two cells (celsius, fahrenheit) connected by two propagators
;;;;   - Type in either field, the other updates automatically
;;;;   - CL's exact rational arithmetic means perfect convergence
;;;;   - No floating-point oscillation in the bidirectional loop
;;;;
;;;; Usage:
;;;;   (ql:quickload :fluxion/examples)
;;;;   (fluxion.examples.converter:start-converter)
;;;;   ;; Open http://localhost:5000

(defpackage #:fluxion.examples.converter
  (:use #:cl)
  (:export #:start-converter
           #:stop-converter))

(in-package #:fluxion.examples.converter)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defun parse-number (str)
  "Safely parse a number from STR. Returns NIL on failure."
  (when (and str (stringp str) (> (length str) 0))
    (let ((*read-eval* nil))
      (handler-case
          (let ((n (read-from-string str)))
            (when (numberp n) n))
        (error () nil)))))

(defun format-temp (n)
  "Format a temperature number for display."
  (if (integerp n)
      (format nil "~D" n)
      (format nil "~,1F" (float n))))

;;; -------------------------------------------------------
;;; Component
;;; -------------------------------------------------------

(defclass converter (fluxion.components:component)
  ((celsius-cell    :accessor converter-celsius-cell)
   (fahrenheit-cell :accessor converter-fahrenheit-cell)
   (c-to-f          :accessor converter-c-to-f)
   (f-to-c          :accessor converter-f-to-c))
  (:default-initargs :id "converter"))

(defmethod initialize-instance :after ((c converter) &key)
  (let ((celsius    (fluxion.cells:make-cell 0   :name "celsius"))
        (fahrenheit (fluxion.cells:make-cell 32  :name "fahrenheit")))
    (setf (converter-celsius-cell c) celsius)
    (setf (converter-fahrenheit-cell c) fahrenheit)
    ;; Bidirectional propagators
    (setf (converter-c-to-f c)
          (fluxion.cells:make-propagator
           :name "c-to-f"
           :inputs (list celsius)
           :fn (lambda (c) (+ (* c 9/5) 32))
           :outputs (list fahrenheit)))
    (setf (converter-f-to-c c)
          (fluxion.cells:make-propagator
           :name "f-to-c"
           :inputs (list fahrenheit)
           :fn (lambda (f) (* (- f 32) 5/9))
           :outputs (list celsius)))))

(defmethod fluxion.components:render ((c converter))
  (let ((celsius (fluxion.cells:cell-value (converter-celsius-cell c)))
        (fahrenheit (fluxion.cells:cell-value (converter-fahrenheit-cell c))))
    (spinneret:with-html-string
      (:div :id (fluxion.components:component-id c)
            :class "converter-component"
        (:h2 "Temperature Converter")
        (:p :class "subtitle" "Bidirectional propagation with exact rational arithmetic")
        (:div :class "converter-fields"
          (:div :class "field"
            (:label "Celsius")
            (:input :type "text"
                    :value (format-temp celsius)
                    :data-on-input "/action/converter/set-celsius"
                    :placeholder "Enter Celsius"))
          (:div :class "field-arrow"
            (:raw (format nil "&#8596;")))
          (:div :class "field"
            (:label "Fahrenheit")
            (:input :type "text"
                    :value (format-temp fahrenheit)
                    :data-on-input "/action/converter/set-fahrenheit"
                    :placeholder "Enter Fahrenheit")))
        (:p :class "result"
            (format nil "~A C = ~A F" (format-temp celsius) (format-temp fahrenheit)))
        (:div :class "presets"
          (:span "Presets: ")
          (:button :data-on-click "/action/converter/set-celsius"
                   :data-param-value "0"
                   "Freezing")
          (:button :data-on-click "/action/converter/set-celsius"
                   :data-param-value "100"
                   "Boiling")
          (:button :data-on-click "/action/converter/set-fahrenheit"
                   :data-param-value "98.6"
                   "Body temp"))))))

;;; -------------------------------------------------------
;;; Actions
;;; -------------------------------------------------------

(fluxion.components:defaction converter :set-celsius (c params)
  (let ((v (parse-number (cdr (assoc :value params)))))
    (when v
      (setf (fluxion.cells:cell-value (converter-celsius-cell c)) v)))
  nil)

(fluxion.components:defaction converter :set-fahrenheit (c params)
  (let ((v (parse-number (cdr (assoc :value params)))))
    (when v
      (setf (fluxion.cells:cell-value (converter-fahrenheit-cell c)) v)))
  nil)

;;; -------------------------------------------------------
;;; Page
;;; -------------------------------------------------------

(defun render-converter-page (converter)
  (fluxion.render:render-page
   :title "Fluxion Temperature Converter"
   :body-html
   (concatenate 'string
    "<style>
       body { font-family: system-ui, sans-serif; max-width: 600px; margin: 2rem auto; padding: 0 1rem;
              background: #1e1e2e; color: #cdd6f4; }
       .converter-component { border: 1px solid #45475a; border-radius: 8px; padding: 1.5rem;
                              background: #313244; }
       .subtitle { color: #a6adc8; margin-top: -0.5rem; }
       .converter-fields { display: flex; align-items: center; gap: 1rem; margin: 1.5rem 0; }
       .field { flex: 1; }
       .field label { display: block; font-weight: bold; margin-bottom: 0.3rem; color: #cdd6f4; }
       .field input { width: 100%; padding: 0.5rem; font-size: 1.2rem; border: 1px solid #585b70;
                      border-radius: 4px; box-sizing: border-box;
                      background: #1e1e2e; color: #cdd6f4; }
       .field input:focus { outline: none; border-color: #89b4fa; }
       .field-arrow { font-size: 1.5rem; color: #a6adc8; padding-top: 1.2rem; }
       .result { font-size: 1.2rem; font-weight: bold; color: #a6e3a1; }
       .presets { margin-top: 1rem; }
       .presets span { color: #a6adc8; }
       .presets button { padding: 0.4rem 0.8rem; border: 1px solid #585b70; border-radius: 4px;
                         background: #45475a; color: #cdd6f4; cursor: pointer; margin-left: 0.3rem; }
       .presets button:hover { background: #585b70; }
       h1 { color: #89b4fa; }
       h2 { color: #cdd6f4; }
       p { color: #bac2de; }
     </style>
     <h1>Fluxion</h1>
     <p>Propagator-inspired reactive dependency graph.</p>"
    (fluxion.components:render converter))))

;;; -------------------------------------------------------
;;; Application setup
;;; -------------------------------------------------------

(defvar *app* nil)

(defun start-converter (&key (port 5000))
  (when *app*
    (fluxion.server:stop *app*))

  (setf *app* (fluxion.server:make-fluxion-app
               :port port
               :static-dir (asdf:system-relative-pathname "fluxion" "static/")))

  (fluxion.server:register-component-factory *app* "converter"
    (lambda () (make-instance 'converter)))

  (fluxion.client:build-client)

  (fluxion.server:start *app*
    (lambda (app session env)
      (declare (ignore app env))
      (let ((converter (fluxion.server:session-component session "converter")))
        (list 200
              '(:content-type "text/html")
              (list (render-converter-page converter)))))
    :port port)

  (format t "~%Fluxion converter example running at http://localhost:~D~%" port)
  *app*)

(defun stop-converter ()
  (when *app*
    (fluxion.server:stop *app*)
    (setf *app* nil)
    (format t "Fluxion converter stopped.~%")))
