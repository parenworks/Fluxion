;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - PostgreSQL backend contract tests
;;;;
;;;; Runs the same contract tests against a local PostgreSQL instance.
;;;; Requires a 'fluxion_test' database accessible by the 'postgres' user.

(in-package #:fluxion.db.tests)

(def-suite :db-pg-suite
  :description "PostgreSQL backend contract tests"
  :in :db-suite)

(in-suite :db-pg-suite)

;;; -------------------------------------------------------
;;; PostgreSQL test fixtures
;;; -------------------------------------------------------

(defun setup-pg-test-db ()
  "Connect a PostgreSQL backend for testing."
  (let ((backend (fluxion.db.postgresql:make-postgresql-backend
                  :database "fluxion_test"
                  :user "postgres"
                  :password ""
                  :host "localhost")))
    (db:connect backend)
    ;; Clean up any leftover test tables
    (dolist (table (db:collections))
      (when (search "test_" table)
        (db:drop table)))))

(defun teardown-pg-test-db ()
  "Clean up and disconnect the PostgreSQL test database."
  (when db:*backend*
    (ignore-errors
      (dolist (table (db:collections))
        (when (search "test_" table)
          (db:drop table))))
    (db:disconnect db:*backend*)))

(defmacro with-pg-test-db (&body body)
  "Execute BODY with a fresh PostgreSQL test database."
  `(progn
     (setup-pg-test-db)
     (unwind-protect (progn ,@body)
       (teardown-pg-test-db))))

;;; -------------------------------------------------------
;;; Connection tests
;;; -------------------------------------------------------

(test pg-connect-disconnect
  "PostgreSQL connect and disconnect cycle works"
  (with-pg-test-db
    (is (db:connected-p db:*backend*))
    (db:disconnect db:*backend*)
    (is (null db:*backend*))))

;;; -------------------------------------------------------
;;; Collection management tests
;;; -------------------------------------------------------

(test pg-create-collection
  "Creating a collection on PostgreSQL succeeds"
  (with-pg-test-db
    (create-test-collection)
    (is (db:collection-exists-p "test_items"))))

(test pg-create-duplicate-error
  "Creating a duplicate collection signals an error"
  (with-pg-test-db
    (create-test-collection)
    (signals db:collection-already-exists
      (create-test-collection))))

(test pg-create-duplicate-ignore
  "Creating a duplicate with :if-exists :ignore is silent"
  (with-pg-test-db
    (create-test-collection)
    (finishes
      (db:create "test_items"
                 '((name :text))
                 :if-exists :ignore))))

(test pg-collections-list
  "collections returns created table names"
  (with-pg-test-db
    (create-test-collection)
    (is (member "test_items" (db:collections) :test #'string=))))

(test pg-drop-collection
  "Dropping a collection removes it"
  (with-pg-test-db
    (create-test-collection)
    (db:drop "test_items")
    (is (not (db:collection-exists-p "test_items")))))

(test pg-empty-collection
  "Empty removes all records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (is (= 5 (db:count "test_items" (db:query :all))))
    (db:empty "test_items")
    (is (= 0 (db:count "test_items" (db:query :all))))))

(test pg-structure
  "Structure returns field definitions"
  (with-pg-test-db
    (create-test-collection)
    (let ((struct (db:collection-structure "test_items")))
      (is (= 4 (length struct)))
      (is (find "name" struct :key #'first :test #'string=))
      (is (find "value" struct :key #'first :test #'string=)))))

(test pg-alter-adds-columns
  "Alter adds missing columns"
  (with-pg-test-db
    (create-test-collection)
    (db:alter "test_items" '((name :text) (value :integer) (description :text)))
    (let ((struct (db:collection-structure "test_items")))
      (is (find "description" struct :key #'first :test #'string=)))))

;;; -------------------------------------------------------
;;; Insert and select tests
;;; -------------------------------------------------------

(test pg-insert-returns-id
  "Insert returns a positive integer ID"
  (with-pg-test-db
    (create-test-collection)
    (let ((id (db:insert "test_items" '(("name" . "test") ("value" . 42)))))
      (is (typep id '(integer 1))))))

(test pg-insert-auto-increment
  "Successive inserts produce increasing IDs"
  (with-pg-test-db
    (create-test-collection)
    (let ((id1 (db:insert "test_items" '(("name" . "a") ("value" . 1))))
          (id2 (db:insert "test_items" '(("name" . "b") ("value" . 2)))))
      (is (< id1 id2)))))

(test pg-select-all
  "Select :all returns all records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all))))
      (is (= 5 (length rows))))))

(test pg-select-equality
  "Select with equality query returns matching records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query (:= name "alpha")))))
      (is (= 1 (length rows)))
      (is (string= "alpha" (cdr (assoc "name" (first rows) :test #'string=)))))))

(test pg-select-comparison
  "Select with comparison returns correct records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query (:> value 30)))))
      (is (= 2 (length rows))))))

(test pg-select-and
  "Select with AND query"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items"
                           (db:query (:and (:= active 1) (:> value 15))))))
      (is (= 2 (length rows))))))

(test pg-select-or
  "Select with OR query"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items"
                           (db:query (:or (:= name "alpha") (:= name "gamma"))))))
      (is (= 2 (length rows))))))

(test pg-select-amount
  "Select with amount limits results"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all) :amount 2)))
      (is (= 2 (length rows))))))

(test pg-select-sort
  "Select with sort orders results"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all)
                           :sort '((value . :desc)))))
      (is (= 50 (cdr (assoc "value" (first rows) :test #'string=))))
      (is (= 10 (cdr (assoc "value" (fifth rows) :test #'string=)))))))

(test pg-select-one
  "select-one returns a single alist or NIL"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((row (db:select-one "test_items" (db:query (:= name "beta")))))
      (is (not (null row)))
      (is (string= "beta" (cdr (assoc "name" row :test #'string=)))))
    (let ((row (db:select-one "test_items" (db:query (:= name "nonexistent")))))
      (is (null row)))))

;;; -------------------------------------------------------
;;; Count tests
;;; -------------------------------------------------------

(test pg-count-all
  "Count :all returns total record count"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (is (= 5 (db:count "test_items" (db:query :all))))))

(test pg-count-filtered
  "Count with query returns matching count"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (is (= 3 (db:count "test_items" (db:query (:= active 1)))))))

;;; -------------------------------------------------------
;;; Update tests
;;; -------------------------------------------------------

(test pg-update-single
  "Update modifies matching records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (db:update "test_items"
               (db:query (:= name "alpha"))
               '(("value" . 999)))
    (let ((row (db:select-one "test_items" (db:query (:= name "alpha")))))
      (is (= 999 (cdr (assoc "value" row :test #'string=)))))))

(test pg-update-multiple
  "Update modifies all matching records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (db:update "test_items"
               (db:query (:= active 0))
               '(("active" . 1)))
    (is (= 5 (db:count "test_items" (db:query (:= active 1)))))))

;;; -------------------------------------------------------
;;; Remove tests
;;; -------------------------------------------------------

(test pg-remove-single
  "Remove deletes matching records"
  (with-pg-test-db
    (create-test-collection)
    (seed-test-data)
    (db:remove "test_items" (db:query (:= name "alpha")))
    (is (= 4 (db:count "test_items" (db:query :all))))))

;;; -------------------------------------------------------
;;; Transaction tests
;;; -------------------------------------------------------

(test pg-transaction-commit
  "Transaction commits on normal return"
  (with-pg-test-db
    (create-test-collection)
    (db:with-transaction ()
      (db:insert "test_items" '(("name" . "tx1") ("value" . 1)))
      (db:insert "test_items" '(("name" . "tx2") ("value" . 2))))
    (is (= 2 (db:count "test_items" (db:query :all))))))

(test pg-transaction-rollback
  "Transaction rolls back on error"
  (with-pg-test-db
    (create-test-collection)
    (ignore-errors
      (db:with-transaction ()
        (db:insert "test_items" '(("name" . "tx1") ("value" . 1)))
        (error "Intentional error for rollback test")))
    (is (= 0 (db:count "test_items" (db:query :all))))))

;;; -------------------------------------------------------
;;; ID handling tests
;;; -------------------------------------------------------

(test pg-record-has-id
  "Selected records include an _id field"
  (with-pg-test-db
    (create-test-collection)
    (db:insert "test_items" '(("name" . "test") ("value" . 1)))
    (let ((row (db:select-one "test_items" (db:query :all))))
      (is (assoc "_id" row :test #'string=))
      (is (plusp (cdr (assoc "_id" row :test #'string=)))))))

(test pg-select-by-id
  "Can select a record by _id"
  (with-pg-test-db
    (create-test-collection)
    (let ((id (db:insert "test_items" '(("name" . "findme") ("value" . 42)))))
      (let ((row (db:select-one "test_items" (db:query (:= _id id)))))
        (is (not (null row)))
        (is (string= "findme" (cdr (assoc "name" row :test #'string=))))))))

;;; -------------------------------------------------------
;;; Data model tests against PostgreSQL
;;; -------------------------------------------------------

(test pg-model-roundtrip
  "Data model roundtrip on PostgreSQL"
  (with-pg-test-db
    (db:create "test_users" '((name :text) (role :text)))
    (let ((model (dm:hull "test_users")))
      (setf (dm:model-field model "name") "Alice")
      (setf (dm:model-field model "role") "admin")
      (dm:save model)
      (is (plusp (dm:model-id model)))
      (let ((found (dm:get-one "test_users" (db:query (:= name "Alice")))))
        (is (not (null found)))
        (is (string= "admin" (dm:model-field found "role")))
        (setf (dm:model-field found "role") "editor")
        (dm:save found)
        (let ((updated (dm:get-one "test_users"
                                    (db:query (:= _id (dm:model-id found))))))
          (is (string= "editor" (dm:model-field updated "role"))))
        (dm:delete-model found)
        (is (null (dm:get-one "test_users"
                               (db:query (:= _id (dm:model-id found))))))))))
