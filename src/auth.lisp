;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Authentication and authorization

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Authentication
;;; -------------------------------------------------------

(defun authenticated-p (session)
  "Return T if SESSION has an authenticated user."
  (not (null (session-user session))))

(defun authenticate (session user &key roles)
  "Set the authenticated user on SESSION.
USER can be any application-defined value (string, plist, CLOS object, etc.).
ROLES is an optional list of role keywords.
Regenerates the CSRF token to prevent session fixation."
  (setf (session-user session) user)
  (when roles
    (setf (session-user-roles session) roles))
  ;; Regenerate CSRF token on privilege change
  (setf (session-csrf-token session) (generate-csrf-token))
  user)

(defun logout (session)
  "Clear the authenticated user from SESSION.
Regenerates the CSRF token."
  (setf (session-user session) nil)
  (setf (session-user-roles session) nil)
  (setf (session-csrf-token session) (generate-csrf-token))
  nil)

(defun has-role-p (session role)
  "Return T if SESSION's user has ROLE in their roles list."
  (and (authenticated-p session)
       (member role (session-user-roles session))))

(defun require-auth (session &key (login-url "/login"))
  "If SESSION is not authenticated, return a redirect response to LOGIN-URL.
Returns NIL if the user is authenticated (meaning: proceed normally).
Use in page handlers as a guard:
  (or (require-auth session) (render-protected-page ...))"
  (unless (authenticated-p session)
    (list 303
          (list :location login-url
                :content-type "text/plain")
          '("Redirecting to login"))))

(defun require-role (session role &key (login-url "/login") (forbidden-url nil))
  "If SESSION's user lacks ROLE, return a redirect or 403 response.
Returns NIL if the user has the role (meaning: proceed normally).
If the user is not authenticated at all, redirects to LOGIN-URL.
If authenticated but lacking the role, returns 403 (or redirects to FORBIDDEN-URL)."
  (cond
    ((not (authenticated-p session))
     (list 303
           (list :location login-url
                 :content-type "text/plain")
           '("Redirecting to login")))
    ((not (has-role-p session role))
     (if forbidden-url
         (list 303
               (list :location forbidden-url
                     :content-type "text/plain")
               '("Insufficient permissions"))
         (list 403
               '(:content-type "text/plain")
               '("Forbidden: insufficient permissions"))))
    (t nil)))
