;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - CLOS component model

(in-package #:fluxion.components)

;;; -------------------------------------------------------
;;; Base component class
;;; -------------------------------------------------------
;;; All Fluxion components inherit from COMPONENT.  Each
;;; component has a unique ID (used as the DOM element ID)
;;; and an optional signal store for client-side state.

(defgeneric component-id (component)
  (:documentation "Unique identifier string, used as the DOM element ID and CSS selector target."))

(defgeneric component-signals (component)
  (:documentation "Optional signal-store for this component's client-side reactive state."))

(defgeneric component-dirty-p (component)
  (:documentation "Whether this component needs re-rendering. Set by mark-dirty, cleared by patch-component."))

(defgeneric component-last-html (component)
  (:documentation "Cached HTML from the last render. Used for dirty comparison to avoid sending no-op patches."))

(defgeneric component-parent (component)
  (:documentation "The parent component, or NIL if this is a top-level component."))

(defgeneric component-children (component)
  (:documentation "List of child components nested inside this component."))

(defgeneric component-session (component)
  (:documentation "Back-pointer to the session that owns this component. Set automatically during session creation."))

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
              :documentation "Cached HTML from the last render, used for dirty comparison.")
   (parent  :initform nil
            :accessor component-parent
            :documentation "Parent component, or NIL for top-level components.")
   (children :initform nil
             :accessor component-children
             :documentation "List of child components nested inside this component.")
   (session-ref :initform nil
                :accessor component-session
                :documentation "Back-pointer to the owning session. Set during session creation."))
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
;;; Lifecycle callbacks
;;; -------------------------------------------------------

(defgeneric component-mounted (component session)
  (:documentation "Called when COMPONENT is first created for a SESSION.
This happens during session creation when component factories run.
Override to perform per-session initialisation (start timers, open
resources, set initial state based on session context).
Default method does nothing."))

(defmethod component-mounted ((c component) session)
  (declare (ignore c session))
  nil)

(defgeneric component-unmounted (component session)
  (:documentation "Called when SESSION is being reaped and COMPONENT will be discarded.
Override to perform cleanup (cancel timers, close connections, release
resources). Called inside the session lock during reaping.
Default method does nothing."))

(defmethod component-unmounted ((c component) session)
  (declare (ignore c session))
  nil)

(defgeneric component-connected (component session)
  (:documentation "Called when the SSE stream is established for SESSION.
This fires each time the browser opens (or re-opens) the EventSource
connection. Override to push initial state or start session-specific
background work.
Default method does nothing."))

(defmethod component-connected ((c component) session)
  (declare (ignore c session))
  nil)

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
;;; Composition helpers
;;; -------------------------------------------------------

(defgeneric add-child (parent child)
  (:documentation "Add CHILD as a nested child of PARENT.
Sets the child's parent back-pointer and propagates the session reference.
If CHILD was previously parented elsewhere, it is removed from the old parent first."))

(defmethod add-child ((parent component) (child component))
  (when (component-parent child)
    (remove-child (component-parent child) child))
  (setf (component-parent child) parent)
  (pushnew child (component-children parent) :test #'eq)
  ;; Propagate session reference
  (when (component-session parent)
    (propagate-session child (component-session parent)))
  child)

(defgeneric remove-child (parent child)
  (:documentation "Remove CHILD from PARENT's children list.
Clears the child's parent back-pointer."))

(defmethod remove-child ((parent component) (child component))
  (setf (component-children parent)
        (remove child (component-children parent) :test #'eq))
  (setf (component-parent child) nil)
  child)

(defun propagate-session (component session)
  "Set the session reference on COMPONENT and all its descendants."
  (setf (component-session component) session)
  (dolist (child (component-children component))
    (propagate-session child session)))

(defgeneric component-root (component)
  (:documentation "Walk up the parent chain to find the root (top-level) component."))

(defmethod component-root ((c component))
  (if (component-parent c)
      (component-root (component-parent c))
      c))

(defgeneric find-child (component id)
  (:documentation "Find a descendant component by ID. Searches breadth-first."))

(defmethod find-child ((c component) (id string))
  (labels ((search-children (comp)
             (dolist (child (component-children comp))
               (when (string= (component-id child) id)
                 (return-from find-child child))
               (search-children child))))
    (search-children c)))

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

;;; -------------------------------------------------------
;;; defcomponent macro
;;; -------------------------------------------------------

(defmacro defcomponent (name &key id slots render)
  "Define a Fluxion component in a single form.

NAME is the class name.
ID is the component DOM id (string). Defaults to the downcased name.
SLOTS is a list of slot specs. Each spec is (slot-name &key cell initform accessor test).
  When :cell is T, the slot is backed by a reactive cell and automatically
  connected to the component. The accessor reads/writes through cell-value.
RENDER is a body form that returns an HTML string. Inside the body, SELF
  is bound to the component instance.

Example:
  (defcomponent counter
    :id \"counter\"
    :slots ((count :cell t :initform 0 :accessor counter-count))
    :render (spinneret:with-html-string
              (:div :id (component-id self)
                (:p (format nil \"Count: ~D\" (counter-count self))))))"
  (let* ((self-gensym (gensym "SELF-"))
         (self-sym (intern "SELF" *package*))
         (id-form (or id (string-downcase (symbol-name name))))
         (cell-slots (remove-if-not (lambda (s) (getf (cdr s) :cell)) slots))
         (plain-slots (remove-if (lambda (s) (getf (cdr s) :cell)) slots))
         ;; Build CLOS slot definitions
         (clos-slots
           (append
            ;; Plain slots -> normal CLOS slots
            (mapcar (lambda (s)
                      (let* ((sname (car s))
                             (props (cdr s))
                             (has-initform (not (eq (getf props :initform :no-initform) :no-initform)))
                             (initform (getf props :initform))
                             (accessor (getf props :accessor)))
                        `(,sname
                          ,@(when has-initform `(:initform ,initform))
                          ,@(when accessor `(:accessor ,accessor)))))
                    plain-slots)
            ;; Cell slots -> internal cell-holder slot
            (mapcar (lambda (s)
                      (let ((sname (car s)))
                        `(,(intern (format nil "~A-CELL%" sname))
                          :accessor ,(intern (format nil "~A-CELL%" sname)))))
                    cell-slots)))
         ;; Build init-after body for cell setup
         (cell-inits
           (mapcar (lambda (s)
                     (let ((sname (car s))
                           (initform (or (getf (cdr s) :initform) nil))
                           (test (getf (cdr s) :test)))
                       `(progn
                          (setf (,(intern (format nil "~A-CELL%" sname)) c)
                                (fluxion.cells:make-cell
                                 ,initform
                                 :name ,(string-downcase (symbol-name sname))
                                 ,@(when test `(:test ,test))))
                          (fluxion.cells:connect
                           (,(intern (format nil "~A-CELL%" sname)) c) c))))
                   cell-slots))
         ;; Build accessor functions for cell slots
         (cell-accessors
           (mapcan (lambda (s)
                     (let ((sname (car s))
                           (accessor (getf (cdr s) :accessor)))
                       (when accessor
                         (list
                          `(defun ,accessor (component)
                             ,(format nil "Read the ~A cell value." sname)
                             (fluxion.cells:cell-value
                              (,(intern (format nil "~A-CELL%" sname)) component)))
                          `(defun (setf ,accessor) (value component)
                             ,(format nil "Set the ~A cell value. Triggers watchers." sname)
                             (setf (fluxion.cells:cell-value
                                    (,(intern (format nil "~A-CELL%" sname)) component))
                                   value))))))
                   cell-slots)))
    `(progn
       (defclass ,name (component)
         ,clos-slots
         (:default-initargs :id ,id-form))

       ,@(when cell-inits
           `((defmethod initialize-instance :after ((c ,name) &key)
               ,@cell-inits)))

       ,@cell-accessors

       ,@(when render
           `((defmethod render ((,self-gensym ,name))
               (symbol-macrolet ((,self-sym ,self-gensym))
                 ,render)))))))

(defgeneric patch-component (component &key mode force)
  (:documentation "Return a list containing a single patch event for COMPONENT.
Re-renders the component and targets its DOM selector.
If the rendered HTML is identical to the cached version and FORCE
is NIL, returns an empty list (no patch sent)."))

(defmethod patch-component ((component component) &key (mode "morph") force)
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
