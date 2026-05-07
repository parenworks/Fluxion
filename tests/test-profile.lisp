;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Profile system tests

(in-package #:fluxion.db.tests)

(def-suite :profile-suite
  :description "Profile system tests"
  :in :db-suite)

(in-suite :profile-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-profile-db (&body body)
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (fluxion.db:*backend* backend))
     (fluxion.db:connect backend)
     (unwind-protect
          (progn
            (fluxion.user:setup)
            (fluxion.user:create "alice" :password "pass123")
            ;; Clear field definitions between tests
            (clrhash fluxion.profile::*field-definitions*)
            (clrhash fluxion.profile::*panel-definitions*)
            ,@body)
       (fluxion.db:disconnect backend))))

;;; -------------------------------------------------------
;;; Display name
;;; -------------------------------------------------------

(test profile-display-name-fallback
  "display-name returns username when no display name set"
  (with-profile-db
    (is (string= "alice" (fluxion.profile:display-name "alice")))))

(test profile-set-display-name
  "set-display-name stores and retrieves"
  (with-profile-db
    (fluxion.profile:set-display-name "alice" "Alice Smith")
    (is (string= "Alice Smith" (fluxion.profile:display-name "alice")))))

;;; -------------------------------------------------------
;;; Avatar
;;; -------------------------------------------------------

(test profile-avatar-url-no-email
  "avatar-url generates Gravatar URL from username"
  (with-profile-db
    (let ((url (fluxion.profile:avatar-url "alice")))
      (is (search "gravatar.com/avatar/" url))
      (is (search "s=80" url)))))

(test profile-avatar-url-with-email
  "avatar-url uses email when available"
  (with-profile-db
    (fluxion.user:set-field "alice" "email" "alice@example.com")
    (let ((url (fluxion.profile:avatar-url "alice" :size 120)))
      (is (search "gravatar.com/avatar/" url))
      (is (search "s=120" url)))))

;;; -------------------------------------------------------
;;; Field definitions
;;; -------------------------------------------------------

(test profile-define-field
  "define-field registers a field definition"
  (with-profile-db
    (fluxion.profile:define-field "bio" :type :text :visibility :public)
    (let ((def (fluxion.profile:field-definition "bio")))
      (is (not (null def)))
      (is (eq :text (fluxion.profile::field-def-type def)))
      (is (eq :public (fluxion.profile::field-def-visibility def))))))

(test profile-undefine-field
  "undefine-field removes a field definition"
  (with-profile-db
    (fluxion.profile:define-field "bio")
    (fluxion.profile:undefine-field "bio")
    (is (null (fluxion.profile:field-definition "bio")))))

(test profile-defined-fields
  "defined-fields returns all definitions sorted"
  (with-profile-db
    (fluxion.profile:define-field "bio")
    (fluxion.profile:define-field "website" :type :url)
    (let ((fields (fluxion.profile:defined-fields)))
      (is (= 2 (length fields)))
      (is (string= "bio"
                    (fluxion.profile::field-def-name (first fields)))))))

;;; -------------------------------------------------------
;;; Per-user field values
;;; -------------------------------------------------------

(test profile-set-and-get
  "set and get store/retrieve profile field values"
  (with-profile-db
    (fluxion.profile:set "alice" "bio" "Lisp hacker")
    (is (string= "Lisp hacker" (fluxion.profile:get "alice" "bio")))))

(test profile-remove-field
  "remove clears a profile field"
  (with-profile-db
    (fluxion.profile:set "alice" "bio" "test")
    (fluxion.profile:remove "alice" "bio")
    (is (null (fluxion.profile:get "alice" "bio")))))

(test profile-all-fields
  "all-fields returns all profile fields for a user"
  (with-profile-db
    (fluxion.profile:set "alice" "bio" "hello")
    (fluxion.profile:set "alice" "website" "https://example.com")
    (let ((fields (fluxion.profile:all-fields "alice")))
      (is (= 2 (length fields)))
      (is (assoc "bio" fields :test #'string=))
      (is (assoc "website" fields :test #'string=)))))

(test profile-public-fields
  "public-fields only returns fields with public visibility"
  (with-profile-db
    (fluxion.profile:define-field "bio" :visibility :public)
    (fluxion.profile:define-field "secret" :visibility :private)
    (fluxion.profile:set "alice" "bio" "hello")
    (fluxion.profile:set "alice" "secret" "shhh")
    (let ((public (fluxion.profile:public-fields "alice")))
      (is (= 1 (length public)))
      (is (string= "bio" (caar public))))))

(test profile-validator
  "field validator rejects invalid values"
  (with-profile-db
    (fluxion.profile:define-field "age"
      :type :integer
      :validator (lambda (v) (ignore-errors (parse-integer v))))
    (signals error
      (fluxion.profile:set "alice" "age" "not-a-number"))))

;;; -------------------------------------------------------
;;; Panels
;;; -------------------------------------------------------

(test profile-define-panel
  "define-panel registers a panel"
  (with-profile-db
    (fluxion.profile:define-panel "activity"
      :label "Activity"
      :order 10
      :renderer (lambda (username)
                  (declare (ignore username))
                  "<div>Activity</div>"))
    (let ((def (fluxion.profile:panel-definition "activity")))
      (is (not (null def)))
      (is (string= "Activity" (fluxion.profile::panel-def-label def))))))

(test profile-panels-sorted
  "panels returns definitions sorted by order"
  (with-profile-db
    (fluxion.profile:define-panel "second" :order 20)
    (fluxion.profile:define-panel "first" :order 10)
    (fluxion.profile:define-panel "third" :order 30)
    (let ((panels (fluxion.profile:panels)))
      (is (= 3 (length panels)))
      (is (string= "first"
                    (fluxion.profile::panel-def-name (first panels)))))))

(test profile-undefine-panel
  "undefine-panel removes a panel"
  (with-profile-db
    (fluxion.profile:define-panel "temp")
    (fluxion.profile:undefine-panel "temp")
    (is (null (fluxion.profile:panel-definition "temp")))))
