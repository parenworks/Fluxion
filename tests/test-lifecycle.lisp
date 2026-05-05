;;;; -*- encoding:utf-8 -*-
;;;; Tests for component lifecycle callbacks

(in-package #:fluxion.tests)

(def-suite lifecycle-suite :in fluxion-suite)
(in-suite lifecycle-suite)

;;; -------------------------------------------------------
;;; Test component with lifecycle tracking
;;; -------------------------------------------------------

(defclass lifecycle-widget (fluxion.components:component)
  ((mount-log :initform nil :accessor widget-mount-log)
   (unmount-log :initform nil :accessor widget-unmount-log)
   (connect-log :initform nil :accessor widget-connect-log))
  (:default-initargs :id "lifecycle-widget"))

(defmethod fluxion.components:render ((w lifecycle-widget))
  (format nil "<div id=\"~A\">lifecycle</div>" (fluxion.components:component-id w)))

(defmethod fluxion.components:component-mounted ((w lifecycle-widget) session)
  (push (fluxion.server:session-id session) (widget-mount-log w)))

(defmethod fluxion.components:component-unmounted ((w lifecycle-widget) session)
  (push (fluxion.server:session-id session) (widget-unmount-log w)))

(defmethod fluxion.components:component-connected ((w lifecycle-widget) session)
  (push (fluxion.server:session-id session) (widget-connect-log w)))

;;; -------------------------------------------------------
;;; component-mounted tests
;;; -------------------------------------------------------

(test lifecycle-mounted-called-on-session-creation
  "component-mounted is called when a factory creates a component for a new session."
  (let* ((app (fluxion.server:make-fluxion-app))
         (widget-ref nil))
    (fluxion.server:register-component-factory app "lifecycle-widget"
      (lambda ()
        (let ((w (make-instance 'lifecycle-widget)))
          (setf widget-ref w)
          w)))
    ;; Simulate a request that triggers session creation
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (multiple-value-bind (session new-p)
          (fluxion.server::get-or-create-session app env)
        (declare (ignore new-p))
        (is (not (null widget-ref)))
        (is (equal (list (fluxion.server:session-id session))
                   (widget-mount-log widget-ref)))))))

(test lifecycle-mounted-not-called-on-existing-session
  "component-mounted is not called again when an existing session is retrieved."
  (let* ((app (fluxion.server:make-fluxion-app))
         (widget-ref nil))
    (fluxion.server:register-component-factory app "lifecycle-widget"
      (lambda ()
        (let ((w (make-instance 'lifecycle-widget)))
          (setf widget-ref w)
          w)))
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (multiple-value-bind (session new-p)
          (fluxion.server::get-or-create-session app env)
        (declare (ignore new-p))
        ;; Second request with same session cookie
        (let ((env2 (list :request-method :get
                          :path-info "/"
                          :cookie (format nil "fluxion-session=~A"
                                          (fluxion.server:session-id session))
                          :headers (make-hash-table :test 'equal))))
          (fluxion.server::get-or-create-session app env2)
          ;; Still only one mount call
          (is (= 1 (length (widget-mount-log widget-ref)))))))))

;;; -------------------------------------------------------
;;; component-unmounted tests
;;; -------------------------------------------------------

(test lifecycle-unmounted-called-on-reap
  "component-unmounted is called when a session is reaped."
  (let* ((app (fluxion.server:make-fluxion-app :session-ttl 0))
         (widget-ref nil))
    (fluxion.server:register-component-factory app "lifecycle-widget"
      (lambda ()
        (let ((w (make-instance 'lifecycle-widget)))
          (setf widget-ref w)
          w)))
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (multiple-value-bind (session new-p)
          (fluxion.server::get-or-create-session app env)
        (declare (ignore new-p))
        ;; Force expiry (universal-time has 1-second granularity)
        (sleep 1.1)
        (let ((reaped (fluxion.server::reap-sessions app)))
          (is (= 1 reaped))
          (is (equal (list (fluxion.server:session-id session))
                     (widget-unmount-log widget-ref))))))))

(defclass error-on-unmount-widget (fluxion.components:component)
  ()
  (:default-initargs :id "error-widget"))

(defmethod fluxion.components:render ((w error-on-unmount-widget))
  "<div id=\"error-widget\">error</div>")

(defmethod fluxion.components:component-unmounted ((w error-on-unmount-widget) session)
  (declare (ignore session))
  (error "Intentional test error in unmount"))

(test lifecycle-unmounted-errors-dont-prevent-reaping
  "An error in component-unmounted does not prevent the session from being reaped."
  (let ((app (fluxion.server:make-fluxion-app :session-ttl 0)))
    (fluxion.server:register-component-factory app "error-widget"
      (lambda () (make-instance 'error-on-unmount-widget)))
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (fluxion.server::get-or-create-session app env)
      (sleep 1.1)
      (let ((reaped (fluxion.server::reap-sessions app)))
        (is (= 1 reaped))
        ;; Session was still removed despite the error
        (is (= 0 (hash-table-count (fluxion.server:app-sessions app))))))))

;;; -------------------------------------------------------
;;; component-connected tests (end-to-end via HTTP)
;;; -------------------------------------------------------

(test lifecycle-connected-called-on-sse
  "component-connected fires when a real SSE connection is established."
  (let* ((widget-ref nil)
         (port (+ 19800 (random 100)))
         (app (fluxion.server:make-fluxion-app :port port :server :hunchentoot)))
    (fluxion.server:register-component-factory app "lifecycle-widget"
      (lambda ()
        (let ((w (make-instance 'lifecycle-widget)))
          (setf widget-ref w)
          w)))
    (fluxion.server:start app
      (lambda (app session env)
        (declare (ignore app env))
        (list 200 '(:content-type "text/html")
              (list (format nil "<html><body>~A</body></html>"
                            (fluxion.components:render
                             (fluxion.server:session-component
                              session "lifecycle-widget")))))))
    (unwind-protect
         (progn
           (sleep 0.3)
           ;; First request creates the session (mounted fires, not connected)
           (multiple-value-bind (body status headers)
               (dex:get (format nil "http://127.0.0.1:~D/" port))
             (declare (ignore body status))
             (let ((cookie (gethash "set-cookie" headers)))
               (is (not (null widget-ref)))
               (is (= 1 (length (widget-mount-log widget-ref))))
               (is (null (widget-connect-log widget-ref)))
               ;; Now open SSE with the session cookie
               (let ((sse-thread
                       (bordeaux-threads:make-thread
                        (lambda ()
                          (ignore-errors
                            (dex:get (format nil "http://127.0.0.1:~D/sse" port)
                                     :headers `(("Cookie" . ,cookie))
                                     :read-timeout 2))))))
                 (sleep 0.5)
                 ;; component-connected should have fired
                 (is (= 1 (length (widget-connect-log widget-ref))))
                 ;; Clean up the SSE thread
                 (ignore-errors (bordeaux-threads:destroy-thread sse-thread))))))
      (fluxion.server:stop app))))

(test lifecycle-connected-fires-each-time
  "component-connected fires on every SSE connection (reconnect scenario)."
  (let* ((app (fluxion.server:make-fluxion-app))
         (widget-ref nil))
    (fluxion.server:register-component-factory app "lifecycle-widget"
      (lambda ()
        (let ((w (make-instance 'lifecycle-widget)))
          (setf widget-ref w)
          w)))
    (let ((env (list :request-method :get
                     :path-info "/"
                     :headers (make-hash-table :test 'equal))))
      (multiple-value-bind (session new-p)
          (fluxion.server::get-or-create-session app env)
        (declare (ignore new-p))
        ;; Simulate 3 SSE connections (same code path as handler.lisp)
        (dotimes (i 3)
          (maphash (lambda (id c)
                     (declare (ignore id))
                     (ignore-errors
                       (fluxion.components:component-connected c session)))
                   (fluxion.server:session-components session)))
        (is (= 3 (length (widget-connect-log widget-ref))))))))
