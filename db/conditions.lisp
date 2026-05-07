;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Conditions
;;;;
;;;; All database-related conditions. These are signalled by backends
;;;; and can be handled by application code.

(in-package #:fluxion.db)

;;; Base condition

(define-condition database-error (error)
  ((message :initarg :message
            :initform "Database error"
            :reader database-error-message))
  (:report (lambda (c s)
             (format s "Database error: ~A" (database-error-message c)))))

;;; Connection conditions

(define-condition connection-failed (database-error)
  ()
  (:report (lambda (c s)
             (format s "Connection failed: ~A" (database-error-message c)))))

(define-condition connection-already-open (warning)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "Database connection is already open"))))

;;; Collection conditions

(define-condition collection-error (database-error)
  ((name :initarg :name
         :reader collection-error-name))
  (:report (lambda (c s)
             (format s "Collection error on ~S: ~A"
                     (collection-error-name c)
                     (database-error-message c)))))

(define-condition invalid-collection (collection-error)
  ()
  (:report (lambda (c s)
             (format s "Collection ~S does not exist"
                     (collection-error-name c)))))

(define-condition collection-already-exists (collection-error)
  ()
  (:report (lambda (c s)
             (format s "Collection ~S already exists"
                     (collection-error-name c)))))

;;; Field conditions

(define-condition invalid-field (database-error)
  ((name :initarg :name
         :reader invalid-field-name))
  (:report (lambda (c s)
             (format s "Invalid field ~S" (invalid-field-name c)))))
