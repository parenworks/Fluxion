;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Authentication interface (fluxion.auth)
;;;;
;;;; Handles login/logout and session-to-user binding.
;;;; Built on top of fluxion.user and fluxion.server sessions.
;;;;
;;;; Usage:
;;;;   (auth:login "alice" "secret")   ; authenticate and bind to session
;;;;   (auth:current)                  ; => user alist or NIL
;;;;   (auth:logout)                   ; unbind user from session
;;;;   (auth:require-authenticated)    ; signal if not logged in

(defpackage #:fluxion.auth
  (:use #:cl)
  (:local-nicknames (#:user #:fluxion.user))
  (:export
   ;; Core API
   #:login
   #:logout
   #:current
   #:current-user-id
   #:require-authenticated

   ;; Hooks
   #:*on-login*
   #:*on-logout*

   ;; Login timeout
   #:*login-timeout*

   ;; Conditions
   #:authentication-failed
   #:not-authenticated))

(in-package #:fluxion.auth)

;;; -------------------------------------------------------
;;; Conditions
;;; -------------------------------------------------------

(define-condition authentication-failed (error)
  ((username :initarg :username :reader authentication-failed-username))
  (:report (lambda (c s)
             (format s "Authentication failed for user: ~A"
                     (authentication-failed-username c)))))

(define-condition not-authenticated (error)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "No authenticated user in current session"))))

;;; -------------------------------------------------------
;;; Configuration
;;; -------------------------------------------------------

(defvar *on-login* nil
  "Function called after successful login with (user-alist session).
Use for audit logging, analytics, etc.")

(defvar *on-logout* nil
  "Function called after logout with (username session).
Use for cleanup, audit logging, etc.")

(defvar *login-timeout* nil
  "Optional override for session TTL after login (in seconds).
When set, the session expiry is adjusted after successful login.
NIL means use the default session TTL.")

;;; -------------------------------------------------------
;;; Core API
;;; -------------------------------------------------------

(defun login (username password)
  "Authenticate USERNAME with PASSWORD and bind to the current session.
Returns the user alist on success.
Signals AUTHENTICATION-FAILED if credentials are invalid.
Requires *current-session* to be bound (i.e. called within a request)."
  (let ((user-row (user:get username)))
    ;; Check user exists
    (unless user-row
      (error 'authentication-failed :username username))
    ;; Verify password
    (let ((pw-hash (user:user-password-hash user-row)))
      (unless (and pw-hash
                   (plusp (length pw-hash))
                   (user:verify-password password pw-hash))
        (error 'authentication-failed :username username)))
    ;; Bind user to session
    (let ((session fluxion.server:*current-session*))
      (setf (fluxion.server:session-user session) user-row)
      (setf (fluxion.server:session-user-roles session)
            (mapcar (lambda (p) (intern (string-upcase p) :keyword))
                    (user:permissions username)))
      ;; Regenerate CSRF token on auth change
      (setf (fluxion.server:session-csrf-token session)
            (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))
      ;; Call hook
      (when *on-login*
        (funcall *on-login* user-row session))
      user-row)))

(defun logout ()
  "Unbind the current user from the session.
Clears user data, roles, and regenerates CSRF token.
Returns T if a user was logged out, NIL if no user was bound."
  (let ((session fluxion.server:*current-session*))
    (let ((user (fluxion.server:session-user session)))
      (when user
        (let ((username (if (consp user)
                            (user:user-username user)
                            user)))
          (setf (fluxion.server:session-user session) nil)
          (setf (fluxion.server:session-user-roles session) nil)
          (setf (fluxion.server:session-csrf-token session)
                (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))
          ;; Call hook
          (when *on-logout*
            (funcall *on-logout* username session))
          t)))))

(defun current ()
  "Return the user alist for the current session, or NIL if not authenticated."
  (fluxion.server:session-user fluxion.server:*current-session*))

(defun current-user-id ()
  "Return the database ID of the current user, or NIL."
  (let ((user (current)))
    (when (consp user)
      (user:user-id user))))

(defun require-authenticated ()
  "Signal NOT-AUTHENTICATED if no user is bound to the current session.
Use at the start of handlers that require login."
  (unless (current)
    (error 'not-authenticated)))
