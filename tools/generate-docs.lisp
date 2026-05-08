;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - API documentation generator
;;;;
;;;; Introspects all exported symbols from Fluxion packages and
;;;; generates API.md from docstrings and type information.
;;;;
;;;; Usage:
;;;;   (ql:quickload '(:fluxion :fluxion/client
;;;;                   :fluxion/db-sqlite :fluxion/rdb
;;;;                   :fluxion/session-db :fluxion/user :fluxion/auth
;;;;                   :fluxion/ban :fluxion/rate))
;;;;   (load "tools/generate-docs.lisp")
;;;;   (fluxion.docs:generate)

(defpackage #:fluxion.docs
  (:use #:cl)
  (:export #:generate #:generate-to-string))

(in-package #:fluxion.docs)

;;; -------------------------------------------------------
;;; Configuration
;;; -------------------------------------------------------

(defparameter *packages-to-document*
  '("FLUXION.COMPONENTS" "FLUXION.CELLS" "FLUXION.SERVER"
    "FLUXION.EVENTS" "FLUXION.PROTOCOL" "FLUXION.RENDER"
    "FLUXION.VALIDATION" "FLUXION.HOOKS" "FLUXION.LOG"
    "FLUXION.CLIENT" "FLUXION"
    "FLUXION.DB" "FLUXION.DB.QUERY" "FLUXION.DB.MODEL"
    "FLUXION.RDB" "FLUXION.SESSION.DB"
    "FLUXION.USER" "FLUXION.AUTH"
    "FLUXION.BAN" "FLUXION.RATE"
    "FLUXION.CACHE" "FLUXION.MAIL" "FLUXION.PROFILE"
    "FLUXION.MIGRATE")
  "Packages to include in the generated documentation, in order.")

(defparameter *package-descriptions*
  '(("FLUXION.COMPONENTS" . "Components - CLOS component model, rendering, patching")
    ("FLUXION.CELLS" . "Cells / Lattice - reactive cells, computed cells, propagators, transactions")
    ("FLUXION.SERVER" . "Server - application, sessions, routing, auth, SSE push, conditions")
    ("FLUXION.EVENTS" . "Events - SSE event constructors")
    ("FLUXION.PROTOCOL" . "Protocol - low-level SSE formatting")
    ("FLUXION.RENDER" . "Render - HTML page rendering helpers")
    ("FLUXION.VALIDATION" . "Validation - server-side form validation")
    ("FLUXION.HOOKS" . "Hooks - inter-module event communication with triggers, priorities, and switches")
    ("FLUXION.LOG" . "Log - structured logging with categories and levels")
    ("FLUXION.CLIENT" . "Client - Parenscript runtime compilation")
    ("FLUXION" . "Umbrella Package (fluxion / fx) - re-exports key symbols")
    ("FLUXION.DB" . "Database - backend protocol, connection management, collection CRUD, query DSL")
    ("FLUXION.DB.QUERY" . "Query DSL - s-expression query compiler, SQL generation helpers")
    ("FLUXION.DB.MODEL" . "Data Model - record objects with field access, model-level CRUD")
    ("FLUXION.RDB" . "Relational Extension - joins between collections, raw SQL queries")
    ("FLUXION.SESSION.DB" . "Session Persistence - database-backed session store")
    ("FLUXION.USER" . "User System - accounts, extensible fields, hierarchical permissions")
    ("FLUXION.AUTH" . "Authentication - login/logout, session-to-user binding, hooks")
    ("FLUXION.BAN" . "Ban System - IP-based access control with database persistence")
    ("FLUXION.RATE" . "Rate Limiting - named per-resource limits with per-client tracking")
    ("FLUXION.CACHE" . "Cache - in-memory and persistent caching with TTL expiry")
    ("FLUXION.MAIL" . "Mail - email sending with templates and SMTP support")
    ("FLUXION.PROFILE" . "Profile - request profiling and performance measurement")
    ("FLUXION.MIGRATE" . "Migrate - database schema migrations with version tracking"))
  "Human-readable descriptions for each documented package.")

;;; -------------------------------------------------------
;;; Symbol classification
;;; -------------------------------------------------------

(defun symbol-type (sym)
  "Classify an exported symbol into a category."
  (cond
    ((and (fboundp sym) (typep (fdefinition sym) 'generic-function))
     :generic-function)
    ((and (fboundp sym) (macro-function sym))
     :macro)
    ((fboundp sym)
     :function)
    ((find-class sym nil)
     :class)
    ((boundp sym)
     :variable)
    ;; Check if it's a condition type (defined via define-condition)
    ((ignore-errors (subtypep sym 'condition))
     :condition)
    (t :other)))

(defun symbol-doc (sym type)
  "Get the documentation string for SYM of the given TYPE."
  (case type
    (:generic-function (documentation sym 'function))
    (:function (documentation sym 'function))
    (:macro (documentation sym 'function))
    (:class (documentation (find-class sym) t))
    (:condition (documentation (find-class sym) t))
    (:variable (documentation sym 'variable))
    (t nil)))

(defun function-lambda-list (sym)
  "Get the lambda list for a function or generic function."
  (cond
    ((and (fboundp sym) (typep (fdefinition sym) 'generic-function))
     (sb-mop:generic-function-lambda-list (fdefinition sym)))
    ((and (fboundp sym) (not (macro-function sym)))
     (sb-introspect:function-lambda-list (fdefinition sym)))
    ((macro-function sym)
     (sb-introspect:function-lambda-list (macro-function sym)))
    (t nil)))

(defun format-lambda-list (ll)
  "Format a lambda list as a readable string."
  (if ll
      (format nil "~(~{~A~^ ~}~)" ll)
      ""))

;;; -------------------------------------------------------
;;; Markdown generation
;;; -------------------------------------------------------

(defun write-header (stream)
  (format stream "# Fluxion API Reference~%~%")
  (format stream "Auto-generated from source docstrings.~%~%")
  (format stream "---~%~%"))

(defun write-package-header (stream pkg-name)
  (let ((desc (cdr (assoc pkg-name *package-descriptions* :test #'string=))))
    (format stream "## ~A~%~%" (or desc pkg-name))
    (format stream "Package: `~(~A~)`~%~%" pkg-name)))

(defun write-symbol-entry (stream sym type)
  (let ((doc (symbol-doc sym type))
        (name (string-downcase (symbol-name sym))))
    (case type
      (:class
       (format stream "### Class: `~A`~%~%" name)
       (when doc (format stream "~A~%~%" doc))
       ;; Show slots
       (let ((class (find-class sym nil)))
         (when class
           (ignore-errors
            (sb-mop:finalize-inheritance class)
            (let ((slots (sb-mop:class-direct-slots class)))
              (when slots
                (format stream "Slots:~%~%")
                (dolist (slot slots)
                  (let ((sname (sb-mop:slot-definition-name slot))
                        (sdoc (documentation slot t)))
                    (format stream "- **`~(~A~)`**~@[ - ~A~]~%"
                            sname sdoc)))
                (format stream "~%")))))))

      (:condition
       (format stream "### Condition: `~A`~%~%" name)
       (when doc (format stream "~A~%~%" doc))
       (let ((class (find-class sym nil)))
         (when class
           (handler-bind ((warning #'muffle-warning))
             (ignore-errors
              (sb-mop:finalize-inheritance class)
              (let ((supers (mapcar #'class-name
                                    (sb-mop:class-direct-superclasses class))))
                (when (remove 'condition supers)
                  (format stream "Inherits from: ~{`~(~A~)`~^, ~}~%~%"
                          (remove 'condition supers)))))))))

      (:generic-function
       (let ((ll (function-lambda-list sym)))
         (format stream "**`~A (~A)`**" name (format-lambda-list ll)))
       (when doc (format stream " - ~A" doc))
       (format stream "~%~%"))

      (:function
       (let ((ll (function-lambda-list sym)))
         (format stream "**`~A (~A)`**" name (format-lambda-list ll)))
       (when doc (format stream " - ~A" doc))
       (format stream "~%~%"))

      (:macro
       (let ((ll (function-lambda-list sym)))
         (format stream "**`~A (~A)`** *(macro)*" name (format-lambda-list ll)))
       (when doc (format stream " - ~A" doc))
       (format stream "~%~%"))

      (:variable
       (format stream "**`~A`** *(variable)*" name)
       (when doc (format stream " - ~A" doc))
       (format stream "~%~%"))

      (t
       (format stream "**`~A`**" name)
       (when doc (format stream " - ~A" doc))
       (format stream "~%~%")))))

(defun type-sort-key (type)
  "Sort order for symbol categories."
  (case type
    (:class 0)
    (:condition 1)
    (:generic-function 2)
    (:macro 3)
    (:function 4)
    (:variable 5)
    (t 6)))

(defun collect-symbols (pkg-name)
  "Collect all external symbols from a package with their types."
  (let ((pkg (find-package pkg-name))
        (symbols '()))
    (when pkg
      (do-external-symbols (sym pkg)
        (when (eq (symbol-package sym) pkg)
          (push (cons sym (symbol-type sym)) symbols))))
    ;; Sort by type then name
    (sort symbols (lambda (a b)
                    (let ((ta (type-sort-key (cdr a)))
                          (tb (type-sort-key (cdr b))))
                      (if (= ta tb)
                          (string< (symbol-name (car a))
                                   (symbol-name (car b)))
                          (< ta tb)))))))

(defun type-heading (type)
  (case type
    (:class "Classes")
    (:condition "Conditions")
    (:generic-function "Generic Functions")
    (:macro "Macros")
    (:function "Functions")
    (:variable "Variables")
    (t "Other")))

(defparameter *umbrella-packages*
  '("FLUXION")
  "Packages whose symbols are all re-exports. Documented as a reference table.")

(defun write-umbrella-section (stream pkg-name)
  "Write documentation for an umbrella package as a grouped re-export table."
  (let ((pkg (find-package pkg-name))
        (groups (make-hash-table :test #'equal)))
    (when pkg
      (do-external-symbols (sym pkg)
        (let ((home (package-name (symbol-package sym))))
          (push sym (gethash home groups))))
      (write-package-header stream pkg-name)
      (format stream "This package re-exports symbols from other Fluxion packages ")
      (format stream "for convenience. All symbols below are documented in full ")
      (format stream "under their home package.~%~%")
      (let ((sorted-homes (sort (loop for k being the hash-keys of groups collect k)
                                #'string<)))
        (dolist (home sorted-homes)
          (let ((syms (sort (gethash home groups) #'string< :key #'symbol-name)))
            (format stream "### From `~(~A~)`~%~%" home)
            (dolist (sym syms)
              (format stream "- `~(~A~)`~%" (symbol-name sym)))
            (format stream "~%"))))
      (format stream "---~%~%"))))

;;; -------------------------------------------------------
;;; Client-side JavaScript API extraction
;;; -------------------------------------------------------

(defparameter *client-runtime-path*
  (asdf:system-relative-pathname "fluxion" "client/runtime.lisp")
  "Path to the Parenscript client runtime source.")

(defparameter *public-client-functions*
  '("fluxion-on-navigate" "fluxion-navigated" "fluxion-get-csrf-token"
    "fluxion-get-signal" "fluxion-set-signal" "fluxion-get-all-signals"
    "fluxion-post" "fluxion-bind-actions" "fluxion-collect-params"
    "fluxion-merge-body")
  "Client functions considered public API (Parenscript names).")

(defun ps-name-to-js (name)
  "Convert a Parenscript-style name to camelCase JavaScript name.
E.g. fluxion-bind-actions -> fluxionBindActions"
  (let ((parts (uiop:split-string name :separator "-"))
        (result ""))
    (loop for part in parts
          for i from 0
          do (setf result
                   (concatenate 'string result
                                (if (zerop i)
                                    part
                                    (concatenate 'string
                                                 (string-upcase (subseq part 0 1))
                                                 (subseq part 1))))))
    result))

(defun extract-client-functions ()
  "Parse the Parenscript runtime source and extract public function docs.
Returns a list of (js-name params docstring) tuples."
  (let ((results '()))
    (with-open-file (in *client-runtime-path* :direction :input
                                              :external-format :utf-8)
      (let ((lines (loop for line = (read-line in nil nil)
                         while line collect line)))
        (loop for i from 0 below (length lines)
              for line = (nth i lines)
              when (and (search "(defun fluxion-" line)
                        (not (search "(defun fluxion-handle-" line))
                        (not (search "(defun fluxion-patch-" line))
                        (not (search "(defun fluxion-morph-" line))
                        (not (search "(defun fluxion-sync-" line))
                        (not (search "(defun fluxion-parse-" line))
                        (not (search "(defun fluxion-dispatch-" line))
                        (not (search "(defun fluxion-schedule-" line))
                        (not (search "(defun fluxion-connect-" line))
                        (not (search "(defun fluxion-init" line))
                        (not (search "(defun fluxion-update-" line)))
                do (let* ((trimmed (string-trim " " line))
                          (open-paren (position #\( trimmed :start 7))
                          (name-end (or open-paren (length trimmed)))
                          (ps-name (string-trim " " (subseq trimmed 7 name-end)))
                          (params ""))
                     ;; Extract params from same line or next
                     (when open-paren
                       (let ((close (position #\) trimmed :start open-paren)))
                         (when close
                           (setf params (subseq trimmed (1+ open-paren) close)))))
                     ;; Check if next line is a docstring
                     (let ((docstring nil))
                       (when (< (1+ i) (length lines))
                         (let ((next (string-trim " " (nth (1+ i) lines))))
                           (when (and (plusp (length next))
                                      (char= (char next 0) #\"))
                             (setf docstring
                                   (string-trim "\""
                                                (if (search "\"" next :start2 1)
                                                    next
                                                    next))))))
                       ;; Only include public functions
                       (when (member ps-name *public-client-functions*
                                     :test #'string=)
                         (push (list (ps-name-to-js ps-name) params
                                     (or docstring ""))
                               results)))))))
    (nreverse results)))

(defun write-client-api-section (stream)
  "Write the client-side JavaScript API section."
  (format stream "## Client Runtime (JavaScript)~%~%")
  (format stream "Package: `fluxion.js` (served at `/static/fluxion.js`)~%~%")
  (format stream "These functions are available globally in the browser after ")
  (format stream "loading the Fluxion client runtime.~%~%")
  (format stream "### Functions~%~%")
  (let ((fns (extract-client-functions)))
    (if fns
        (dolist (entry fns)
          (destructuring-bind (js-name params doc) entry
            (format stream "**`~A(~A)`**" js-name params)
            (when (plusp (length doc))
              (format stream " - ~A" doc))
            (format stream "~%~%")))
        (format stream "*No public client functions found.*~%~%")))
  (format stream "### Data Attributes~%~%")
  (format stream "- **`data-on-click`** - URL to POST when element is clicked~%")
  (format stream "- **`data-on-submit`** - URL to POST when form is submitted~%")
  (format stream "- **`data-on-change`** - URL to POST when input value changes~%")
  (format stream "- **`data-on-input`** - URL to POST on each input keystroke~%")
  (format stream "- **`data-on-keydown`** - URL to POST on keydown (filters by data-key)~%")
  (format stream "- **`data-param-*`** - Parameters collected and sent with the POST body~%")
  (format stream "- **`data-bind`** - Two-way signal binding for input elements~%")
  (format stream "- **`data-text`** - One-way text binding from signal to element content~%")
  (format stream "- **`data-confirm`** - Confirmation prompt before executing action~%~%")
  (format stream "### Signals~%~%")
  (format stream "Signals are client-side reactive state that persist across morphs ")
  (format stream "and are automatically included in POST request bodies.~%~%")
  (format stream "---~%~%"))

;;; -------------------------------------------------------
;;; Public API
;;; -------------------------------------------------------

(defun generate-to-string ()
  "Generate API documentation as a string."
  (with-output-to-string (s)
    (write-header s)
    (dolist (pkg-name *packages-to-document*)
      (if (member pkg-name *umbrella-packages* :test #'string=)
          (write-umbrella-section s pkg-name)
          (let ((symbols (collect-symbols pkg-name)))
            (when symbols
              (write-package-header s pkg-name)
              ;; Group by type, skip heading for types that emit their own headings
              (let ((current-type nil))
                (dolist (entry symbols)
                  (let ((sym (car entry))
                        (type (cdr entry)))
                    (unless (eq type current-type)
                      (setf current-type type)
                      (unless (member type '(:class :condition))
                        (format s "### ~A~%~%" (type-heading type))))
                    (write-symbol-entry s sym type))))
              (format s "---~%~%")))))
    ;; Client-side API section
    (write-client-api-section s)))

(defun generate (&key (output-path nil))
  "Generate API.md from live package introspection.
OUTPUT-PATH defaults to the Fluxion project root API.md."
  (let ((path (or output-path
                  (asdf:system-relative-pathname "fluxion" "API.md"))))
    (let ((content (generate-to-string)))
      (with-open-file (out path :direction :output
                                :if-exists :supersede
                                :external-format :utf-8)
        (write-string content out)))
    (format t "~&Generated ~A (~D bytes)~%" path (length (generate-to-string)))
    path))
