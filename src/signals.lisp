;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Server-side signal model (DEPRECATED)
;;;;
;;;; This module is superseded by the Lattice reactive engine
;;;; (cells, computed cells, propagators, transactions) in cells.lisp.
;;;; The signal-store class is retained for backwards compatibility but
;;;; should not be used in new code.  Use make-cell / computed instead.
;;;;
;;;; Note: make-signal-event in events.lisp and client-side signal
;;;; handling (fluxion-get-signal etc.) remain useful for pushing
;;;; lightweight key/value updates to the browser and are unaffected
;;;; by this deprecation.

(in-package #:fluxion.signals)

;;; -------------------------------------------------------
;;; Signal store (DEPRECATED - use Lattice cells instead)
;;; -------------------------------------------------------

(defclass signal-store ()
  ((signals :initform (make-hash-table :test 'equal)
            :accessor %signals
            :documentation "Hash-table mapping signal names (strings) to values.")))

(defmethod print-object ((s signal-store) stream)
  (print-unreadable-object (s stream :type t :identity t)
    (format stream "~D signal~:P" (hash-table-count (%signals s)))))

(defun make-signal-store ()
  "Create a new empty signal store."
  (make-instance 'signal-store))

(defgeneric get-signal (store name)
  (:documentation "Retrieve the value of signal NAME from STORE."))

(defmethod get-signal ((store signal-store) (name string))
  (gethash name (%signals store)))

(defgeneric set-signal (store name value)
  (:documentation "Set the value of signal NAME in STORE to VALUE."))

(defmethod set-signal ((store signal-store) (name string) value)
  (setf (gethash name (%signals store)) value))

(defgeneric signals-to-alist (store)
  (:documentation "Return the contents of STORE as an alist."))

(defmethod signals-to-alist ((store signal-store))
  (let ((result '()))
    (maphash (lambda (k v)
               (push (cons k v) result))
             (%signals store))
    (nreverse result)))

(defgeneric alist-to-signals (store alist)
  (:documentation "Merge an alist of signal name/value pairs into STORE."))

(defmethod alist-to-signals ((store signal-store) (alist list))
  (loop for (name . value) in alist
        do (set-signal store name value))
  store)

(defgeneric merge-signals (store signals-plist)
  (:documentation "Merge a plist of signal name/value pairs into STORE."))

(defmethod merge-signals ((store signal-store) (plist list))
  (loop for (name value) on plist by #'cddr
        do (set-signal store (string name) value))
  store)
