;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Condition hierarchy

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; Generic function declarations for condition readers
;;; -------------------------------------------------------

(defgeneric fluxion-error-message (condition)
  (:documentation "Human-readable error message for the condition."))

(defgeneric session-not-found-id (condition)
  (:documentation "The session-id string that could not be resolved."))

(defgeneric action-dispatch-error-path (condition)
  (:documentation "The URL path of the action that failed."))

(defgeneric action-dispatch-error-cause (condition)
  (:documentation "The underlying error that caused the action dispatch failure."))

(defgeneric component-not-found-id (condition)
  (:documentation "The component-id string that could not be resolved."))

;;; -------------------------------------------------------
;;; Base condition
;;; -------------------------------------------------------

(define-condition fluxion-error (error)
  ((message :initarg :message
            :initform nil
            :reader fluxion-error-message))
  (:report (lambda (c stream)
             (format stream "Fluxion error: ~A"
                     (or (fluxion-error-message c) "(no details)"))))
  (:documentation "Base condition for all Fluxion framework errors."))

;;; -------------------------------------------------------
;;; Session conditions
;;; -------------------------------------------------------

(define-condition session-not-found (fluxion-error)
  ((session-id :initarg :session-id
               :initform nil
               :reader session-not-found-id))
  (:report (lambda (c stream)
             (format stream "Session not found: ~A"
                     (or (session-not-found-id c) "(unknown)"))))
  (:documentation "Signalled when a session ID cannot be resolved."))

;;; -------------------------------------------------------
;;; CSRF conditions
;;; -------------------------------------------------------

(define-condition csrf-validation-error (fluxion-error)
  ()
  (:report (lambda (c stream)
             (declare (ignore c))
             (format stream "CSRF token validation failed")))
  (:documentation "Signalled when a CSRF token is missing or invalid."))

;;; -------------------------------------------------------
;;; Action dispatch conditions
;;; -------------------------------------------------------

(define-condition action-dispatch-error (fluxion-error)
  ((path :initarg :path
         :initform nil
         :reader action-dispatch-error-path)
   (cause :initarg :cause
          :initform nil
          :reader action-dispatch-error-cause))
  (:report (lambda (c stream)
             (format stream "Action dispatch error on ~A~@[: ~A~]"
                     (or (action-dispatch-error-path c) "(unknown)")
                     (action-dispatch-error-cause c))))
  (:documentation "Signalled when an action handler fails."))

;;; -------------------------------------------------------
;;; Component conditions
;;; -------------------------------------------------------

(define-condition component-not-found (fluxion-error)
  ((component-id :initarg :component-id
                 :initform nil
                 :reader component-not-found-id))
  (:report (lambda (c stream)
             (format stream "Component not found: ~A"
                     (or (component-not-found-id c) "(unknown)"))))
  (:documentation "Signalled when a component ID cannot be resolved."))

;;; -------------------------------------------------------
;;; Request parsing conditions
;;; -------------------------------------------------------

(define-condition request-parse-error (fluxion-error)
  ((body :initarg :body
         :initform nil
         :reader request-parse-error-body))
  (:report (lambda (c stream)
             (declare (ignore c))
             (format stream "Failed to parse request body")))
  (:documentation "Signalled when a request body cannot be parsed."))
