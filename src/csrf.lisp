;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - CSRF token generation

(in-package #:fluxion.server)

;;; -------------------------------------------------------
;;; CSRF token generation
;;; -------------------------------------------------------

(defun generate-csrf-token ()
  "Generate a cryptographically random CSRF token string (32 hex characters)."
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))
