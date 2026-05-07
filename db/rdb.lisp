;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Relational extension (fluxion.rdb)
;;;;
;;;; Extends the base DB interface with relational operations that
;;;; are available when the backend supports them (SQLite, PostgreSQL).
;;;;
;;;; Provides:
;;;;   rdb:join  - JOIN queries between collections
;;;;   rdb:sql   - raw SQL escape hatch with parameterized queries
;;;;
;;;; Usage:
;;;;   (rdb:join :inner "users" "orders"
;;;;     :on (:= users._id orders.user_id)
;;;;     :query (db:query (:> orders.total 100))
;;;;     :fields '(users.name orders.total))
;;;;
;;;;   (rdb:sql "SELECT * FROM users WHERE name = ?" "Alice")

(defpackage #:fluxion.rdb
  (:use #:cl)
  (:local-nicknames (#:db #:fluxion.db)
                    (#:q #:fluxion.db.query))
  (:export
   ;; Join operations
   #:join

   ;; Raw SQL escape hatch
   #:sql
   #:sql-execute

   ;; Backend protocol for relational operations
   #:%join
   #:%sql-query
   #:%sql-execute))

(in-package #:fluxion.rdb)

;;; -------------------------------------------------------
;;; Backend protocol generics
;;; -------------------------------------------------------

(defgeneric %join (backend type left-collection right-collection
                   &key on query fields sort skip amount)
  (:documentation
   "Execute a JOIN between LEFT-COLLECTION and RIGHT-COLLECTION.
TYPE is one of :inner, :left, :right, or :cross.
ON is a join condition as a query DSL expression using qualified field names.
QUERY is an optional WHERE filter (compiled query cons).
FIELDS is an optional list of qualified field names to return.
SORT, SKIP, AMOUNT work as in db:select.
Returns a list of alists."))

(defgeneric %sql-query (backend sql params)
  (:documentation
   "Execute raw SQL that returns rows. PARAMS is a list of parameter values
for ? placeholders. Returns a list of alists with string keys."))

(defgeneric %sql-execute (backend sql params)
  (:documentation
   "Execute raw SQL that does not return rows (INSERT, UPDATE, DELETE, DDL).
PARAMS is a list of parameter values for ? placeholders.
Returns the backend-specific result (typically row count or NIL)."))

;;; -------------------------------------------------------
;;; Join condition compilation
;;; -------------------------------------------------------

(defun qualified-field-p (sym)
  "Return T if SYM looks like a qualified field name (contains a dot).
Example: users.name, orders.total"
  (and (symbolp sym)
       (find #\. (symbol-name sym))))

(defun split-qualified (sym)
  "Split a qualified field symbol like USERS.NAME into (\"users\" \"name\").
Returns (table-name column-name) as strings."
  (let* ((name (string-downcase (symbol-name sym)))
         (dot (position #\. name)))
    (if dot
        (list (subseq name 0 dot)
              (subseq name (1+ dot)))
        (list nil name))))

(defun quote-qualified (sym)
  "Quote a qualified field name for SQL.
USERS.NAME becomes \"users\".\"name\"."
  (let ((parts (split-qualified sym)))
    (if (first parts)
        (format nil "~A.~A"
                (q:quote-identifier (first parts))
                (q:quote-identifier (second parts)))
        (q:quote-identifier (second parts)))))

(defun compile-join-expr (expr)
  "Compile a join condition expression to SQL.
Like compile-query-expr but supports qualified field names on both sides.
For ON clauses: (:= users._id orders.user_id)"
  (cond
    ((atom expr)
     (if (qualified-field-p expr)
         (quote-qualified expr)
         (error "Expected a join expression, got atom: ~S" expr)))

    ;; Equality between two qualified fields: (:= table1.col table2.col)
    ((member (car expr) '(:= :!= :< :> :<= :>=))
     (destructuring-bind (op left right) expr
       (let ((sql-op (case op
                       (:=  "=")
                       (:!= "!=")
                       (:<  "<")
                       (:>  ">")
                       (:<= "<=")
                       (:>= ">="))))
         (format nil "~A ~A ~A"
                 (if (qualified-field-p left)
                     (quote-qualified left)
                     (q:quote-identifier left))
                 sql-op
                 (if (qualified-field-p right)
                     (quote-qualified right)
                     (q:quote-identifier right))))))

    ;; AND
    ((eq (car expr) :and)
     (let ((clauses (mapcar #'compile-join-expr (cdr expr))))
       (format nil "(~{~A~^ AND ~})" clauses)))

    ;; OR
    ((eq (car expr) :or)
     (let ((clauses (mapcar #'compile-join-expr (cdr expr))))
       (format nil "(~{~A~^ OR ~})" clauses)))

    (t (error "Unknown join condition operator: ~S" (car expr)))))

(defun compile-join-fields (fields)
  "Compile a list of qualified field names to a SQL column list.
NIL means all columns (*)."
  (if fields
      (format nil "~{~A~^, ~}" (mapcar #'quote-qualified fields))
      "*"))

(defun join-type-sql (type)
  "Convert a join type keyword to SQL string."
  (ecase type
    (:inner "INNER JOIN")
    (:left  "LEFT JOIN")
    (:right "RIGHT JOIN")
    (:cross "CROSS JOIN")))

(defun compile-join-sql (type left right &key on query fields sort skip amount)
  "Compile a full JOIN statement.
Returns (sql-string . parameter-list)."
  (let* ((col-str (compile-join-fields fields))
         (on-sql (when on (compile-join-expr on)))
         (where-sql (when query (car query)))
         (where-params (when query (cdr query)))
         (sql (format nil "SELECT ~A FROM ~A ~A ~A"
                      col-str
                      (q:quote-identifier left)
                      (join-type-sql type)
                      (q:quote-identifier right))))
    ;; ON clause
    (when on-sql
      (setf sql (format nil "~A ON ~A" sql on-sql)))
    ;; WHERE clause
    (when where-sql
      (setf sql (format nil "~A WHERE ~A" sql where-sql)))
    ;; ORDER BY
    (when sort
      (let ((order-parts (mapcar (lambda (s)
                                   (format nil "~A ~A"
                                           (if (qualified-field-p (car s))
                                               (quote-qualified (car s))
                                               (q:quote-identifier (car s)))
                                           (ecase (cdr s)
                                             (:asc "ASC")
                                             (:desc "DESC"))))
                                 sort)))
        (setf sql (format nil "~A ORDER BY ~{~A~^, ~}" sql order-parts))))
    ;; LIMIT / OFFSET
    (when amount
      (setf sql (format nil "~A LIMIT ~D" sql amount)))
    (when (and skip (plusp skip))
      (setf sql (format nil "~A OFFSET ~D" sql skip)))
    (cons sql where-params)))

;;; -------------------------------------------------------
;;; Public API
;;; -------------------------------------------------------

(defun %join-call (type left-collection right-collection
                   &key on query fields sort skip amount)
  "Runtime implementation for the join macro."
  (%join (db:current-backend) type
         (string left-collection) (string right-collection)
         :on on :query query :fields fields
         :sort sort :skip skip :amount amount))

(defmacro join (type left-collection right-collection
                &key on query fields sort skip amount)
  "Execute a JOIN between two collections and return matching records.
TYPE is :inner, :left, :right, or :cross.
ON is the join condition as a query DSL expression with qualified field names.
QUERY is an optional WHERE filter (from db:query).
FIELDS is an optional list of qualified field symbols to select.
SORT, SKIP, AMOUNT control ordering and pagination.

Example:
  (rdb:join :inner \"users\" \"orders\"
    :on (:= users._id orders.user_id)
    :query (db:query (:> orders.total 100))
    :fields '(users.name orders.total)
    :sort '((orders.total . :desc)))"
  `(%join-call ,type ,left-collection ,right-collection
               :on ',on :query ,query :fields ,fields
               :sort ,sort :skip ,skip :amount ,amount))

(defun sql (sql &rest params)
  "Execute raw SQL that returns rows. Use ? placeholders for parameters.
Returns a list of alists with string keys.

This is an escape hatch for queries that the DSL cannot express.
Prefer the structured API (db:select, rdb:join) when possible.

Example:
  (rdb:sql \"SELECT u.name, COUNT(o._id) AS order_count
             FROM users u JOIN orders o ON u._id = o.user_id
             GROUP BY u.name HAVING COUNT(o._id) > ?\" 5)"
  (%sql-query (db:current-backend) sql params))

(defun sql-execute (sql &rest params)
  "Execute raw SQL that does not return rows (DDL, INSERT, UPDATE, DELETE).
Use ? placeholders for parameters.

Example:
  (rdb:sql-execute \"CREATE INDEX idx_users_name ON users (name)\")"
  (%sql-execute (db:current-backend) sql params))
