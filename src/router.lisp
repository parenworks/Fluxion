;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Path-based request router

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Router
;;; -------------------------------------------------------

(defclass route ()
  ((method  :initarg :method
            :accessor route-method
            :type keyword
            :documentation "HTTP method keyword (:get, :post, or :any).")
   (pattern :initarg :pattern
            :accessor route-pattern
            :type string
            :documentation "URL pattern, e.g. \"/users/:id\".")
   (segments :initarg :segments
             :accessor route-segments
             :documentation "Pre-parsed list of (keyword-or-string) segments.")
   (handler :initarg :handler
            :accessor route-handler
            :documentation "Function (app session env &key params) -> response.")
   (guard   :initarg :guard
            :accessor route-guard
            :initform nil
            :documentation "Optional guard function (session) -> response-or-nil.
If it returns a response, that response is sent and the handler is skipped.")
   (name    :initarg :name
            :accessor route-name
            :initform nil
            :documentation "Optional route name for URL generation."))
  (:documentation "A single route entry in the router."))

(defmethod print-object ((r route) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "~A ~A~@[ (~A)~]"
            (route-method r) (route-pattern r) (route-name r))))

(defclass router ()
  ((routes  :initform nil
            :accessor router-routes
            :documentation "List of route objects in registration order.")
   (not-found-handler :initarg :not-found-handler
                      :accessor router-not-found-handler
                      :initform nil
                      :documentation "Optional handler for 404. Signature: (app session env)."))
  (:documentation "Path-based request router."))

(defmethod print-object ((r router) stream)
  (print-unreadable-object (r stream :type t :identity t)
    (format stream "~D route~:P" (length (router-routes r)))))

(defun make-router (&key not-found-handler)
  "Create a new router instance."
  (make-instance 'router :not-found-handler not-found-handler))

(defun parse-pattern (pattern)
  "Parse a URL pattern like \"/users/:id/posts\" into a list of segments.
Each segment is either a string (literal) or a keyword (parameter).
Example: (\"/users/:id\") -> (\"users\" :id)"
  (loop for seg in (remove "" (uiop:split-string pattern :separator "/") :test #'string=)
        collect (if (and (> (length seg) 0)
                         (char= (char seg 0) #\:))
                    (intern (string-upcase (subseq seg 1)) :keyword)
                    seg)))

(defun match-route (route path method)
  "Try to match PATH and METHOD against ROUTE.
Returns (values matched-p params-alist) where params-alist contains
extracted path parameters."
  (unless (or (eq (route-method route) :any)
              (eq (route-method route) method))
    (return-from match-route (values nil nil)))
  (let ((path-segments (remove "" (uiop:split-string path :separator "/") :test #'string=))
        (route-segments (route-segments route))
        (params nil))
    (unless (= (length path-segments) (length route-segments))
      (return-from match-route (values nil nil)))
    (loop for ps in path-segments
          for rs in route-segments
          do (cond
               ((keywordp rs)
                (push (cons rs ps) params))
               ((string= ps rs)
                nil)
               (t
                (return-from match-route (values nil nil)))))
    (values t (nreverse params))))

(defun add-route (router method pattern handler &key guard name)
  "Add a route to the router. METHOD is :get, :post, or :any.
PATTERN is a URL path like \"/users/:id\".
HANDLER is (app session env &key params) -> response.
GUARD is an optional (session) -> response-or-nil."
  (let ((route (make-instance 'route
                              :method method
                              :pattern pattern
                              :segments (parse-pattern pattern)
                              :handler handler
                              :guard guard
                              :name name)))
    (setf (router-routes router)
          (append (router-routes router) (list route)))
    route))

(defun dispatch-route (router app session env)
  "Find and dispatch the first matching route. Returns a Clack response.
If no route matches, calls the not-found-handler or returns 404."
  (let ((path (get-request-path env))
        (method (get-request-method env)))
    (dolist (route (router-routes router))
      (multiple-value-bind (matched params)
          (match-route route path method)
        (when matched
          ;; Run guard if present
          (when (route-guard route)
            (let ((guard-response (funcall (route-guard route) session)))
              (when guard-response
                (return-from dispatch-route guard-response))))
          ;; Run handler
          (return-from dispatch-route
            (funcall (route-handler route) app session env :params params)))))
    ;; No match
    (if (router-not-found-handler router)
        (funcall (router-not-found-handler router) app session env)
        (list 404
              '(:content-type "text/plain")
              '("Not found")))))

(defun router-handler (router)
  "Return a page-handler function suitable for passing to start.
This bridges the router into the existing Fluxion server."
  (lambda (app session env)
    (dispatch-route router app session env)))

(defmacro defroute (router-var method pattern args &body body)
  "Define a route on ROUTER-VAR.
METHOD is :get, :post, or :any.
PATTERN is a URL path like \"/users/:id\".
ARGS is a lambda list (app session env &key params).

Example:
  (defroute *router* :get \"/\" (app session env &key params)
    (list 200 '(:content-type \"text/html\") (list \"Hello\")))

  (defroute *router* :get \"/users/:id\" (app session env &key params)
    (let ((user-id (cdr (assoc :id params))))
      ...))"
  `(add-route ,router-var ,method ,pattern
              (lambda ,args ,@body)))
