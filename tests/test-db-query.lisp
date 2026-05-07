;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Query DSL tests

(in-package #:fluxion.db.tests)

(in-suite :db-query-suite)

;;; -------------------------------------------------------
;;; compile-query tests
;;; -------------------------------------------------------

(test query-all
  "Query :all compiles to 1=1 with no params"
  (let ((result (q:compile-query :all)))
    (is (string= "1=1" (car result)))
    (is (null (cdr result)))))

(test query-equals
  "Simple equality compiles correctly"
  (let ((result (q:compile-query '(:= name "Alice"))))
    (is (search "\"name\" =" (car result)))
    (is (equal '("Alice") (cdr result)))))

(test query-not-equals
  "Not-equals compiles correctly"
  (let ((result (q:compile-query '(:!= role "guest"))))
    (is (search "\"role\" !=" (car result)))
    (is (equal '("guest") (cdr result)))))

(test query-less-than
  "Less-than compiles correctly"
  (let ((result (q:compile-query '(:< age 21))))
    (is (search "\"age\" <" (car result)))
    (is (equal '(21) (cdr result)))))

(test query-greater-than
  "Greater-than compiles correctly"
  (let ((result (q:compile-query '(:> count 100))))
    (is (search "\"count\" >" (car result)))
    (is (equal '(100) (cdr result)))))

(test query-lte
  "Less-than-or-equal compiles correctly"
  (let ((result (q:compile-query '(:<= priority 5))))
    (is (search "\"priority\" <=" (car result)))
    (is (equal '(5) (cdr result)))))

(test query-gte
  "Greater-than-or-equal compiles correctly"
  (let ((result (q:compile-query '(:>= score 90))))
    (is (search "\"score\" >=" (car result)))
    (is (equal '(90) (cdr result)))))

(test query-null-equals
  "Equality to NIL compiles to IS NULL"
  (let ((result (q:compile-query '(:= deleted nil))))
    (is (search "IS NULL" (car result)))
    (is (null (cdr result)))))

(test query-null-not-equals
  "Not-equals NIL compiles to IS NOT NULL"
  (let ((result (q:compile-query '(:!= email nil))))
    (is (search "IS NOT NULL" (car result)))
    (is (null (cdr result)))))

(test query-like
  "LIKE compiles correctly"
  (let ((result (q:compile-query '(:like name "%test%"))))
    (is (search "LIKE" (car result)))
    (is (equal '("%test%") (cdr result)))))

(test query-not-like
  "NOT LIKE compiles correctly"
  (let ((result (q:compile-query '(:not-like name "%spam%"))))
    (is (search "NOT LIKE" (car result)))
    (is (equal '("%spam%") (cdr result)))))

(test query-in
  "IN compiles correctly"
  (let ((result (q:compile-query '(:in role ("admin" "editor")))))
    (is (search "IN" (car result)))
    (is (equal '("admin" "editor") (cdr result)))))

(test query-not-in
  "NOT IN compiles correctly"
  (let ((result (q:compile-query '(:not-in status ("deleted" "banned")))))
    (is (search "NOT IN" (car result)))
    (is (equal '("deleted" "banned") (cdr result)))))

(test query-between
  "BETWEEN compiles correctly"
  (let ((result (q:compile-query '(:between age 18 65))))
    (is (search "BETWEEN" (car result)))
    (is (equal '(18 65) (cdr result)))))

(test query-and
  "AND combines clauses correctly"
  (let ((result (q:compile-query '(:and (:= role "admin") (:> age 21)))))
    (is (search "AND" (car result)))
    (is (equal '("admin" 21) (cdr result)))))

(test query-or
  "OR combines clauses correctly"
  (let ((result (q:compile-query '(:or (:= role "admin") (:= role "editor")))))
    (is (search "OR" (car result)))
    (is (equal '("admin" "editor") (cdr result)))))

(test query-not
  "NOT wraps a clause correctly"
  (let ((result (q:compile-query '(:not (:= banned t)))))
    (is (search "NOT" (car result)))))

(test query-nested-and-or
  "Nested AND/OR compiles correctly"
  (let ((result (q:compile-query
                 '(:and (:= active 1)
                        (:or (:= role "admin")
                             (:= role "editor"))))))
    (is (search "AND" (car result)))
    (is (search "OR" (car result)))
    (is (= 3 (length (cdr result))))))

(test query-hyphen-to-underscore
  "Field names with hyphens become underscores in SQL"
  (let ((result (q:compile-query '(:= user-name "test"))))
    (is (search "\"user_name\"" (car result)))))

;;; -------------------------------------------------------
;;; SQL generation helper tests
;;; -------------------------------------------------------

(test compile-fields-all
  "NIL fields compiles to *"
  (is (string= "*" (q:compile-fields nil))))

(test compile-fields-specific
  "Specific fields compile to quoted column list"
  (let ((result (q:compile-fields '(name age))))
    (is (search "\"name\"" result))
    (is (search "\"age\"" result))))

(test compile-sort-single
  "Single sort compiles correctly"
  (let ((result (q:compile-sort '((name . :asc)))))
    (is (search "ORDER BY" result))
    (is (search "ASC" result))))

(test compile-sort-multi
  "Multiple sort fields compile correctly"
  (let ((result (q:compile-sort '((name . :asc) (age . :desc)))))
    (is (search "ASC" result))
    (is (search "DESC" result))))

(test compile-sort-nil
  "NIL sort returns NIL"
  (is (null (q:compile-sort nil))))

(test compile-create-table-basic
  "CREATE TABLE includes _id and all fields"
  (let ((sql (q:compile-create-table "users" '((name :text) (age :integer)))))
    (is (search "CREATE TABLE" sql))
    (is (search "_id" sql))
    (is (search "\"name\" TEXT" sql))
    (is (search "\"age\" INTEGER" sql))))

(test compile-insert-basic
  "INSERT generates correct SQL and params"
  (let ((result (q:compile-insert "users" '(("name" . "Alice") ("age" . 30)))))
    (is (search "INSERT INTO" (car result)))
    (is (search "\"name\"" (car result)))
    (is (equal '("Alice" 30) (cdr result)))))

(test compile-select-basic
  "SELECT generates correct SQL"
  (let* ((qc (q:compile-query '(:= role "admin")))
         (result (q:compile-select "users" qc)))
    (is (search "SELECT" (car result)))
    (is (search "FROM \"users\"" (car result)))
    (is (search "WHERE" (car result)))))

(test compile-select-with-limit
  "SELECT with amount generates LIMIT"
  (let* ((qc (q:compile-query :all))
         (result (q:compile-select "users" qc :amount 10)))
    (is (search "LIMIT 10" (car result)))))

(test compile-select-with-offset
  "SELECT with skip generates OFFSET"
  (let* ((qc (q:compile-query :all))
         (result (q:compile-select "users" qc :skip 5 :amount 10)))
    (is (search "OFFSET 5" (car result)))))

(test compile-select-distinct
  "SELECT with unique generates DISTINCT"
  (let* ((qc (q:compile-query :all))
         (result (q:compile-select "users" qc :unique t)))
    (is (search "DISTINCT" (car result)))))
