;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Form validation helpers

(in-package #:fluxion.validation)

;;; -------------------------------------------------------
;;; Validation result
;;; -------------------------------------------------------

(defclass validation-result ()
  ((errors :initform (make-hash-table :test 'equal)
           :accessor validation-errors
           :documentation "Hash table mapping field name strings to error message strings."))
  (:documentation "Container for validation errors from a set of rules."))

(defun make-validation-result ()
  "Create an empty validation result."
  (make-instance 'validation-result))

(defun add-error (result field message)
  "Add an error MESSAGE for FIELD to RESULT. Only the first error per field is kept."
  (let ((errors (validation-errors result)))
    (unless (gethash field errors)
      (setf (gethash field errors) message)))
  result)

(defun field-error (result field)
  "Return the error message for FIELD, or NIL if the field is valid."
  (gethash field (validation-errors result)))

(defun valid-p (result)
  "Return T if RESULT has no validation errors."
  (zerop (hash-table-count (validation-errors result))))

(defun errors-alist (result)
  "Return the errors as an alist of (field . message) pairs."
  (let ((pairs nil))
    (maphash (lambda (k v) (push (cons k v) pairs))
             (validation-errors result))
    (nreverse pairs)))

(defun errors-plist (result)
  "Return the errors as a plist (:field message ...)."
  (let ((plist nil))
    (maphash (lambda (k v)
               (push v plist)
               (push (intern (string-upcase k) :keyword) plist))
             (validation-errors result))
    plist))

;;; -------------------------------------------------------
;;; Built-in validators
;;; -------------------------------------------------------
;;; Each validator is a function that takes (value field-name)
;;; and returns an error message string or NIL.

(defun required (&optional message)
  "Validator: field must be present and non-empty."
  (lambda (value field)
    (declare (ignore field))
    (if (or (null value)
            (and (stringp value) (string= value "")))
        (or message "This field is required")
        nil)))

(defun min-length (n &optional message)
  "Validator: string must be at least N characters."
  (lambda (value field)
    (declare (ignore field))
    (when (and (stringp value) (< (length value) n))
      (or message (format nil "Must be at least ~D characters" n)))))

(defun max-length (n &optional message)
  "Validator: string must be at most N characters."
  (lambda (value field)
    (declare (ignore field))
    (when (and (stringp value) (> (length value) n))
      (or message (format nil "Must be at most ~D characters" n)))))

(defun matches-pattern (regex &optional message)
  "Validator: string must match REGEX (a CL-PPCRE pattern).
Returns the error message if the value does not match."
  (lambda (value field)
    (declare (ignore field))
    (when (and (stringp value)
               (not (cl-ppcre:scan regex value)))
      (or message "Invalid format"))))

(defun email (&optional message)
  "Validator: value must look like an email address."
  (matches-pattern "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"
                   (or message "Must be a valid email address")))

(defun integer-string (&optional message)
  "Validator: value must be a string that parses as an integer."
  (lambda (value field)
    (declare (ignore field))
    (when (and (stringp value)
               (not (ignore-errors (parse-integer value))))
      (or message "Must be a whole number"))))

(defun number-string (&optional message)
  "Validator: value must be a string that parses as a number."
  (lambda (value field)
    (declare (ignore field))
    (when (and (stringp value)
               (not (ignore-errors (read-from-string value))))
      (or message "Must be a number"))))

(defun one-of (choices &optional message)
  "Validator: value must be one of CHOICES (list of strings)."
  (lambda (value field)
    (declare (ignore field))
    (when (and (stringp value)
               (not (member value choices :test #'string=)))
      (or message (format nil "Must be one of: ~{~A~^, ~}" choices)))))

(defun predicate (fn &optional message)
  "Validator: custom predicate. FN takes a value and returns T if valid."
  (lambda (value field)
    (declare (ignore field))
    (unless (funcall fn value)
      (or message "Invalid value"))))

(defun confirmed (params confirm-field &optional message)
  "Validator: value must match the value of CONFIRM-FIELD in PARAMS.
Useful for password confirmation."
  (lambda (value field)
    (declare (ignore field))
    (let ((confirm-value (cdr (assoc confirm-field params :test #'string=))))
      (unless (equal value confirm-value)
        (or message "Does not match")))))

;;; -------------------------------------------------------
;;; Validation runner
;;; -------------------------------------------------------

(defun validate (params rules)
  "Validate PARAMS (an alist) against RULES.
RULES is a list of (field-name validator1 validator2 ...) lists.
FIELD-NAME is a string matching a key in PARAMS.
Each validator is a function returned by required, min-length, etc.

Returns a VALIDATION-RESULT. Use VALID-P to check if validation passed.

Example:
  (validate params
    (list (list \"username\" (required) (min-length 3))
          (list \"email\"    (required) (email))))"
  (let ((result (make-validation-result)))
    (dolist (rule rules)
      (destructuring-bind (field &rest validators) rule
        (let ((value (cdr (assoc field params :test #'string=))))
          (dolist (validator validators)
            (let ((error-msg (funcall validator value field)))
              (when error-msg
                (add-error result field error-msg)
                ;; Stop at first error for this field
                (return)))))))
    result))

;;; -------------------------------------------------------
;;; Error feedback to client
;;; -------------------------------------------------------

(defun validation-error-events (result &key (selector-fn nil) (class "field-error"))
  "Generate SSE patch events to display validation errors in the DOM.
For each field with an error, patches an element with the error message.

SELECTOR-FN is an optional function (field-name) -> CSS selector.
Defaults to \"#error-{field-name}\".

CLASS is the CSS class added to the error element (default: \"field-error\").

Returns a list of SSE events suitable for returning from an action handler."
  (let ((events nil)
        (sel-fn (or selector-fn
                    (lambda (field)
                      (format nil "#error-~A" field)))))
    (maphash (lambda (field message)
               (push (fluxion.events:make-patch-event
                      (funcall sel-fn field)
                      (format nil "<span class=\"~A\">~A</span>"
                              class
                              message)
                      :mode "replace")
                     events))
             (validation-errors result))
    (nreverse events)))

(defun clear-error-events (fields &key (selector-fn nil))
  "Generate SSE patch events to clear error messages for FIELDS.
FIELDS is a list of field name strings.
SELECTOR-FN works the same as in VALIDATION-ERROR-EVENTS."
  (let ((events nil)
        (sel-fn (or selector-fn
                    (lambda (field)
                      (format nil "#error-~A" field)))))
    (dolist (field fields)
      (push (fluxion.events:make-patch-event
             (funcall sel-fn field)
             (format nil "<span></span>")
             :mode "replace")
            events))
    (nreverse events)))
