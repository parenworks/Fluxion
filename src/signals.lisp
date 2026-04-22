;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Server-side signal model

(in-package #:fluxion.signals)

;;; -------------------------------------------------------
;;; Signal store
;;; -------------------------------------------------------
;;; A signal store is a simple key/value map that tracks
;;; reactive state.  For v0.1 this is a thin wrapper around
;;; a hash-table.  The propagator/cell model (Lattice) will
;;; replace this in a later version.

(defclass signal-store ()
  ((signals :initform (make-hash-table :test 'equal)
            :accessor %signals
            :documentation "Hash-table mapping signal names (strings) to values.")))

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
