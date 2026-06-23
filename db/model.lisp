;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Data Model
;;;;
;;;; Provides data-model objects for field-level access to database records
;;;; without writing SQL. Equivalent to Radiance's dm: package.
;;;;
;;;; Usage:
;;;;   (let ((user (fxdm:hull "users")))
;;;;     (setf (fxdm:model-field user "name") "Alice")
;;;;     (setf (fxdm:model-field user "role") "admin")
;;;;     (fxdm:insert-model user))
;;;;
;;;;   (let ((users (fxdm:get-all "users" (fxdb:query :all))))
;;;;     (dolist (u users)
;;;;       (format t "~A~%" (fxdm:model-field u "name"))))

(in-package #:fluxion.db.model)

;;; -------------------------------------------------------
;;; Data model class
;;; -------------------------------------------------------

(defclass data-model ()
  ((collection :initarg :collection
               :reader model-collection
               :documentation "The collection (table) this model belongs to.")
   (id :initarg :id
       :initform nil
       :accessor model-id
       :documentation "The record's database ID, or NIL if not yet persisted.")
   (fields :initarg :fields
           :initform (make-hash-table :test 'equal)
           :accessor model-field-table
           :documentation "Hash table of field-name -> value."))
  (:documentation "A database record as a first-class object.
Provides field-level access without SQL."))

(defmethod print-object ((model data-model) stream)
  (print-unreadable-object (model stream :type t)
    (format stream "~A~@[ #~A~]"
            (model-collection model)
            (model-id model))))

;;; -------------------------------------------------------
;;; Constructors
;;; -------------------------------------------------------

(defun hull (collection)
  "Create an empty, unsaved data model for COLLECTION.
This is a blank record ready to have fields set on it."
  (make-instance 'data-model :collection (string collection)))

(defun hull-p (model)
  "Return T if MODEL is an empty hull (no ID and no fields set)."
  (and (null (model-id model))
       (zerop (hash-table-count (model-field-table model)))))

;;; -------------------------------------------------------
;;; Field access
;;; -------------------------------------------------------

(defun model-fields (model)
  "Return a list of field name strings for MODEL."
  (let ((fields nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k fields))
             (model-field-table model))
    (nreverse fields)))

(defun model-field (model field)
  "Get the value of FIELD (string) from MODEL."
  (gethash (string field) (model-field-table model)))

(defun (setf model-field) (value model field)
  "Set the value of FIELD (string) on MODEL."
  (setf (gethash (string field) (model-field-table model)) value))

;;; -------------------------------------------------------
;;; Conversion
;;; -------------------------------------------------------

(defun model-to-alist (model)
  "Convert MODEL's fields to an alist of (field-name . value) pairs.
Includes _id if set."
  (let ((result nil))
    (when (model-id model)
      (push (cons "_id" (model-id model)) result))
    (maphash (lambda (k v)
               (push (cons k v) result))
             (model-field-table model))
    (nreverse result)))

(defun alist-to-model (collection alist)
  "Create a data model for COLLECTION from ALIST.
If ALIST contains an \"_id\" key, it is set as the model ID."
  (let ((model (hull collection))
        (id-val (cdr (assoc "_id" alist :test #'string=))))
    (when id-val
      (setf (model-id model) (fluxion.db:ensure-id id-val)))
    (dolist (pair alist model)
      (unless (string= "_id" (car pair))
        (setf (model-field model (car pair))
              (if (eq (cdr pair) :null) nil (cdr pair)))))))

;;; -------------------------------------------------------
;;; CRUD operations
;;; -------------------------------------------------------

(defun model-new-p (model)
  "Return T if MODEL has not yet been persisted (no ID)."
  (null (model-id model)))

(defun insert-model (model)
  "Insert MODEL into the database. Sets MODEL's ID from the returned value.
Returns MODEL."
  (let ((data (model-to-alist model)))
    ;; Remove _id from insert data if nil
    (setf data (remove "_id" data :key #'car :test #'string=))
    (let ((new-id (fluxion.db:insert (model-collection model) data)))
      (setf (model-id model) new-id)
      model)))

(defun save (model)
  "Save MODEL to the database.
If the model is new (no ID), inserts it.
If the model has an ID, updates the existing record."
  (if (model-new-p model)
      (insert-model model)
      (let ((data (model-to-alist model)))
        (setf data (remove "_id" data :key #'car :test #'string=))
        (fluxion.db:update (model-collection model)
                           (fluxion.db.query:compile-query
                            `(:= _id ,(model-id model)))
                           data)
        model)))

(defun delete-model (model)
  "Delete MODEL from the database."
  (when (model-id model)
    (fluxion.db:remove (model-collection model)
                       (fluxion.db.query:compile-query
                        `(:= _id ,(model-id model))))))

;;; -------------------------------------------------------
;;; Query wrappers returning data models
;;; -------------------------------------------------------

(defun %row-to-model (collection row)
  "Convert a database row (alist) to a data model."
  (alist-to-model collection row))

(defun get-all (collection query &key fields skip amount sort unique)
  "Select records from COLLECTION matching QUERY, returning data models."
  (mapcar (lambda (row) (%row-to-model collection row))
          (fluxion.db:select collection query
                             :fields fields :skip skip :amount amount
                             :sort sort :unique unique)))

(defun get-one (collection query &key fields)
  "Select a single record from COLLECTION matching QUERY, returning a data model or NIL."
  (let ((row (fluxion.db:select-one collection query :fields fields)))
    (when row
      (%row-to-model collection row))))
