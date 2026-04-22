;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - CLOS component model

(in-package #:fluxion.components)

;;; -------------------------------------------------------
;;; Base component class
;;; -------------------------------------------------------
;;; All Fluxion components inherit from COMPONENT.  Each
;;; component has a unique ID (used as the DOM element ID)
;;; and an optional signal store for client-side state.

(defclass component ()
  ((id      :initarg :id
            :accessor component-id
            :type string
            :documentation "Unique identifier, used as the DOM element ID and CSS selector target.")
   (signals :initarg :signals
            :accessor component-signals
            :initform nil
            :documentation "Optional signal-store for this component's reactive state."))
  (:documentation "Base class for all Fluxion components."))

(defmethod initialize-instance :after ((c component) &key)
  (unless (slot-boundp c 'id)
    (setf (component-id c)
          (format nil "fluxion-~A" (string-downcase (symbol-name (type-of c)))))))

;;; -------------------------------------------------------
;;; Core generic functions
;;; -------------------------------------------------------

(defgeneric render (component)
  (:documentation
   "Render COMPONENT to an HTML string.  This is the primary method
application code must specialise.  Should return a string of HTML
with an element whose id matches (component-id component)."))

(defgeneric handle-action (component action params)
  (:documentation
   "Handle an incoming ACTION for COMPONENT.
ACTION is a keyword symbol identifying the action.
PARAMS is an alist of request parameters / signals.
Methods should mutate component state and return a list of SSE
events to send to the client, or use (patch component) as a
convenience."))

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defun component-selector (component)
  "Return the CSS selector string that targets COMPONENT's root element."
  (format nil "#~A" (component-id component)))
