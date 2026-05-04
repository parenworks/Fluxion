;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Example - Colour Picker
;;;;
;;;; Demonstrates bidirectional propagation with six cells:
;;;;   - R, G, B cells (0-255) connected to H, S, V cells (H: 0-360, S/V: 0-100)
;;;;   - Two propagators: RGB->HSV and HSV->RGB
;;;;   - Move any slider, all six values stay in sync
;;;;   - The colour swatch and hex code update live
;;;;   - data-debounce on sliders for input throttling
;;;;   - Router-based page serving
;;;;
;;;; This is the propagator network in action: changing R triggers RGB->HSV,
;;;; which updates H, S, V. Changing H triggers HSV->RGB, which updates R, G, B.
;;;; The re-entrance guard prevents infinite loops.
;;;;
;;;; Usage:
;;;;   (ql:quickload :fluxion/examples)
;;;;   (fluxion.examples.colour-picker:start-colour-picker)
;;;;   ;; Open http://localhost:5000

(defpackage #:fluxion.examples.colour-picker
  (:use #:cl #:fluxion)
  (:export #:start-colour-picker
           #:stop-colour-picker))

(in-package #:fluxion.examples.colour-picker)

;;; -------------------------------------------------------
;;; RGB <-> HSV conversion
;;; -------------------------------------------------------

(defun rgb->hsv (r g b)
  "Convert R G B (0-255) to (H S V) where H is 0-360, S and V are 0-100.
Returns a list (H S V)."
  (let* ((r1 (/ r 255.0))
         (g1 (/ g 255.0))
         (b1 (/ b 255.0))
         (cmax (max r1 g1 b1))
         (cmin (min r1 g1 b1))
         (delta (- cmax cmin)))
    (let ((h (cond
               ((zerop delta) 0)
               ((= cmax r1) (* 60 (mod (/ (- g1 b1) delta) 6)))
               ((= cmax g1) (* 60 (+ (/ (- b1 r1) delta) 2)))
               (t            (* 60 (+ (/ (- r1 g1) delta) 4)))))
          (s (if (zerop cmax) 0 (* 100 (/ delta cmax))))
          (v (* 100 cmax)))
      (list (round (mod h 360)) (round s) (round v)))))

(defun hsv->rgb (h s v)
  "Convert H (0-360) S (0-100) V (0-100) to (R G B) each 0-255.
Returns a list (R G B)."
  (let* ((s1 (/ s 100.0))
         (v1 (/ v 100.0))
         (c (* v1 s1))
         (x (* c (- 1 (abs (- (mod (/ h 60.0) 2) 1)))))
         (m (- v1 c)))
    (multiple-value-bind (r1 g1 b1)
        (cond
          ((< h  60) (values c x 0))
          ((< h 120) (values x c 0))
          ((< h 180) (values 0 c x))
          ((< h 240) (values 0 x c))
          ((< h 300) (values x 0 c))
          (t         (values c 0 x)))
      (list (round (* (+ r1 m) 255))
            (round (* (+ g1 m) 255))
            (round (* (+ b1 m) 255))))))

;;; -------------------------------------------------------
;;; Component
;;; -------------------------------------------------------

(defclass colour-picker (component)
  ((r-cell :accessor picker-r-cell)
   (g-cell :accessor picker-g-cell)
   (b-cell :accessor picker-b-cell)
   (h-cell :accessor picker-h-cell)
   (s-cell :accessor picker-s-cell)
   (v-cell :accessor picker-v-cell)
   (rgb->hsv-prop :accessor picker-rgb->hsv)
   (hsv->rgb-prop :accessor picker-hsv->rgb))
  (:default-initargs :id "colour-picker"))

(defmethod initialize-instance :after ((cp colour-picker) &key)
  ;; Compute consistent initial values so propagators converge on first fire.
  (destructuring-bind (init-h init-s init-v) (rgb->hsv 66 135 245)
    (let ((r (make-cell 66  :name "r"))
          (g (make-cell 135 :name "g"))
          (b (make-cell 245 :name "b"))
          (h (make-cell init-h :name "h"))
          (s (make-cell init-s :name "s"))
          (v (make-cell init-v :name "v")))
      (setf (picker-r-cell cp) r  (picker-g-cell cp) g  (picker-b-cell cp) b
            (picker-h-cell cp) h  (picker-s-cell cp) s  (picker-v-cell cp) v)
      ;; Bidirectional propagators: changing any RGB slider updates HSV
      ;; and vice versa. Re-entrance guards in fire-propagator prevent
      ;; infinite loops; consistent initial values prevent oscillation.
      (setf (picker-rgb->hsv cp)
            (make-propagator
             :name "rgb->hsv"
             :inputs (list r g b)
             :fn #'rgb->hsv
             :outputs (list h s v)))
      (setf (picker-hsv->rgb cp)
            (make-propagator
             :name "hsv->rgb"
             :inputs (list h s v)
             :fn #'hsv->rgb
             :outputs (list r g b))))))

(defun hex-colour (r g b)
  "Return a CSS hex colour string."
  (format nil "#~2,'0X~2,'0X~2,'0X" (min 255 (max 0 r))
          (min 255 (max 0 g)) (min 255 (max 0 b))))

(defun slider (label value action min max &optional colour)
  "Render a range slider row."
  (spinneret:with-html-string
    (:div :class "slider-row"
      (:label (:span :class "slider-label" label)
              (:span :class "slider-value"
                     :style (when colour (format nil "color:~A" colour))
                     (format nil "~D" value)))
      (:input :type "range"
              :min (format nil "~D" min)
              :max (format nil "~D" max)
              :value (format nil "~D" value)
              :class (or colour "")
              :data-on-input action
              :data-debounce "5"))))

(defmethod render ((cp colour-picker))
  (let* ((r (cell-value (picker-r-cell cp)))
         (g (cell-value (picker-g-cell cp)))
         (b (cell-value (picker-b-cell cp)))
         (h (cell-value (picker-h-cell cp)))
         (s (cell-value (picker-s-cell cp)))
         (v (cell-value (picker-v-cell cp)))
         (hex (hex-colour r g b)))
    (spinneret:with-html-string
      (:div :id (component-id cp)
            :class "colour-picker"
        ;; Swatch
        (:div :class "swatch"
          (:div :class "swatch-colour"
                :style (format nil "background-color:~A" hex))
          (:div :class "swatch-hex" hex))
        ;; Sliders
        (:div :class "slider-columns"
          (:div :class "slider-group"
            (:h3 "RGB")
            (:raw (slider "R" r "/action/colour-picker/set-r" 0 255 "#f38ba8"))
            (:raw (slider "G" g "/action/colour-picker/set-g" 0 255 "#a6e3a1"))
            (:raw (slider "B" b "/action/colour-picker/set-b" 0 255 "#89b4fa")))
          (:div :class "slider-group"
            (:h3 "HSV")
            (:raw (slider "H" h "/action/colour-picker/set-h" 0 360))
            (:raw (slider "S" s "/action/colour-picker/set-s" 0 100))
            (:raw (slider "V" v "/action/colour-picker/set-v" 0 100))))))))

;;; -------------------------------------------------------
;;; Actions
;;; -------------------------------------------------------

(defun clamp (val lo hi)
  (min hi (max lo val)))

(defmacro def-slider-action (name cell-accessor lo hi)
  `(defaction colour-picker ,name (cp params)
     (let ((v (parse-integer (cdr (assoc :value params)) :junk-allowed t)))
       (when v
         (setf (cell-value (,cell-accessor cp))
               (clamp v ,lo ,hi))))
     nil))

(def-slider-action :set-r picker-r-cell 0 255)
(def-slider-action :set-g picker-g-cell 0 255)
(def-slider-action :set-b picker-b-cell 0 255)
(def-slider-action :set-h picker-h-cell 0 360)
(def-slider-action :set-s picker-s-cell 0 100)
(def-slider-action :set-v picker-v-cell 0 100)

;;; -------------------------------------------------------
;;; Page
;;; -------------------------------------------------------

(defun render-colour-page (picker &key csrf-token)
  (render-page
   :title "Fluxion Colour Picker"
   :csrf-token csrf-token
   :body-html
   (concatenate 'string
    "<style>
       body { font-family: system-ui, sans-serif; max-width: 700px; margin: 2rem auto; padding: 0 1rem;
              background: #1e1e2e; color: #cdd6f4; }
       h1 { color: #89b4fa; margin-bottom: 0.25rem; }
       h1 + p { color: #a6adc8; margin-top: 0; }
       h3 { color: #cdd6f4; margin-bottom: 0.5rem; }
       .colour-picker { border: 1px solid #45475a; border-radius: 8px; padding: 1.5rem;
                         background: #313244; }
       .swatch { text-align: center; margin-bottom: 1.5rem; }
       .swatch-colour { width: 100%; height: 160px; border-radius: 6px;
                         border: 2px solid #45475a; }
       .swatch-hex { font-family: 'JetBrains Mono', monospace; font-size: 1.6rem;
                      margin-top: 0.5rem; color: #cdd6f4; letter-spacing: 0.1em; }
       .slider-columns { display: flex; gap: 2rem; }
       .slider-group { flex: 1; }
       .slider-row { margin-bottom: 0.75rem; }
       .slider-row label { display: flex; justify-content: space-between; margin-bottom: 0.2rem; }
       .slider-label { font-weight: bold; color: #a6adc8; }
       .slider-value { font-family: 'JetBrains Mono', monospace; min-width: 2.5em; text-align: right; }
       input[type=range] { width: 100%; accent-color: #89b4fa; cursor: pointer;
                           height: 6px; -webkit-appearance: none; appearance: none;
                           background: #45475a; border-radius: 3px; outline: none; }
       input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; appearance: none;
                           width: 18px; height: 18px; border-radius: 50%;
                           background: #cdd6f4; border: 2px solid #313244; cursor: pointer; }
     </style>
     <h1>Fluxion</h1>
     <p>Bidirectional propagation: RGB and HSV stay in sync.</p>"
    (render picker))))

;;; -------------------------------------------------------
;;; Application setup (router-based)
;;; -------------------------------------------------------

(defvar *app* nil)
(defvar *router* (make-router))

(defroute *router* :get "/" (app session env &key params)
  (declare (ignore app env params))
  (let ((picker (session-component session "colour-picker")))
    (list 200
          '(:content-type "text/html")
          (list (render-colour-page picker
                 :csrf-token (session-csrf-token session))))))

(defun start-colour-picker (&key (port 5000) (server :woo))
  (when *app*
    (stop *app*))

  (setf *app* (make-fluxion-app
               :port port
               :server server
               :static-dir (asdf:system-relative-pathname "fluxion" "static/")))

  (register-component-factory *app* "colour-picker"
    (lambda () (make-instance 'colour-picker)))

  (fluxion.client:build-client)

  (start *app* (router-handler *router*) :port port)

  (format t "~%Fluxion colour picker running at http://localhost:~D~%" port)
  *app*)

(defun stop-colour-picker ()
  (when *app*
    (stop *app*)
    (setf *app* nil)
    (format t "Fluxion colour picker stopped.~%")))
