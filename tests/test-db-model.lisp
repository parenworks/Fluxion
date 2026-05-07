;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Data model tests

(in-package #:fluxion.db.tests)

(in-suite :db-model-suite)

;;; -------------------------------------------------------
;;; Hull and field access tests
;;; -------------------------------------------------------

(test model-hull-creation
  "hull creates an empty data model"
  (let ((model (dm:hull "users")))
    (is (string= "users" (dm:model-collection model)))
    (is (null (dm:model-id model)))
    (is (dm:hull-p model))))

(test model-field-set-get
  "Setting and getting fields works"
  (let ((model (dm:hull "users")))
    (setf (dm:model-field model "name") "Alice")
    (setf (dm:model-field model "role") "admin")
    (is (string= "Alice" (dm:model-field model "name")))
    (is (string= "admin" (dm:model-field model "role")))
    (is (not (dm:hull-p model)))))

(test model-fields-list
  "model-fields returns all field names"
  (let ((model (dm:hull "users")))
    (setf (dm:model-field model "name") "Alice")
    (setf (dm:model-field model "role") "admin")
    (let ((fields (dm:model-fields model)))
      (is (= 2 (length fields)))
      (is (member "name" fields :test #'string=))
      (is (member "role" fields :test #'string=)))))

;;; -------------------------------------------------------
;;; Conversion tests
;;; -------------------------------------------------------

(test model-to-alist-basic
  "model-to-alist converts fields to alist"
  (let ((model (dm:hull "users")))
    (setf (dm:model-field model "name") "Alice")
    (let ((alist (dm:model-to-alist model)))
      (is (assoc "name" alist :test #'string=))
      (is (string= "Alice" (cdr (assoc "name" alist :test #'string=)))))))

(test model-to-alist-with-id
  "model-to-alist includes _id when set"
  (let ((model (dm:hull "users")))
    (setf (dm:model-id model) 42)
    (setf (dm:model-field model "name") "Alice")
    (let ((alist (dm:model-to-alist model)))
      (is (= 42 (cdr (assoc "_id" alist :test #'string=)))))))

(test alist-to-model-basic
  "alist-to-model creates a model from an alist"
  (let ((model (dm:alist-to-model "users"
                                   '(("_id" . 1) ("name" . "Alice") ("role" . "admin")))))
    (is (string= "users" (dm:model-collection model)))
    (is (= 1 (dm:model-id model)))
    (is (string= "Alice" (dm:model-field model "name")))
    (is (string= "admin" (dm:model-field model "role")))))

(test alist-to-model-no-id
  "alist-to-model works without _id"
  (let ((model (dm:alist-to-model "users" '(("name" . "test")))))
    (is (null (dm:model-id model)))
    (is (string= "test" (dm:model-field model "name")))))

;;; -------------------------------------------------------
;;; CRUD tests (require database)
;;; -------------------------------------------------------

(test model-insert-and-retrieve
  "Insert a model and retrieve it"
  (with-test-db
    (db:create "users" '((name :text) (role :text)))
    (let ((model (dm:hull "users")))
      (setf (dm:model-field model "name") "Alice")
      (setf (dm:model-field model "role") "admin")
      (dm:insert-model model)
      (is (plusp (dm:model-id model)))
      ;; Retrieve
      (let ((found (dm:get-one "users" (db:query (:= name "Alice")))))
        (is (not (null found)))
        (is (string= "Alice" (dm:model-field found "name")))
        (is (string= "admin" (dm:model-field found "role")))))))

(test model-save-insert
  "Save a new model inserts it"
  (with-test-db
    (db:create "users" '((name :text) (role :text)))
    (let ((model (dm:hull "users")))
      (setf (dm:model-field model "name") "test")
      (setf (dm:model-field model "role") "user")
      (is (dm:model-new-p model))
      (dm:save model)
      (is (not (dm:model-new-p model)))
      (is (plusp (dm:model-id model))))))

(test model-save-update
  "Save an existing model updates it"
  (with-test-db
    (db:create "users" '((name :text) (role :text)))
    (let ((model (dm:hull "users")))
      (setf (dm:model-field model "name") "Alice")
      (setf (dm:model-field model "role") "user")
      (dm:save model)
      ;; Update
      (setf (dm:model-field model "role") "admin")
      (dm:save model)
      ;; Verify
      (let ((found (dm:get-one "users" (db:query (:= name "Alice")))))
        (is (string= "admin" (dm:model-field found "role")))))))

(test model-delete
  "Delete a model removes it from the database"
  (with-test-db
    (db:create "users" '((name :text)))
    (let ((model (dm:hull "users")))
      (setf (dm:model-field model "name") "deleteme")
      (dm:save model)
      (is (= 1 (db:count "users" (db:query :all))))
      (dm:delete-model model)
      (is (= 0 (db:count "users" (db:query :all)))))))

(test model-get-all
  "get-all returns a list of data models"
  (with-test-db
    (db:create "users" '((name :text)))
    (let ((m1 (dm:hull "users"))
          (m2 (dm:hull "users")))
      (setf (dm:model-field m1 "name") "alpha")
      (setf (dm:model-field m2 "name") "beta")
      (dm:save m1)
      (dm:save m2)
      (let ((all (dm:get-all "users" (db:query :all))))
        (is (= 2 (length all)))
        (is (every (lambda (m) (typep m 'dm:data-model)) all))))))

(test model-get-one-not-found
  "get-one returns NIL when no match"
  (with-test-db
    (db:create "users" '((name :text)))
    (let ((found (dm:get-one "users" (db:query (:= name "nonexistent")))))
      (is (null found)))))

(test model-roundtrip
  "A model survives a full insert/select/update/select/delete cycle"
  (with-test-db
    (db:create "items" '((name :text) (value :integer)))
    ;; Insert
    (let ((model (dm:hull "items")))
      (setf (dm:model-field model "name") "roundtrip")
      (setf (dm:model-field model "value") 100)
      (dm:save model)
      (let ((id (dm:model-id model)))
        ;; Select
        (let ((found (dm:get-one "items" (db:query (:= _id id)))))
          (is (= 100 (dm:model-field found "value")))
          ;; Update
          (setf (dm:model-field found "value") 200)
          (dm:save found)
          ;; Re-select
          (let ((updated (dm:get-one "items" (db:query (:= _id id)))))
            (is (= 200 (dm:model-field updated "value")))
            ;; Delete
            (dm:delete-model updated)
            (is (null (dm:get-one "items" (db:query (:= _id id)))))))))))
