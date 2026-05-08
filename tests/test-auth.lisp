;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Authentication interface tests

(in-package #:fluxion.db.tests)

(def-suite :auth-suite
  :description "Authentication interface tests"
  :in :db-suite)

(in-suite :auth-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-auth-db (&body body)
  "Set up in-memory SQLite with user tables and a mock session, then run BODY."
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (fluxion.db:*backend* backend)
          (fluxion.server:*current-session*
            (make-instance 'fluxion.server:session :id "test-session")))
     (fluxion.db:connect backend)
     (unwind-protect
          (progn
            (fluxion.user:setup)
            ,@body)
       (fluxion.db:disconnect backend))))

;;; -------------------------------------------------------
;;; Login tests
;;; -------------------------------------------------------

(test auth-login-success
  "Successful login binds user to session"
  (with-auth-db
    (fluxion.user:create "alice" :password "secret123")
    (let ((user (fluxion.auth:login "alice" "secret123")))
      (is (not (null user)))
      (is (string= "alice" (fluxion.user:user-username user)))
      ;; Session should have user bound
      (is (not (null (fluxion.auth:current))))
      (is (string= "alice"
                    (fluxion.user:user-username (fluxion.auth:current)))))))

(test auth-login-wrong-password
  "Wrong password signals authentication-failed"
  (with-auth-db
    (fluxion.user:create "alice" :password "secret123")
    (signals fluxion.auth:authentication-failed
      (fluxion.auth:login "alice" "wrongpassword"))))

(test auth-login-nonexistent-user
  "Login with nonexistent user signals authentication-failed"
  (with-auth-db
    (signals fluxion.auth:authentication-failed
      (fluxion.auth:login "nobody" "password"))))

(test auth-login-no-password-user
  "Login against user with no password signals authentication-failed"
  (with-auth-db
    (fluxion.user:create "alice")
    (signals fluxion.auth:authentication-failed
      (fluxion.auth:login "alice" "anything"))))

(test auth-login-sets-roles
  "Login populates session-user-roles as keywords from permissions"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (fluxion.user:grant "alice" "admin")
    (fluxion.user:grant "alice" "editor")
    (fluxion.auth:login "alice" "pass")
    (let ((roles (fluxion.server:session-user-roles
                  fluxion.server:*current-session*)))
      (is (= 2 (length roles)))
      (is (member :admin roles))
      (is (member :editor roles)))))

(test auth-login-regenerates-csrf
  "Login regenerates the CSRF token"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (let ((old-csrf (fluxion.server:session-csrf-token
                     fluxion.server:*current-session*)))
      (fluxion.auth:login "alice" "pass")
      (is (not (string= old-csrf
                         (fluxion.server:session-csrf-token
                          fluxion.server:*current-session*)))))))

;;; -------------------------------------------------------
;;; Logout tests
;;; -------------------------------------------------------

(test auth-logout
  "Logout clears user from session"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (fluxion.auth:login "alice" "pass")
    (is (not (null (fluxion.auth:current))))
    (is (eq t (fluxion.auth:logout)))
    (is (null (fluxion.auth:current)))))

(test auth-logout-no-user
  "Logout returns NIL when no user is bound"
  (with-auth-db
    (is (null (fluxion.auth:logout)))))

(test auth-logout-clears-roles
  "Logout clears session-user-roles"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (fluxion.user:grant "alice" "admin")
    (fluxion.auth:login "alice" "pass")
    (fluxion.auth:logout)
    (is (null (fluxion.server:session-user-roles
               fluxion.server:*current-session*)))))

;;; -------------------------------------------------------
;;; Current user tests
;;; -------------------------------------------------------

(test auth-current-nil-when-not-logged-in
  "current returns NIL with no authenticated user"
  (with-auth-db
    (is (null (fluxion.auth:current)))))

(test auth-current-user-id
  "current-user-id returns the database ID"
  (with-auth-db
    (let ((uid (fluxion.user:create "alice" :password "pass")))
      (fluxion.auth:login "alice" "pass")
      (is (eql uid (fluxion.auth:current-user-id))))))

(test auth-require-authenticated-passes
  "require-authenticated does not signal when logged in"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (fluxion.auth:login "alice" "pass")
    (finishes (fluxion.auth:require-authenticated))))

(test auth-require-authenticated-signals
  "require-authenticated signals not-authenticated when not logged in"
  (with-auth-db
    (signals fluxion.auth:not-authenticated
      (fluxion.auth:require-authenticated))))

;;; -------------------------------------------------------
;;; Hook tests
;;; -------------------------------------------------------

(test auth-on-login-hook
  "on-login hook is called with user and session"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (let ((hook-called nil))
      (let ((fluxion.auth:*on-login*
              (lambda (user session)
                (setf hook-called (list (fluxion.user:user-username user)
                                        (fluxion.server:session-id session))))))
        (fluxion.auth:login "alice" "pass")
        (is (equal '("alice" "test-session") hook-called))))))

(test auth-on-logout-hook
  "on-logout hook is called with username and session"
  (with-auth-db
    (fluxion.user:create "alice" :password "pass")
    (fluxion.auth:login "alice" "pass")
    (let ((hook-called nil))
      (let ((fluxion.auth:*on-logout*
              (lambda (username session)
                (setf hook-called (list username
                                        (fluxion.server:session-id session))))))
        (fluxion.auth:logout)
        (is (equal '("alice" "test-session") hook-called))))))
