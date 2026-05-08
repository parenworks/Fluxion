;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - User/account system (fluxion.user)
;;;;
;;;; Persistent user objects stored in the database with extensible
;;;; fields and hierarchical permissions.
;;;;
;;;; Usage:
;;;;   (user:create "alice" :password "secret" :fields '(("email" . "a@b.com")))
;;;;   (user:get "alice")
;;;;   (user:grant "alice" "admin.users.edit")
;;;;   (user:check "alice" "admin.users")  ; => T (prefix match)
;;;;   (user:field "alice" "email")         ; => "a@b.com"

(defpackage #:fluxion.user
  (:use #:cl)
  (:local-nicknames (#:db #:fluxion.db)
                    (#:q #:fluxion.db.query))
  (:shadow #:get #:remove)
  (:export
   ;; Core API
   #:setup
   #:create
   #:remove
   #:get
   #:list-users
   #:user-id
   #:user-username
   #:user-password-hash
   #:user=

   ;; Extensible fields
   #:fields
   #:field
   #:set-field
   #:remove-field

   ;; Permissions/ACL
   #:grant
   #:revoke
   #:check
   #:permissions
   #:add-default-permissions
   #:*default-permissions*

   ;; Password utilities
   #:hash-password
   #:verify-password

   ;; Conditions
   #:user-error
   #:user-not-found
   #:user-already-exists
   #:permission-denied))

(in-package #:fluxion.user)

;;; -------------------------------------------------------
;;; Conditions
;;; -------------------------------------------------------

(define-condition user-error (error)
  ((message :initarg :message :reader user-error-message))
  (:report (lambda (c s) (format s "~A" (user-error-message c)))))

(define-condition user-not-found (user-error)
  ((username :initarg :username :reader user-not-found-username))
  (:report (lambda (c s)
             (format s "User not found: ~A" (user-not-found-username c)))))

(define-condition user-already-exists (user-error)
  ((username :initarg :username :reader user-already-exists-username))
  (:report (lambda (c s)
             (format s "User already exists: ~A" (user-already-exists-username c)))))

(define-condition permission-denied (user-error)
  ((username :initarg :username :reader permission-denied-username)
   (permission :initarg :permission :reader permission-denied-permission))
  (:report (lambda (c s)
             (format s "Permission denied: ~A lacks ~A"
                     (permission-denied-username c)
                     (permission-denied-permission c)))))

;;; -------------------------------------------------------
;;; Table definitions
;;; -------------------------------------------------------

(defparameter *users-table* "fluxion_users"
  "Name of the users table.")

(defparameter *users-structure*
  '((username :text)
    (password_hash :text))
  "Core columns for the users table. Applications add custom fields via alter.")

(defparameter *user-fields-table* "fluxion_user_fields"
  "Name of the extensible user fields table.")

(defparameter *user-fields-structure*
  '((user_id :integer)
    (field_name :text)
    (field_value :text))
  "Structure for the extensible user fields table (EAV pattern).")

(defparameter *permissions-table* "fluxion_permissions"
  "Name of the permissions table.")

(defparameter *permissions-structure*
  '((user_id :integer)
    (permission :text))
  "Structure for the permissions table.")

;;; -------------------------------------------------------
;;; Setup
;;; -------------------------------------------------------

(defun setup ()
  "Create the user, fields, and permissions tables if they do not exist.
Idempotent: safe to call multiple times."
  (unless (db:collection-exists-p *users-table*)
    (db:create *users-table* *users-structure*))
  (unless (db:collection-exists-p *user-fields-table*)
    (db:create *user-fields-table* *user-fields-structure*))
  (unless (db:collection-exists-p *permissions-table*)
    (db:create *permissions-table* *permissions-structure*)))

;;; -------------------------------------------------------
;;; Password hashing
;;; -------------------------------------------------------

(defparameter *pbkdf2-iterations* 100000
  "Number of PBKDF2 iterations for password hashing.")

(defparameter *pbkdf2-key-length* 32
  "Length of the derived key in bytes.")

(defparameter *salt-length* 16
  "Length of the random salt in bytes.")

(defun hash-password (password)
  "Hash PASSWORD using PBKDF2-SHA256. Returns a string encoding
the salt and derived key in hex, separated by a colon."
  (let* ((salt (ironclad:random-data *salt-length*))
         (key (ironclad:derive-key
               (ironclad:make-kdf :pbkdf2 :digest :sha256)
               (ironclad:ascii-string-to-byte-array password)
               salt
               *pbkdf2-iterations*
               *pbkdf2-key-length*)))
    (format nil "~A:~A"
            (ironclad:byte-array-to-hex-string salt)
            (ironclad:byte-array-to-hex-string key))))

(defun verify-password (password hash-string)
  "Verify PASSWORD against a stored HASH-STRING (salt:key in hex).
Returns T if the password matches."
  (let* ((colon (position #\: hash-string))
         (salt-hex (subseq hash-string 0 colon))
         (key-hex (subseq hash-string (1+ colon)))
         (salt (ironclad:hex-string-to-byte-array salt-hex))
         (stored-key (ironclad:hex-string-to-byte-array key-hex))
         (derived-key (ironclad:derive-key
                       (ironclad:make-kdf :pbkdf2 :digest :sha256)
                       (ironclad:ascii-string-to-byte-array password)
                       salt
                       *pbkdf2-iterations*
                       *pbkdf2-key-length*)))
    (equalp derived-key stored-key)))

;;; -------------------------------------------------------
;;; Core API
;;; -------------------------------------------------------

(defun create (username &key password fields)
  "Create a new user with USERNAME and optional PASSWORD and FIELDS.
PASSWORD is hashed before storage. FIELDS is an alist of string key-value pairs.
Returns the user's database ID.
Signals USER-ALREADY-EXISTS if the username is taken."
  (when (%get-user-row username)
    (error 'user-already-exists
           :username username
           :message (format nil "User already exists: ~A" username)))
  (let* ((pw-hash (when password (hash-password password)))
         (user-id (db:insert *users-table*
                              `(("username" . ,username)
                                ("password_hash" . ,(or pw-hash ""))))))
    ;; Store extensible fields
    (dolist (pair fields)
      (db:insert *user-fields-table*
                 `(("user_id" . ,user-id)
                   ("field_name" . ,(car pair))
                   ("field_value" . ,(cdr pair)))))
    ;; Apply default permissions
    (dolist (perm *default-permissions*)
      (%grant-permission user-id perm))
    user-id))

(defun remove (username)
  "Remove a user and all associated fields and permissions.
Signals USER-NOT-FOUND if the user does not exist."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (let ((uid (%row-id row)))
      ;; Remove fields, permissions, then user
      (db:remove *user-fields-table*
                 (q:compile-query `(:= user_id ,uid)))
      (db:remove *permissions-table*
                 (q:compile-query `(:= user_id ,uid)))
      (db:remove *users-table*
                 (q:compile-query `(:= _id ,uid))))))

(defun get (username)
  "Get a user record as an alist by USERNAME.
Returns an alist with \"_id\", \"username\", \"password_hash\" keys, or NIL."
  (%get-user-row username))

(defun list-users ()
  "Return a list of all user records (alists)."
  (db:select *users-table* (q:compile-query :all)))

(defun user-id (user-or-username)
  "Return the database ID of a user. Accepts a user alist or username string."
  (etypecase user-or-username
    (string (let ((row (%get-user-row user-or-username)))
              (when row (%row-id row))))
    (cons (%row-id user-or-username))))

(defun user-username (user-alist)
  "Return the username from a user alist."
  (cdr (assoc "username" user-alist :test #'string=)))

(defun user-password-hash (user-alist)
  "Return the password hash from a user alist."
  (or (cdr (assoc "password-hash" user-alist :test #'string=))
      (cdr (assoc "password_hash" user-alist :test #'string=))))

(defun user= (a b)
  "Return T if two user references identify the same user.
Accepts user alists or username strings."
  (let ((id-a (user-id a))
        (id-b (user-id b)))
    (and id-a id-b (eql id-a id-b))))

;;; -------------------------------------------------------
;;; Extensible fields (EAV pattern)
;;; -------------------------------------------------------

(defun fields (username)
  "Return all extensible fields for USERNAME as an alist.
Signals USER-NOT-FOUND if the user does not exist."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (let* ((uid (%row-id row))
           (rows (db:select *user-fields-table*
                            (q:compile-query `(:= user_id ,uid)))))
      (mapcar (lambda (r)
                (cons (cdr (assoc "field_name" r :test #'string=))
                      (cdr (assoc "field_value" r :test #'string=))))
              rows))))

(defun field (username field-name)
  "Return the value of FIELD-NAME for USERNAME, or NIL if not set."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (let* ((uid (%row-id row))
           (result (db:select-one
                    *user-fields-table*
                    (q:compile-query `(:and (:= user_id ,uid)
                                            (:= field_name ,field-name))))))
      (when result
        (cdr (assoc "field_value" result :test #'string=))))))

(defun set-field (username field-name value)
  "Set FIELD-NAME to VALUE for USERNAME.
Creates the field if it does not exist, updates if it does."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (let* ((uid (%row-id row))
           (existing (db:select-one
                      *user-fields-table*
                      (q:compile-query `(:and (:= user_id ,uid)
                                              (:= field_name ,field-name))))))
      (if existing
          (db:update *user-fields-table*
                     (q:compile-query `(:and (:= user_id ,uid)
                                             (:= field_name ,field-name)))
                     `(("field_value" . ,value)))
          (db:insert *user-fields-table*
                     `(("user_id" . ,uid)
                       ("field_name" . ,field-name)
                       ("field_value" . ,value)))))))

(defun remove-field (username field-name)
  "Remove FIELD-NAME from USERNAME's extensible fields."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (let ((uid (%row-id row)))
      (db:remove *user-fields-table*
                 (q:compile-query `(:and (:= user_id ,uid)
                                         (:= field_name ,field-name)))))))

;;; -------------------------------------------------------
;;; Permissions/ACL
;;; -------------------------------------------------------

(defvar *default-permissions* nil
  "List of permission strings automatically granted to new users.
Set before calling user:create to apply defaults.")

(defun add-default-permissions (&rest permissions)
  "Add PERMISSIONS to the default set granted to new users."
  (dolist (p permissions)
    (pushnew p *default-permissions* :test #'string=)))

(defun grant (username permission)
  "Grant PERMISSION to USERNAME. Idempotent."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (%grant-permission (%row-id row) permission)))

(defun revoke (username permission)
  "Revoke PERMISSION from USERNAME. Idempotent."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (let ((uid (%row-id row)))
      (db:remove *permissions-table*
                 (q:compile-query `(:and (:= user_id ,uid)
                                         (:= permission ,permission)))))))

(defun check (username permission)
  "Check if USERNAME has PERMISSION (or a parent of it).
Hierarchical: \"admin.users.edit\" implies \"admin.users\" and \"admin\".
Returns T if granted, NIL otherwise."
  (let ((row (%get-user-row username)))
    (unless row (return-from check nil))
    (let* ((uid (%row-id row))
           (granted (permissions-for-id uid)))
      ;; Check if any granted permission is a prefix of the requested one
      (some (lambda (g)
              (or (string= g permission)
                  ;; g is a prefix: "admin" matches "admin.users.edit"
                  (and (> (length permission) (length g))
                       (string= g (subseq permission 0 (length g)))
                       (char= #\. (char permission (length g))))))
            granted))))

(defun permissions (username)
  "Return a list of all permission strings granted to USERNAME."
  (let ((row (%get-user-row username)))
    (unless row
      (error 'user-not-found
             :username username
             :message (format nil "User not found: ~A" username)))
    (permissions-for-id (%row-id row))))

;;; -------------------------------------------------------
;;; Internal helpers
;;; -------------------------------------------------------

(defun %get-user-row (username)
  "Look up a user by username. Returns the row alist or NIL."
  (db:select-one *users-table*
                 (q:compile-query `(:= username ,username))))

(defun %row-id (row)
  "Extract the _id from a database row alist."
  (cdr (assoc "_id" row :test #'string=)))

(defun %grant-permission (user-id permission)
  "Grant a permission to a user by ID. Idempotent."
  (let ((existing (db:select-one
                   *permissions-table*
                   (q:compile-query `(:and (:= user_id ,user-id)
                                           (:= permission ,permission))))))
    (unless existing
      (db:insert *permissions-table*
                 `(("user_id" . ,user-id)
                   ("permission" . ,permission))))))

(defun permissions-for-id (user-id)
  "Return all permissions for a user by database ID."
  (let ((rows (db:select *permissions-table*
                         (q:compile-query `(:= user_id ,user-id)))))
    (mapcar (lambda (r)
              (cdr (assoc "permission" r :test #'string=)))
            rows)))
