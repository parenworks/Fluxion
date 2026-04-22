;;;; -*- encoding:utf-8 -*-
;;;; Tests for fluxion.validation

(in-package #:fluxion.tests)
(in-suite validation-suite)

;;; -------------------------------------------------------
;;; Validation result basics
;;; -------------------------------------------------------

(test validation-result-empty
  "A fresh validation result has no errors."
  (let ((r (fluxion.validation:make-validation-result)))
    (is-true (fluxion.validation:valid-p r))
    (is (null (fluxion.validation:errors-alist r)))))

(test validation-result-add-error
  "Adding an error makes the result invalid."
  (let ((r (fluxion.validation:make-validation-result)))
    (fluxion.validation:add-error r "name" "is required")
    (is-false (fluxion.validation:valid-p r))
    (is (string= "is required" (fluxion.validation:field-error r "name")))))

(test validation-result-first-error-kept
  "Only the first error per field is kept."
  (let ((r (fluxion.validation:make-validation-result)))
    (fluxion.validation:add-error r "name" "first")
    (fluxion.validation:add-error r "name" "second")
    (is (string= "first" (fluxion.validation:field-error r "name")))))

(test validation-result-multiple-fields
  "Errors on different fields are independent."
  (let ((r (fluxion.validation:make-validation-result)))
    (fluxion.validation:add-error r "name" "required")
    (fluxion.validation:add-error r "email" "invalid")
    (is (= 2 (length (fluxion.validation:errors-alist r))))
    (is (string= "required" (fluxion.validation:field-error r "name")))
    (is (string= "invalid" (fluxion.validation:field-error r "email")))))

;;; -------------------------------------------------------
;;; Built-in validators
;;; -------------------------------------------------------

(test validator-required-nil
  "required fails on NIL."
  (let ((v (fluxion.validation:required)))
    (is (stringp (funcall v nil "field")))))

(test validator-required-empty
  "required fails on empty string."
  (let ((v (fluxion.validation:required)))
    (is (stringp (funcall v "" "field")))))

(test validator-required-passes
  "required passes on non-empty string."
  (let ((v (fluxion.validation:required)))
    (is (null (funcall v "hello" "field")))))

(test validator-required-custom-message
  "required uses custom message when provided."
  (let ((v (fluxion.validation:required "Name needed")))
    (is (string= "Name needed" (funcall v "" "field")))))

(test validator-min-length-fails
  "min-length fails when string is too short."
  (let ((v (fluxion.validation:min-length 5)))
    (is (stringp (funcall v "abc" "field")))))

(test validator-min-length-passes
  "min-length passes when string is long enough."
  (let ((v (fluxion.validation:min-length 3)))
    (is (null (funcall v "abc" "field")))))

(test validator-max-length-fails
  "max-length fails when string is too long."
  (let ((v (fluxion.validation:max-length 3)))
    (is (stringp (funcall v "abcdef" "field")))))

(test validator-max-length-passes
  "max-length passes when string is short enough."
  (let ((v (fluxion.validation:max-length 5)))
    (is (null (funcall v "abc" "field")))))

(test validator-email-passes
  "email passes for valid-looking addresses."
  (let ((v (fluxion.validation:email)))
    (is (null (funcall v "user@example.com" "field")))))

(test validator-email-fails
  "email fails for invalid addresses."
  (let ((v (fluxion.validation:email)))
    (is (stringp (funcall v "not-an-email" "field")))
    (is (stringp (funcall v "@missing.local" "field")))))

(test validator-integer-string-passes
  "integer-string passes for numeric strings."
  (let ((v (fluxion.validation:integer-string)))
    (is (null (funcall v "42" "field")))
    (is (null (funcall v "-7" "field")))))

(test validator-integer-string-fails
  "integer-string fails for non-numeric strings."
  (let ((v (fluxion.validation:integer-string)))
    (is (stringp (funcall v "abc" "field")))
    (is (stringp (funcall v "3.14" "field")))))

(test validator-one-of-passes
  "one-of passes when value is in the list."
  (let ((v (fluxion.validation:one-of '("red" "green" "blue"))))
    (is (null (funcall v "red" "field")))))

(test validator-one-of-fails
  "one-of fails when value is not in the list."
  (let ((v (fluxion.validation:one-of '("red" "green" "blue"))))
    (is (stringp (funcall v "yellow" "field")))))

(test validator-predicate-passes
  "predicate passes when fn returns T."
  (let ((v (fluxion.validation:predicate #'stringp)))
    (is (null (funcall v "hello" "field")))))

(test validator-predicate-fails
  "predicate fails when fn returns NIL."
  (let ((v (fluxion.validation:predicate #'integerp)))
    (is (stringp (funcall v "hello" "field")))))

(test validator-matches-pattern-passes
  "matches-pattern passes for matching string."
  (let ((v (fluxion.validation:matches-pattern "^[A-Z]+$")))
    (is (null (funcall v "HELLO" "field")))))

(test validator-matches-pattern-fails
  "matches-pattern fails for non-matching string."
  (let ((v (fluxion.validation:matches-pattern "^[A-Z]+$")))
    (is (stringp (funcall v "hello" "field")))))

;;; -------------------------------------------------------
;;; Validate runner
;;; -------------------------------------------------------

(test validate-all-pass
  "validate returns valid result when all rules pass."
  (let* ((params '(("name" . "Alice") ("email" . "alice@example.com")))
         (result (fluxion.validation:validate params
                   (list (list "name" (fluxion.validation:required))
                         (list "email" (fluxion.validation:required)
                                       (fluxion.validation:email))))))
    (is-true (fluxion.validation:valid-p result))))

(test validate-collects-errors
  "validate collects errors for failing fields."
  (let* ((params '(("name" . "") ("email" . "bad")))
         (result (fluxion.validation:validate params
                   (list (list "name" (fluxion.validation:required))
                         (list "email" (fluxion.validation:email))))))
    (is-false (fluxion.validation:valid-p result))
    (is (stringp (fluxion.validation:field-error result "name")))
    (is (stringp (fluxion.validation:field-error result "email")))))

(test validate-stops-at-first-error-per-field
  "validate only reports the first failing validator per field."
  (let* ((params '(("name" . "")))
         (result (fluxion.validation:validate params
                   (list (list "name"
                               (fluxion.validation:required "first")
                               (fluxion.validation:min-length 5 "second"))))))
    (is (string= "first" (fluxion.validation:field-error result "name")))))

(test validate-missing-field
  "validate treats missing fields as NIL values."
  (let* ((params '(("other" . "value")))
         (result (fluxion.validation:validate params
                   (list (list "name" (fluxion.validation:required))))))
    (is-false (fluxion.validation:valid-p result))))

;;; -------------------------------------------------------
;;; Error event generation
;;; -------------------------------------------------------

(test validation-error-events-generates-patches
  "validation-error-events produces patch events for errored fields."
  (let ((result (fluxion.validation:make-validation-result)))
    (fluxion.validation:add-error result "name" "required")
    (let ((events (fluxion.validation:validation-error-events result)))
      (is (= 1 (length events))))))

(test validation-error-events-empty-for-valid
  "validation-error-events returns empty list for valid result."
  (let ((result (fluxion.validation:make-validation-result)))
    (is (null (fluxion.validation:validation-error-events result)))))

(test clear-error-events-generates-patches
  "clear-error-events produces patch events to clear fields."
  (let ((events (fluxion.validation:clear-error-events '("name" "email"))))
    (is (= 2 (length events)))))
