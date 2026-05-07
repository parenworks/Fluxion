;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Profile system
;;;;
;;;; Extensible user profiles layered on top of fluxion.user.
;;;; Provides structured profile fields with types and visibility,
;;;; display name management, avatar support (Gravatar), and
;;;; an extensible panel registration system.
;;;;
;;;; Usage:
;;;;   (profile:set-display-name "alice" "Alice Smith")
;;;;   (profile:display-name "alice")
;;;;   (profile:avatar-url "alice" :size 80)
;;;;   (profile:define-field "bio" :type :text :visibility :public)
;;;;   (profile:set "alice" "bio" "I write Lisp.")

(defpackage #:fluxion.profile
  (:use #:cl)
  (:shadow #:get #:set #:remove)
  (:local-nicknames (#:user #:fluxion.user))
  (:export
   ;; Display name
   #:display-name
   #:set-display-name
   ;; Avatar
   #:avatar-url
   #:*default-avatar-size*
   ;; Profile fields
   #:define-field
   #:undefine-field
   #:defined-fields
   #:field-definition
   ;; Per-user field values
   #:get
   #:set
   #:remove
   #:all-fields
   #:public-fields
   ;; Panels
   #:define-panel
   #:undefine-panel
   #:panels
   #:panel-definition))

(in-package #:fluxion.profile)

;;; -------------------------------------------------------
;;; Field definitions (schema)
;;; -------------------------------------------------------

(defstruct field-def
  "Definition of a profile field."
  (name "" :type string)
  (type :text :type keyword)
  (visibility :public :type keyword)
  (label nil :type (or null string))
  (validator nil :type (or null function)))

(defvar *field-definitions* (make-hash-table :test 'equal)
  "Registry of defined profile fields. Keys are field name strings.")

(defun define-field (name &key (type :text) (visibility :public) label validator)
  "Define a profile field that users can populate.
TYPE is one of :text, :url, :date, :boolean, :integer.
VISIBILITY is :public or :private.
LABEL is a human-readable name (defaults to NAME).
VALIDATOR is an optional function that receives a value and returns T if valid."
  (setf (gethash name *field-definitions*)
        (make-field-def :name name
                        :type type
                        :visibility visibility
                        :label (or label name)
                        :validator validator)))

(defun undefine-field (name)
  "Remove a profile field definition."
  (remhash name *field-definitions*))

(defun defined-fields ()
  "Return a list of all defined field definitions."
  (let ((result '()))
    (maphash (lambda (k v)
               (declare (ignore k))
               (push v result))
             *field-definitions*)
    (sort result #'string< :key #'field-def-name)))

(defun field-definition (name)
  "Return the field-def for NAME, or NIL."
  (gethash name *field-definitions*))

;;; -------------------------------------------------------
;;; Display name
;;; -------------------------------------------------------

(defun display-name (username)
  "Return the display name for USERNAME.
Falls back to the username itself if no display name is set."
  (or (user:field username "display_name")
      username))

(defun set-display-name (username name)
  "Set the display name for USERNAME."
  (user:set-field username "display_name" name))

;;; -------------------------------------------------------
;;; Avatar (Gravatar)
;;; -------------------------------------------------------

(defvar *default-avatar-size* 80
  "Default avatar size in pixels.")

(defun md5-hex (string)
  "Return the MD5 hex digest of STRING (lowercased, trimmed)."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline) (string-downcase string)))
         (bytes (babel:string-to-octets trimmed :encoding :utf-8))
         (digest (ironclad:digest-sequence :md5 bytes)))
    (ironclad:byte-array-to-hex-string digest)))

(defun avatar-url (username &key (size *default-avatar-size*) (default "identicon"))
  "Return a Gravatar URL for USERNAME.
Uses the user's email field if available, otherwise hashes the username.
SIZE is the image size in pixels. DEFAULT is the fallback image type."
  (let* ((email (user:field username "email"))
         (hash (md5-hex (or email username))))
    (format nil "https://www.gravatar.com/avatar/~A?s=~D&d=~A"
            hash size default)))

;;; -------------------------------------------------------
;;; Per-user field values (stored via fluxion.user fields)
;;; -------------------------------------------------------

(defun field-key (name)
  "Prefix a profile field name for storage in the user fields table."
  (format nil "profile.~A" name))

(defun get (username field-name)
  "Get the value of a profile field for USERNAME."
  (user:field username (field-key field-name)))

(defun set (username field-name value)
  "Set a profile field for USERNAME. Validates if a validator is defined."
  (let ((def (field-definition field-name)))
    (when (and def (field-def-validator def))
      (unless (funcall (field-def-validator def) value)
        (error "Invalid value for profile field ~S: ~S" field-name value))))
  (user:set-field username (field-key field-name) (princ-to-string value)))

(defun remove (username field-name)
  "Remove a profile field value for USERNAME."
  (user:remove-field username (field-key field-name)))

(defun all-fields (username)
  "Return an alist of all profile field values for USERNAME.
Keys are field names (without the profile. prefix)."
  (let ((prefix "profile.")
        (result '()))
    (dolist (pair (user:fields username))
      (let ((key (car pair)))
        (when (and (> (length key) (length prefix))
                   (string= prefix key :end2 (length prefix)))
          (push (cons (subseq key (length prefix)) (cdr pair)) result))))
    (nreverse result)))

(defun public-fields (username)
  "Return an alist of public profile fields for USERNAME.
Only includes fields that have a definition with :public visibility."
  (let ((all (all-fields username)))
    (cl:remove-if-not
     (lambda (pair)
       (let ((def (field-definition (car pair))))
         (and def (eq (field-def-visibility def) :public))))
     all)))

;;; -------------------------------------------------------
;;; Panels (extensible profile sections)
;;; -------------------------------------------------------

(defstruct panel-def
  "A registered profile panel."
  (name "" :type string)
  (label "" :type string)
  (order 0 :type integer)
  (renderer nil :type (or null function)))

(defvar *panel-definitions* (make-hash-table :test 'equal)
  "Registry of profile panels.")

(defun define-panel (name &key (label name) (order 0) renderer)
  "Register a profile panel.
NAME is a unique string identifier.
LABEL is the human-readable title.
ORDER controls display ordering (lower first).
RENDERER is a function (username) -> HTML string."
  (setf (gethash name *panel-definitions*)
        (make-panel-def :name name
                        :label label
                        :order order
                        :renderer renderer)))

(defun undefine-panel (name)
  "Remove a profile panel definition."
  (remhash name *panel-definitions*))

(defun panels ()
  "Return all registered panel definitions, sorted by order."
  (let ((result '()))
    (maphash (lambda (k v)
               (declare (ignore k))
               (push v result))
             *panel-definitions*)
    (sort result #'< :key #'panel-def-order)))

(defun panel-definition (name)
  "Return the panel-def for NAME, or NIL."
  (gethash name *panel-definitions*))
