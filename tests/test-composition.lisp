;;;; -*- encoding:utf-8 -*-
;;;; Tests for component composition/nesting

(in-package #:fluxion.tests)

(def-suite composition-suite
  :description "Component composition and nesting."
  :in fluxion-suite)

(in-suite composition-suite)

;;; -------------------------------------------------------
;;; Test component classes
;;; -------------------------------------------------------

(defclass shell-component (fluxion.components:component)
  ((content :initform nil :accessor shell-content))
  (:default-initargs :id "shell"))

(defmethod fluxion.components:render ((c shell-component))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id c)
      (:nav "sidebar")
      (when (shell-content c)
        (:raw (fluxion.components:render (shell-content c)))))))

(defclass page-component (fluxion.components:component)
  ((title :initarg :title :initform "Page" :accessor page-title))
  (:default-initargs :id "page"))

(defmethod fluxion.components:render ((c page-component))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id c)
      (:h1 (page-title c)))))

(defclass widget-a (fluxion.components:component)
  ()
  (:default-initargs :id "widget-a"))

(defmethod fluxion.components:render ((c widget-a))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id c) "Widget A")))

(defclass widget-b (fluxion.components:component)
  ()
  (:default-initargs :id "widget-b"))

(defmethod fluxion.components:render ((c widget-b))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id c) "Widget B")))

;;; -------------------------------------------------------
;;; add-child / remove-child basics
;;; -------------------------------------------------------

(test composition-add-child
  "add-child sets parent and children correctly."
  (let ((parent (make-instance 'shell-component))
        (child (make-instance 'page-component)))
    (fluxion.components:add-child parent child)
    (is (eq parent (fluxion.components:component-parent child)))
    (is (member child (fluxion.components:component-children parent) :test #'eq))))

(test composition-remove-child
  "remove-child clears the relationship."
  (let ((parent (make-instance 'shell-component))
        (child (make-instance 'page-component)))
    (fluxion.components:add-child parent child)
    (fluxion.components:remove-child parent child)
    (is (null (fluxion.components:component-parent child)))
    (is (null (fluxion.components:component-children parent)))))

(test composition-reparent
  "Adding a child that already has a parent moves it."
  (let ((p1 (make-instance 'shell-component))
        (p2 (make-instance 'shell-component :id "shell-2"))
        (child (make-instance 'page-component)))
    (fluxion.components:add-child p1 child)
    (fluxion.components:add-child p2 child)
    (is (eq p2 (fluxion.components:component-parent child)))
    (is (null (fluxion.components:component-children p1)))
    (is (member child (fluxion.components:component-children p2) :test #'eq))))

(test composition-multiple-children
  "A parent can have multiple children."
  (let ((parent (make-instance 'shell-component))
        (a (make-instance 'widget-a))
        (b (make-instance 'widget-b)))
    (fluxion.components:add-child parent a)
    (fluxion.components:add-child parent b)
    (is (= 2 (length (fluxion.components:component-children parent))))
    (is (eq parent (fluxion.components:component-parent a)))
    (is (eq parent (fluxion.components:component-parent b)))))

(test composition-idempotent-add
  "Adding the same child twice does not duplicate."
  (let ((parent (make-instance 'shell-component))
        (child (make-instance 'page-component)))
    (fluxion.components:add-child parent child)
    (fluxion.components:add-child parent child)
    (is (= 1 (length (fluxion.components:component-children parent))))))

;;; -------------------------------------------------------
;;; component-root
;;; -------------------------------------------------------

(test composition-root
  "component-root walks up to the top-level component."
  (let ((root (make-instance 'shell-component))
        (mid (make-instance 'page-component))
        (leaf (make-instance 'widget-a)))
    (fluxion.components:add-child root mid)
    (fluxion.components:add-child mid leaf)
    (is (eq root (fluxion.components:component-root leaf)))
    (is (eq root (fluxion.components:component-root mid)))
    (is (eq root (fluxion.components:component-root root)))))

;;; -------------------------------------------------------
;;; find-child
;;; -------------------------------------------------------

(test composition-find-child
  "find-child locates a descendant by ID."
  (let ((root (make-instance 'shell-component))
        (mid (make-instance 'page-component))
        (leaf (make-instance 'widget-a)))
    (fluxion.components:add-child root mid)
    (fluxion.components:add-child mid leaf)
    (is (eq leaf (fluxion.components:find-child root "widget-a")))
    (is (eq mid (fluxion.components:find-child root "page")))
    (is (null (fluxion.components:find-child root "nonexistent")))))

;;; -------------------------------------------------------
;;; Session back-pointer propagation
;;; -------------------------------------------------------

(test composition-session-propagation
  "Session reference propagates to children when parent has a session."
  (let ((parent (make-instance 'shell-component))
        (child (make-instance 'page-component))
        (session (make-instance 'fluxion.server:session :id "test-sess")))
    (setf (fluxion.components:component-session parent) session)
    (fluxion.components:add-child parent child)
    (is (eq session (fluxion.components:component-session child)))))

(test composition-session-set-during-factory
  "component-session is set during session creation via factories."
  (let* ((app (fluxion.server:make-fluxion-app))
         (captured nil))
    (fluxion.server:register-component-factory app "test-comp"
      (lambda ()
        (make-instance 'page-component)))
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (multiple-value-bind (session new-p)
          (fluxion.server::get-or-create-session app env)
        (declare (ignore new-p))
        (setf captured (fluxion.server:session-component session "test-comp"))
        (is (not (null captured)))
        (is (eq session (fluxion.components:component-session captured)))))))

(test composition-deep-session-propagation
  "Session propagates through multi-level nesting."
  (let ((root (make-instance 'shell-component))
        (mid (make-instance 'page-component))
        (leaf (make-instance 'widget-a))
        (session (make-instance 'fluxion.server:session :id "deep-test")))
    ;; Build the tree first
    (fluxion.components:add-child root mid)
    (fluxion.components:add-child mid leaf)
    ;; Then set session on root and propagate
    (fluxion.components:propagate-session root session)
    (is (eq session (fluxion.components:component-session root)))
    (is (eq session (fluxion.components:component-session mid)))
    (is (eq session (fluxion.components:component-session leaf)))))

;;; -------------------------------------------------------
;;; Rendering with composition
;;; -------------------------------------------------------

(test composition-render-nested
  "Rendering a parent includes the child's output."
  (let ((shell (make-instance 'shell-component))
        (page (make-instance 'page-component :title "Dashboard")))
    (setf (shell-content shell) page)
    (fluxion.components:add-child shell page)
    (let ((html (fluxion.components:render shell)))
      (is (search "sidebar" html))
      (is (search "Dashboard" html))
      (is (search "id=page" html)))))

(test composition-child-only-patch
  "patch-component on a child returns events for only the child's selector."
  (let ((shell (make-instance 'shell-component))
        (page (make-instance 'page-component :title "Settings")))
    (fluxion.components:add-child shell page)
    (setf (shell-content shell) page)
    ;; Clear parent dirty, mark child dirty
    (fluxion.components:clear-dirty shell)
    (setf (fluxion.components:component-last-html shell) (fluxion.components:render shell))
    (fluxion.components:mark-dirty page)
    ;; Patching the child should produce events targeting "#page"
    (let ((events (fluxion.components:patch-component page :force t)))
      (is (= 1 (length events)))
      (let ((data (fluxion.protocol:event-data (first events))))
        (is (string= "#page" (cdr (assoc "selector" data :test #'string=))))))))

;;; -------------------------------------------------------
;;; Lifecycle callbacks with composition
;;; -------------------------------------------------------

(defclass lifecycle-parent (fluxion.components:component)
  ((mount-log :initform nil :accessor lp-mount-log))
  (:default-initargs :id "lp"))

(defmethod fluxion.components:component-mounted ((c lifecycle-parent) session)
  (push :mounted (lp-mount-log c)))

(defmethod fluxion.components:render ((c lifecycle-parent))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id c) "parent")))

(test composition-lifecycle-on-dynamic-child
  "Lifecycle callbacks are not disrupted by composition."
  (let* ((app (fluxion.server:make-fluxion-app))
         (parent-ref nil))
    (fluxion.server:register-component-factory app "lp"
      (lambda ()
        (let ((p (make-instance 'lifecycle-parent)))
          (setf parent-ref p)
          p)))
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (multiple-value-bind (session new-p)
          (fluxion.server::get-or-create-session app env)
        (declare (ignore new-p))
        ;; Parent was mounted via factory
        (is (equal '(:mounted) (lp-mount-log parent-ref)))
        ;; Dynamically add a child
        (let ((child (make-instance 'page-component)))
          (fluxion.components:add-child parent-ref child)
          ;; Child gets session from parent
          (is (eq session (fluxion.components:component-session child))))))))
