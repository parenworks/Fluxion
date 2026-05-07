;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - User system tests

(in-package #:fluxion.db.tests)

(def-suite :user-suite
  :description "User/account system tests"
  :in :db-suite)

(in-suite :user-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-user-db (&body body)
  "Set up an in-memory SQLite backend with user tables and run BODY."
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (fluxion.db:*backend* backend))
     (fluxion.db:connect backend)
     (unwind-protect
          (progn
            (fluxion.user:setup)
            ,@body)
       (fluxion.db:disconnect backend))))

;;; -------------------------------------------------------
;;; Setup
;;; -------------------------------------------------------

(test user-setup-creates-tables
  "setup creates user, fields, and permissions tables"
  (with-user-db
    (is (fluxion.db:collection-exists-p "fluxion_users"))
    (is (fluxion.db:collection-exists-p "fluxion_user_fields"))
    (is (fluxion.db:collection-exists-p "fluxion_permissions"))))

(test user-setup-idempotent
  "setup can be called multiple times"
  (with-user-db
    (fluxion.user:setup)
    (is (fluxion.db:collection-exists-p "fluxion_users"))))

;;; -------------------------------------------------------
;;; Core CRUD
;;; -------------------------------------------------------

(test user-create-and-get
  "Creating a user and retrieving it"
  (with-user-db
    (let ((id (fluxion.user:create "alice" :password "secret123")))
      (is (integerp id))
      (let ((user (fluxion.user:get "alice")))
        (is (not (null user)))
        (is (string= "alice" (fluxion.user:user-username user)))
        (is (eql id (fluxion.user:user-id user)))))))

(test user-create-no-password
  "Users can be created without a password"
  (with-user-db
    (let ((id (fluxion.user:create "bob")))
      (is (integerp id))
      (let ((user (fluxion.user:get "bob")))
        (is (string= "" (fluxion.user:user-password-hash user)))))))

(test user-create-duplicate-signals
  "Creating a duplicate user signals user-already-exists"
  (with-user-db
    (fluxion.user:create "alice")
    (signals fluxion.user:user-already-exists
      (fluxion.user:create "alice"))))

(test user-remove
  "Removing a user deletes it from the database"
  (with-user-db
    (fluxion.user:create "alice")
    (is (not (null (fluxion.user:get "alice"))))
    (fluxion.user:remove "alice")
    (is (null (fluxion.user:get "alice")))))

(test user-remove-nonexistent-signals
  "Removing a nonexistent user signals user-not-found"
  (with-user-db
    (signals fluxion.user:user-not-found
      (fluxion.user:remove "nobody"))))

(test user-list
  "list-users returns all users"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:create "bob")
    (fluxion.user:create "carol")
    (let ((users (fluxion.user:list-users)))
      (is (= 3 (length users))))))

(test user-get-nonexistent
  "get returns NIL for nonexistent user"
  (with-user-db
    (is (null (fluxion.user:get "nobody")))))

(test user-identity-comparison
  "user= compares by database ID"
  (with-user-db
    (fluxion.user:create "alice")
    (let ((a1 (fluxion.user:get "alice"))
          (a2 (fluxion.user:get "alice")))
      (is (fluxion.user:user= a1 a2))
      (is (fluxion.user:user= "alice" a1)))))

;;; -------------------------------------------------------
;;; Password hashing
;;; -------------------------------------------------------

(test password-hash-and-verify
  "hash-password and verify-password roundtrip"
  (let ((hash (fluxion.user:hash-password "mypassword")))
    (is (stringp hash))
    (is (find #\: hash))
    (is (fluxion.user:verify-password "mypassword" hash))
    (is (not (fluxion.user:verify-password "wrongpassword" hash)))))

(test password-different-salts
  "Each hash uses a different random salt"
  (let ((h1 (fluxion.user:hash-password "same"))
        (h2 (fluxion.user:hash-password "same")))
    (is (not (string= h1 h2)))))

;;; -------------------------------------------------------
;;; Extensible fields
;;; -------------------------------------------------------

(test user-set-and-get-field
  "set-field and field roundtrip"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:set-field "alice" "email" "alice@example.com")
    (is (string= "alice@example.com"
                  (fluxion.user:field "alice" "email")))))

(test user-fields-list
  "fields returns all custom fields"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:set-field "alice" "email" "a@b.com")
    (fluxion.user:set-field "alice" "phone" "555-0100")
    (let ((f (fluxion.user:fields "alice")))
      (is (= 2 (length f)))
      (is (assoc "email" f :test #'string=))
      (is (assoc "phone" f :test #'string=)))))

(test user-set-field-updates
  "set-field updates existing fields"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:set-field "alice" "email" "old@example.com")
    (fluxion.user:set-field "alice" "email" "new@example.com")
    (is (string= "new@example.com"
                  (fluxion.user:field "alice" "email")))))

(test user-create-with-fields
  "create accepts initial fields"
  (with-user-db
    (fluxion.user:create "alice"
                         :fields '(("email" . "a@b.com") ("org" . "acme")))
    (is (string= "a@b.com" (fluxion.user:field "alice" "email")))
    (is (string= "acme" (fluxion.user:field "alice" "org")))))

(test user-remove-field
  "remove-field deletes a custom field"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:set-field "alice" "email" "a@b.com")
    (fluxion.user:remove-field "alice" "email")
    (is (null (fluxion.user:field "alice" "email")))))

(test user-field-nonexistent-user-signals
  "field on nonexistent user signals user-not-found"
  (with-user-db
    (signals fluxion.user:user-not-found
      (fluxion.user:field "nobody" "email"))))

(test user-remove-cascades-fields
  "Removing a user also removes their fields"
  (with-user-db
    (fluxion.user:create "alice"
                         :fields '(("email" . "a@b.com")))
    (fluxion.user:remove "alice")
    ;; Fields table should have no rows for this user
    (let ((rows (fluxion.db:select "fluxion_user_fields"
                                   (fluxion.db.query:compile-query :all))))
      (is (= 0 (length rows))))))

;;; -------------------------------------------------------
;;; Permissions/ACL
;;; -------------------------------------------------------

(test user-grant-and-check
  "grant and check basic permission"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "admin")
    (is (fluxion.user:check "alice" "admin"))))

(test user-check-hierarchical
  "Hierarchical permission: admin implies admin.users.edit"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "admin")
    (is (fluxion.user:check "alice" "admin.users"))
    (is (fluxion.user:check "alice" "admin.users.edit"))))

(test user-check-no-false-prefix
  "admin does not grant adminator"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "admin")
    (is (not (fluxion.user:check "alice" "adminator")))))

(test user-check-not-granted
  "check returns NIL for ungrated permission"
  (with-user-db
    (fluxion.user:create "alice")
    (is (not (fluxion.user:check "alice" "admin")))))

(test user-grant-idempotent
  "Granting the same permission twice does not duplicate"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "admin")
    (fluxion.user:grant "alice" "admin")
    (is (= 1 (length (fluxion.user:permissions "alice"))))))

(test user-revoke
  "revoke removes a permission"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "admin")
    (fluxion.user:revoke "alice" "admin")
    (is (not (fluxion.user:check "alice" "admin")))))

(test user-permissions-list
  "permissions returns all granted permissions"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "read")
    (fluxion.user:grant "alice" "write")
    (let ((perms (fluxion.user:permissions "alice")))
      (is (= 2 (length perms)))
      (is (member "read" perms :test #'string=))
      (is (member "write" perms :test #'string=)))))

(test user-default-permissions
  "Default permissions are applied on create"
  (with-user-db
    (let ((fluxion.user:*default-permissions* '("user.read" "user.profile")))
      (fluxion.user:create "alice")
      (is (fluxion.user:check "alice" "user.read"))
      (is (fluxion.user:check "alice" "user.profile")))))

(test user-remove-cascades-permissions
  "Removing a user also removes their permissions"
  (with-user-db
    (fluxion.user:create "alice")
    (fluxion.user:grant "alice" "admin")
    (fluxion.user:remove "alice")
    (let ((rows (fluxion.db:select "fluxion_permissions"
                                   (fluxion.db.query:compile-query :all))))
      (is (= 0 (length rows))))))
