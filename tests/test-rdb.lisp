;;;; -*- encoding:utf-8 -*-
;;;; Fluxion RDB Extension - Test suite
;;;;
;;;; Tests join operations and raw SQL against SQLite in-memory.

(in-package #:fluxion.db.tests)

(def-suite :rdb-suite
  :description "Relational database extension tests"
  :in :db-suite)

(in-suite :rdb-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defun create-rdb-test-data ()
  "Create users and orders tables with test data for join tests."
  (db:create "users" '((name :text) (role :text)))
  (db:create "orders" '((user_id :integer) (product :text) (total :integer)))
  ;; Insert users
  (let ((u1 (db:insert "users" '(("name" . "Alice") ("role" . "admin"))))
        (u2 (db:insert "users" '(("name" . "Bob") ("role" . "user"))))
        (u3 (db:insert "users" '(("name" . "Carol") ("role" . "user")))))
    ;; Insert orders
    (db:insert "orders" `(("user_id" . ,u1) ("product" . "Widget") ("total" . 100)))
    (db:insert "orders" `(("user_id" . ,u1) ("product" . "Gadget") ("total" . 250)))
    (db:insert "orders" `(("user_id" . ,u2) ("product" . "Widget") ("total" . 50)))
    ;; Carol has no orders (for left join test)
    (values u1 u2 u3)))

;;; -------------------------------------------------------
;;; Inner join tests
;;; -------------------------------------------------------

(test rdb-inner-join-basic
  "Inner join returns matching rows from both tables"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :inner "users" "orders"
                  :on (:= users._id orders.user_id))))
      ;; Alice has 2 orders, Bob has 1, Carol has 0
      (is (= 3 (length rows))))))

(test rdb-inner-join-with-query
  "Inner join with WHERE filter"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :inner "users" "orders"
                  :on (:= users._id orders.user_id)
                  :query (db:query (:> orders.total 75)))))
      ;; Only Alice's orders > 75: Widget(100) and Gadget(250)
      (is (= 2 (length rows))))))

(test rdb-inner-join-with-fields
  "Inner join selecting specific fields"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :inner "users" "orders"
                  :on (:= users._id orders.user_id)
                  :fields '(users.name orders.product orders.total))))
      (is (= 3 (length rows)))
      ;; Each row should have name, product, total
      (let ((first-row (first rows)))
        (is (assoc "name" first-row :test #'string=))
        (is (assoc "product" first-row :test #'string=))
        (is (assoc "total" first-row :test #'string=))))))

(test rdb-inner-join-with-sort
  "Inner join with ORDER BY"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :inner "users" "orders"
                  :on (:= users._id orders.user_id)
                  :sort '((orders.total . :desc)))))
      (is (= 250 (cdr (assoc "total" (first rows) :test #'string=))))
      (is (= 50 (cdr (assoc "total" (third rows) :test #'string=)))))))

(test rdb-inner-join-with-amount
  "Inner join with LIMIT"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :inner "users" "orders"
                  :on (:= users._id orders.user_id)
                  :amount 2)))
      (is (= 2 (length rows))))))

;;; -------------------------------------------------------
;;; Left join tests
;;; -------------------------------------------------------

(test rdb-left-join-includes-unmatched
  "Left join includes rows with no match in the right table"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :left "users" "orders"
                  :on (:= users._id orders.user_id))))
      ;; Alice(2) + Bob(1) + Carol(1 with NULL order) = 4
      (is (= 4 (length rows)))
      ;; Carol's row should have NULL product
      (let ((carol-row (find-if (lambda (r)
                                  (string= "Carol"
                                           (cdr (assoc "name" r :test #'string=))))
                                rows)))
        (is (not (null carol-row)))
        (is (null (cdr (assoc "product" carol-row :test #'string=))))))))

;;; -------------------------------------------------------
;;; Cross join test
;;; -------------------------------------------------------

(test rdb-cross-join
  "Cross join produces cartesian product"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:join :cross "users" "orders")))
      ;; 3 users x 3 orders = 9
      (is (= 9 (length rows))))))

;;; -------------------------------------------------------
;;; Raw SQL tests
;;; -------------------------------------------------------

(test rdb-sql-select
  "Raw SQL query returns alist rows"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:sql "SELECT * FROM \"users\" WHERE \"role\" = ?" "admin")))
      (is (= 1 (length rows)))
      (is (string= "Alice" (cdr (assoc "name" (first rows) :test #'string=)))))))

(test rdb-sql-with-join
  "Raw SQL can express complex joins"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:sql
                 "SELECT u.\"name\", SUM(o.\"total\") AS \"order_total\"
                  FROM \"users\" u
                  JOIN \"orders\" o ON u.\"_id\" = o.\"user_id\"
                  GROUP BY u.\"name\"
                  HAVING SUM(o.\"total\") > ?"
                 100)))
      ;; Alice: 100+250=350 > 100, Bob: 50 <= 100
      (is (= 1 (length rows)))
      (is (string= "Alice" (cdr (assoc "name" (first rows) :test #'string=)))))))

(test rdb-sql-no-params
  "Raw SQL without parameters"
  (with-test-db
    (create-rdb-test-data)
    (let ((rows (fluxion.rdb:sql "SELECT COUNT(*) AS \"cnt\" FROM \"users\"")))
      (is (= 3 (cdr (assoc "cnt" (first rows) :test #'string=)))))))

(test rdb-sql-execute-ddl
  "sql-execute for DDL statements"
  (with-test-db
    (db:create "users" '((name :text)))
    (fluxion.rdb:sql-execute "CREATE INDEX \"idx_users_name\" ON \"users\" (\"name\")")
    ;; If we get here without error, the index was created
    (is (db:collection-exists-p "users"))))

(test rdb-sql-execute-dml
  "sql-execute for DML statements"
  (with-test-db
    (db:create "users" '((name :text) (role :text)))
    (db:insert "users" '(("name" . "Alice") ("role" . "user")))
    (fluxion.rdb:sql-execute "UPDATE \"users\" SET \"role\" = ? WHERE \"name\" = ?"
                             "admin" "Alice")
    (let ((row (db:select-one "users" (db:query (:= name "Alice")))))
      (is (string= "admin" (cdr (assoc "role" row :test #'string=)))))))

;;; -------------------------------------------------------
;;; Join condition compilation tests
;;; -------------------------------------------------------

(test rdb-compile-join-expr-equality
  "Join condition compiles qualified field equality"
  (let ((sql (fluxion.rdb::compile-join-expr '(:= users._id orders.user_id))))
    (is (search "\"users\".\"_id\"" sql))
    (is (search "\"orders\".\"user_id\"" sql))
    (is (search "=" sql))))

(test rdb-compile-join-expr-and
  "Join condition compiles AND"
  (let ((sql (fluxion.rdb::compile-join-expr
              '(:and (:= a.x b.y) (:= a.z b.w)))))
    (is (search "AND" sql))))
