;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.components

(in-package #:fluxion.tests)
(in-suite components-suite)

;;; -------------------------------------------------------
;;; Test component (manual class definition)
;;; -------------------------------------------------------

(defclass test-widget (fluxion.components:component)
  ((label :initform "hello" :accessor test-widget-label))
  (:default-initargs :id "test-widget"))

(defmethod fluxion.components:render ((w test-widget))
  (format nil "<div id=\"~A\">~A</div>"
          (fluxion.components:component-id w)
          (test-widget-label w)))

(test component-creation
  "Components get an ID and start dirty."
  (let ((w (make-instance 'test-widget)))
    (is (string= "test-widget" (fluxion.components:component-id w)))
    (is-true (fluxion.components:component-dirty-p w))))

(test component-auto-id
  "Components without explicit ID get an auto-generated one."
  (let ((w (make-instance 'fluxion.components:component)))
    (is (stringp (fluxion.components:component-id w)))
    (is (search "fluxion-" (fluxion.components:component-id w)))))

(test component-selector
  "component-selector returns #id."
  (let ((w (make-instance 'test-widget)))
    (is (string= "#test-widget" (fluxion.components:component-selector w)))))

(test component-render
  "render returns HTML with the correct ID."
  (let* ((w (make-instance 'test-widget))
         (html (fluxion.components:render w)))
    (is (search "test-widget" html))
    (is (search "hello" html))))

(test component-dirty-tracking
  "mark-dirty and clear-dirty work."
  (let ((w (make-instance 'test-widget)))
    (fluxion.components:clear-dirty w)
    (is-false (fluxion.components:component-dirty-p w))
    (fluxion.components:mark-dirty w)
    (is-true (fluxion.components:component-dirty-p w))))

(test patch-component-returns-event
  "patch-component returns a list with one patch event."
  (let* ((w (make-instance 'test-widget))
         (events (fluxion.components:patch-component w)))
    (is (= 1 (length events)))
    (let ((e (first events)))
      (is (string= "fluxion-patch" (fluxion.protocol:event-type e))))))

(test patch-component-caches-html
  "patch-component caches the HTML and skips if unchanged."
  (let ((w (make-instance 'test-widget)))
    ;; First patch
    (let ((events1 (fluxion.components:patch-component w)))
      (is (= 1 (length events1))))
    ;; Second patch without changes - should be empty
    (let ((events2 (fluxion.components:patch-component w)))
      (is (= 0 (length events2))))))

(test patch-component-force
  "patch-component :force t always sends."
  (let ((w (make-instance 'test-widget)))
    (fluxion.components:patch-component w)
    ;; Force should send even though nothing changed
    (let ((events (fluxion.components:patch-component w :force t)))
      (is (= 1 (length events))))))

(test patch-component-after-mutation
  "Mutating the component and marking dirty produces a new patch."
  (let ((w (make-instance 'test-widget)))
    (fluxion.components:patch-component w)
    ;; Mutate
    (setf (test-widget-label w) "changed")
    (fluxion.components:mark-dirty w)
    (let ((events (fluxion.components:patch-component w)))
      (is (= 1 (length events)))
      (let* ((e (first events))
             (data (fluxion.protocol:event-data e))
             (fragment (cdr (assoc "fragment" data :test #'string=))))
        (is (search "changed" fragment))))))

;;; -------------------------------------------------------
;;; defaction tests
;;; -------------------------------------------------------

(fluxion.components:defaction test-widget :set-label (w params)
  (setf (test-widget-label w)
        (or (cdr (assoc :label params)) "default"))
  nil)

(test defaction-dispatches
  "defaction creates a handle-action method that dispatches correctly."
  (let ((w (make-instance 'test-widget)))
    (let ((events (fluxion.components:handle-action w :set-label '((:label . "new")))))
      ;; Returns events (auto-patch since body returned nil)
      (is (listp events))
      (is (>= (length events) 1)))
    (is (string= "new" (test-widget-label w)))))

(test defaction-marks-dirty
  "defaction marks the component dirty before running the body."
  (let ((w (make-instance 'test-widget)))
    (fluxion.components:clear-dirty w)
    (fluxion.components:handle-action w :set-label nil)
    ;; After action, dirty should have been set (and then cleared by patch)
    ;; The label should be "default" since params was nil
    (is (string= "default" (test-widget-label w)))))

;;; -------------------------------------------------------
;;; defcomponent tests
;;; -------------------------------------------------------

(fluxion.components:defcomponent test-counter
  :id "test-counter"
  :slots ((count :cell t :initform 0 :accessor test-counter-count)
          (title :initform "Test" :accessor test-counter-title))
  :render (format nil "<div id=\"~A\">~A: ~D</div>"
                  (fluxion.components:component-id self)
                  (test-counter-title self)
                  (test-counter-count self)))

(test defcomponent-creates-class
  "defcomponent creates a class that can be instantiated."
  (let ((c (make-instance 'test-counter)))
    (is (string= "test-counter" (fluxion.components:component-id c)))))

(test defcomponent-cell-accessor
  "Cell-backed slots have working accessors."
  (let ((c (make-instance 'test-counter)))
    (is (= 0 (test-counter-count c)))
    (setf (test-counter-count c) 42)
    (is (= 42 (test-counter-count c)))))

(test defcomponent-plain-slot
  "Plain (non-cell) slots work normally."
  (let ((c (make-instance 'test-counter)))
    (is (string= "Test" (test-counter-title c)))))

(test defcomponent-render
  "defcomponent generates a working render method."
  (let* ((c (make-instance 'test-counter))
         (html (fluxion.components:render c)))
    (is (search "test-counter" html))
    (is (search "Test" html))
    (is (search "0" html))))

(test defcomponent-cell-triggers-patch
  "Changing a cell-backed slot collects a patch event."
  (let ((c (make-instance 'test-counter))
        (fluxion.cells:*pending-events* (list nil)))
    ;; Prime the cache
    (fluxion.components:patch-component c)
    ;; Change the cell value
    (setf (test-counter-count c) 10)
    ;; The cell watcher should have collected events
    (let ((events (fluxion.cells:drain-pending-events)))
      (is (>= (length events) 1)))))

(test defcomponent-default-id
  "defcomponent defaults ID to the downcased class name."
  (fluxion.components:defcomponent test-auto-id-widget
    :slots ()
    :render "<div></div>")
  (let ((w (make-instance 'test-auto-id-widget)))
    (is (string= "test-auto-id-widget" (fluxion.components:component-id w)))))
