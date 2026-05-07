;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Backend contract tests
;;;;
;;;; These tests verify that a backend correctly implements the full
;;;; database contract. They run against whatever backend is active.
;;;; The default setup uses SQLite in-memory for speed.

(in-package #:fluxion.db.tests)

(in-suite :db-contract-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defun setup-test-db ()
  "Connect an in-memory SQLite backend for testing."
  (let ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:")))
    (db:connect backend)))

(defun teardown-test-db ()
  "Disconnect the test database."
  (when db:*backend*
    (db:disconnect db:*backend*)))

(defmacro with-test-db (&body body)
  "Execute BODY with a fresh in-memory SQLite database."
  `(progn
     (setup-test-db)
     (unwind-protect (progn ,@body)
       (teardown-test-db))))

(defun create-test-collection ()
  "Create a standard test collection."
  (db:create "test_items"
             '((name :text)
               (value :integer)
               (active :boolean)
               (score :float))))

(defun seed-test-data ()
  "Insert test data into test_items."
  (db:insert "test_items" '(("name" . "alpha") ("value" . 10) ("active" . 1) ("score" . 3.5)))
  (db:insert "test_items" '(("name" . "beta") ("value" . 20) ("active" . 1) ("score" . 7.2)))
  (db:insert "test_items" '(("name" . "gamma") ("value" . 30) ("active" . 0) ("score" . 1.8)))
  (db:insert "test_items" '(("name" . "delta") ("value" . 40) ("active" . 1) ("score" . 9.1)))
  (db:insert "test_items" '(("name" . "epsilon") ("value" . 50) ("active" . 0) ("score" . 5.0))))

;;; -------------------------------------------------------
;;; Connection tests
;;; -------------------------------------------------------

(test contract-connect-disconnect
  "Connect and disconnect cycle works"
  (with-test-db
    (is (db:connected-p db:*backend*))
    (db:disconnect db:*backend*)
    (is (null db:*backend*))))

(test contract-no-backend-error
  "Operations without a backend signal an error"
  (let ((db:*backend* nil))
    (signals db:connection-failed
      (db:collections))))

;;; -------------------------------------------------------
;;; Collection management tests
;;; -------------------------------------------------------

(test contract-create-collection
  "Creating a collection succeeds"
  (with-test-db
    (create-test-collection)
    (is (db:collection-exists-p "test_items"))))

(test contract-create-duplicate-error
  "Creating a duplicate collection signals an error by default"
  (with-test-db
    (create-test-collection)
    (signals db:collection-already-exists
      (create-test-collection))))

(test contract-create-duplicate-ignore
  "Creating a duplicate with :if-exists :ignore is silent"
  (with-test-db
    (create-test-collection)
    (finishes
      (db:create "test_items"
                 '((name :text))
                 :if-exists :ignore))))

(test contract-collections-list
  "collections returns created table names"
  (with-test-db
    (create-test-collection)
    (is (member "test_items" (db:collections) :test #'string=))))

(test contract-drop-collection
  "Dropping a collection removes it"
  (with-test-db
    (create-test-collection)
    (db:drop "test_items")
    (is (not (db:collection-exists-p "test_items")))))

(test contract-drop-nonexistent-error
  "Dropping a nonexistent collection signals an error"
  (with-test-db
    (signals db:invalid-collection
      (db:drop "nonexistent"))))

(test contract-empty-collection
  "Empty removes all records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (is (= 5 (db:count "test_items" (db:query :all))))
    (db:empty "test_items")
    (is (= 0 (db:count "test_items" (db:query :all))))))

(test contract-structure
  "Structure returns field definitions"
  (with-test-db
    (create-test-collection)
    (let ((struct (db:collection-structure "test_items")))
      (is (= 4 (length struct)))
      (is (find "name" struct :key #'first :test #'string=))
      (is (find "value" struct :key #'first :test #'string=)))))

(test contract-alter-adds-columns
  "Alter adds missing columns"
  (with-test-db
    (create-test-collection)
    (db:alter "test_items" '((name :text) (value :integer) (description :text)))
    (let ((struct (db:collection-structure "test_items")))
      (is (find "description" struct :key #'first :test #'string=)))))

;;; -------------------------------------------------------
;;; Insert and select tests
;;; -------------------------------------------------------

(test contract-insert-returns-id
  "Insert returns a positive integer ID"
  (with-test-db
    (create-test-collection)
    (let ((id (db:insert "test_items" '(("name" . "test") ("value" . 42)))))
      (is (typep id '(integer 1))))))

(test contract-insert-auto-increment
  "Successive inserts produce increasing IDs"
  (with-test-db
    (create-test-collection)
    (let ((id1 (db:insert "test_items" '(("name" . "a") ("value" . 1))))
          (id2 (db:insert "test_items" '(("name" . "b") ("value" . 2)))))
      (is (< id1 id2)))))

(test contract-select-all
  "Select :all returns all records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all))))
      (is (= 5 (length rows))))))

(test contract-select-equality
  "Select with equality query returns matching records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query (:= name "alpha")))))
      (is (= 1 (length rows)))
      (is (string= "alpha" (cdr (assoc "name" (first rows) :test #'string=)))))))

(test contract-select-comparison
  "Select with comparison returns correct records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query (:> value 30)))))
      (is (= 2 (length rows))))))

(test contract-select-and
  "Select with AND query"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items"
                           (db:query (:and (:= active 1) (:> value 15))))))
      (is (= 2 (length rows))))))

(test contract-select-or
  "Select with OR query"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items"
                           (db:query (:or (:= name "alpha") (:= name "gamma"))))))
      (is (= 2 (length rows))))))

(test contract-select-like
  "Select with LIKE query"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items"
                           (db:query (:like name "%a%")))))
      ;; alpha, beta, gamma, delta all contain 'a'
      (is (>= (length rows) 4)))))

(test contract-select-fields
  "Select with specific fields"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all) :fields '(name))))
      (is (= 5 (length rows)))
      ;; Each row should have the name field
      (is (assoc "name" (first rows) :test #'string=)))))

(test contract-select-amount
  "Select with amount limits results"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all) :amount 2)))
      (is (= 2 (length rows))))))

(test contract-select-skip
  "Select with skip offsets results"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all) :skip 3 :amount 10)))
      (is (= 2 (length rows))))))

(test contract-select-sort
  "Select with sort orders results"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((rows (db:select "test_items" (db:query :all)
                           :sort '((value . :desc)))))
      (is (= 50 (cdr (assoc "value" (first rows) :test #'string=))))
      (is (= 10 (cdr (assoc "value" (fifth rows) :test #'string=)))))))

(test contract-select-one
  "select-one returns a single alist or NIL"
  (with-test-db
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

(test contract-count-all
  "Count :all returns total record count"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (is (= 5 (db:count "test_items" (db:query :all))))))

(test contract-count-filtered
  "Count with query returns matching count"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (is (= 3 (db:count "test_items" (db:query (:= active 1)))))))

;;; -------------------------------------------------------
;;; Update tests
;;; -------------------------------------------------------

(test contract-update-single
  "Update modifies matching records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (db:update "test_items"
               (db:query (:= name "alpha"))
               '(("value" . 999)))
    (let ((row (db:select-one "test_items" (db:query (:= name "alpha")))))
      (is (= 999 (cdr (assoc "value" row :test #'string=)))))))

(test contract-update-multiple
  "Update modifies all matching records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (db:update "test_items"
               (db:query (:= active 0))
               '(("active" . 1)))
    (is (= 5 (db:count "test_items" (db:query (:= active 1)))))))

;;; -------------------------------------------------------
;;; Remove tests
;;; -------------------------------------------------------

(test contract-remove-single
  "Remove deletes matching records"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (db:remove "test_items" (db:query (:= name "alpha")))
    (is (= 4 (db:count "test_items" (db:query :all))))))

(test contract-remove-filtered
  "Remove with compound query"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (db:remove "test_items" (db:query (:= active 0)))
    (is (= 3 (db:count "test_items" (db:query :all))))))

;;; -------------------------------------------------------
;;; Iterate tests
;;; -------------------------------------------------------

(test contract-iterate
  "Iterate calls function for each matching record"
  (with-test-db
    (create-test-collection)
    (seed-test-data)
    (let ((names nil))
      (db:iterate "test_items" (db:query :all)
                  (lambda (row)
                    (push (cdr (assoc "name" row :test #'string=)) names)))
      (is (= 5 (length names))))))

;;; -------------------------------------------------------
;;; Transaction tests
;;; -------------------------------------------------------

(test contract-transaction-commit
  "Transaction commits on normal return"
  (with-test-db
    (create-test-collection)
    (db:with-transaction ()
      (db:insert "test_items" '(("name" . "tx1") ("value" . 1)))
      (db:insert "test_items" '(("name" . "tx2") ("value" . 2))))
    (is (= 2 (db:count "test_items" (db:query :all))))))

(test contract-transaction-rollback
  "Transaction rolls back on error"
  (with-test-db
    (create-test-collection)
    (ignore-errors
      (db:with-transaction ()
        (db:insert "test_items" '(("name" . "tx1") ("value" . 1)))
        (error "Intentional error for rollback test")))
    (is (= 0 (db:count "test_items" (db:query :all))))))

;;; -------------------------------------------------------
;;; ID handling tests
;;; -------------------------------------------------------

(test contract-record-has-id
  "Selected records include an _id field"
  (with-test-db
    (create-test-collection)
    (db:insert "test_items" '(("name" . "test") ("value" . 1)))
    (let ((row (db:select-one "test_items" (db:query :all))))
      (is (assoc "_id" row :test #'string=))
      (is (plusp (cdr (assoc "_id" row :test #'string=)))))))

(test contract-select-by-id
  "Can select a record by _id"
  (with-test-db
    (create-test-collection)
    (let ((id (db:insert "test_items" '(("name" . "findme") ("value" . 42)))))
      (let ((row (db:select-one "test_items" (db:query (:= _id id)))))
        (is (not (null row)))
        (is (string= "findme" (cdr (assoc "name" row :test #'string=))))))))

(test ensure-id-integer
  "ensure-id accepts positive integers"
  (is (= 42 (db:ensure-id 42))))

(test ensure-id-string
  "ensure-id parses string integers"
  (is (= 42 (db:ensure-id "42"))))

(test ensure-id-bad-string
  "ensure-id signals on bad strings"
  (signals db:database-error
    (db:ensure-id "not-a-number")))
