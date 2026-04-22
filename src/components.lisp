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
            :documentation "Optional signal-store for this component's reactive state.")
   (dirty-p :initform t
            :accessor component-dirty-p
            :type boolean
            :documentation "Whether this component needs re-rendering.")
   (last-html :initform nil
              :accessor component-last-html
              :documentation "Cached HTML from the last render, used for dirty comparison."))
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

(defun mark-dirty (component)
  "Mark COMPONENT as needing re-rendering."
  (setf (component-dirty-p component) t)
  component)

(defun clear-dirty (component)
  "Clear the dirty flag on COMPONENT."
  (setf (component-dirty-p component) nil)
  component)

;;; -------------------------------------------------------
;;; defaction macro
;;; -------------------------------------------------------

(defmacro defaction (component-class action-name (component-var &optional (params-var (gensym "PARAMS"))) &body body)
  "Define an action handler for COMPONENT-CLASS.
ACTION-NAME is a keyword symbol (e.g. :increment).
COMPONENT-VAR is bound to the component instance.
PARAMS-VAR is bound to the request params alist.
BODY should mutate state and return a list of SSE events.
If BODY returns NIL, a default patch of the component is sent."
  `(defmethod handle-action ((,component-var ,component-class)
                             (action (eql ,action-name))
                             ,params-var)
     (declare (ignorable ,params-var))
     (mark-dirty ,component-var)
     (let ((result (progn ,@body)))
       (or result
           (patch-component ,component-var)))))

(defun patch-component (component &key (mode "morph") force)
  "Return a list containing a single patch event for COMPONENT.
Re-renders the component and targets its DOM selector.
If the rendered HTML is identical to the cached version and FORCE
is NIL, returns an empty list (no patch sent)."
  (let ((new-html (render component)))
    (cond
      ((and (not force)
            (not (component-dirty-p component))
            (component-last-html component)
            (string= new-html (component-last-html component)))
       '())
      (t
       (setf (component-last-html component) new-html)
       (clear-dirty component)
       (list (fluxion.events:make-patch-event
              (component-selector component)
              new-html
              :mode mode))))))
