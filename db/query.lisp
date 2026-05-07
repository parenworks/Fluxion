;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Query DSL
;;;;
;;;; S-expression query language that compiles to parameterized SQL.
;;;; Applications never write SQL directly; they use the query macro:
;;;;
;;;;   (db:query (:= 'name "Alice"))
;;;;   (db:query (:and (:= 'role "admin") (:> 'age 21)))
;;;;   (db:query :all)
;;;;
;;;; The compiler produces a (sql-string . parameters) cons for each query,
;;;; which backends consume to build prepared statements.

(in-package #:fluxion.db.query)

;;; -------------------------------------------------------
;;; Query representation
;;; -------------------------------------------------------

;;; A compiled query is a cons: (sql-string . parameter-list)
;;; Parameters use ? placeholders, numbered by position.
;;; :all compiles to ("1=1" . nil) (match everything).

;;; -------------------------------------------------------
;;; Field name handling
;;; -------------------------------------------------------

(defun field-name-sql (field)
  "Convert a field name (symbol or string) to a SQL column name string.
Symbols are lowercased and hyphens become underscores."
  (let ((name (etypecase field
                (symbol (string-downcase (symbol-name field)))
                (string field))))
    ;; Convert hyphens to underscores for SQL compatibility
    (substitute #\_ #\- name)))

(defun quote-identifier (name)
  "Quote a SQL identifier (table or column name) with double quotes.
Handles qualified names like users._id by quoting each part separately."
  (let ((raw (field-name-sql name)))
    (let ((dot (position #\. raw)))
      (if dot
          (format nil "\"~A\".\"~A\"" (subseq raw 0 dot) (subseq raw (1+ dot)))
          (format nil "\"~A\"" raw)))))

;;; -------------------------------------------------------
;;; Query compilation
;;; -------------------------------------------------------

(defvar *param-counter* 0
  "Counter for generating parameter placeholders during compilation.")

(defvar *params* nil
  "Accumulator for parameter values during compilation.")

(defun next-placeholder ()
  "Return the next parameter placeholder string.
Uses ? for portability (both SQLite and PostgreSQL support it via drivers)."
  "?")

(defun collect-param (value)
  "Register a parameter value and return its placeholder."
  (push value *params*)
  (next-placeholder))

(defun compile-query-expr (expr)
  "Compile a single query expression into a SQL WHERE clause string.
Parameters are accumulated in *params*."
  (cond
    ;; :all - match everything
    ((eq expr :all)
     "1=1")

    ;; Atom - just a value (shouldn't appear at top level normally)
    ((atom expr)
     (collect-param expr))

    ;; Comparison operators: (:= field value), (:< field value), etc.
    ((member (car expr) '(:= :!= :< :> :<= :>=))
     (destructuring-bind (op field value) expr
       (let ((col (quote-identifier field))
             (sql-op (case op
                       (:=  "=")
                       (:!= "!=")
                       (:<  "<")
                       (:>  ">")
                       (:<= "<=")
                       (:>= ">="))))
         (if (null value)
             ;; NULL handling
             (case op
               (:=  (format nil "~A IS NULL" col))
               (:!= (format nil "~A IS NOT NULL" col))
               (t   (format nil "~A ~A ~A" col sql-op (collect-param value))))
             (format nil "~A ~A ~A" col sql-op (collect-param value))))))

    ;; LIKE: (:like field pattern)
    ((eq (car expr) :like)
     (destructuring-bind (op field pattern) expr
       (declare (ignore op))
       (format nil "~A LIKE ~A" (quote-identifier field) (collect-param pattern))))

    ;; NOT LIKE: (:not-like field pattern)
    ((eq (car expr) :not-like)
     (destructuring-bind (op field pattern) expr
       (declare (ignore op))
       (format nil "~A NOT LIKE ~A"
               (quote-identifier field) (collect-param pattern))))

    ;; IN: (:in field (list of values))
    ((eq (car expr) :in)
     (destructuring-bind (op field values) expr
       (declare (ignore op))
       (let ((placeholders (mapcar #'collect-param values)))
         (format nil "~A IN (~{~A~^, ~})" (quote-identifier field) placeholders))))

    ;; NOT IN
    ((eq (car expr) :not-in)
     (destructuring-bind (op field values) expr
       (declare (ignore op))
       (let ((placeholders (mapcar #'collect-param values)))
         (format nil "~A NOT IN (~{~A~^, ~})"
                 (quote-identifier field) placeholders))))

    ;; BETWEEN: (:between field low high)
    ((eq (car expr) :between)
     (destructuring-bind (op field low high) expr
       (declare (ignore op))
       (format nil "~A BETWEEN ~A AND ~A"
               (quote-identifier field)
               (collect-param low)
               (collect-param high))))

    ;; AND: (:and expr1 expr2 ...)
    ((eq (car expr) :and)
     (let ((clauses (mapcar #'compile-query-expr (cdr expr))))
       (format nil "(~{~A~^ AND ~})" clauses)))

    ;; OR: (:or expr1 expr2 ...)
    ((eq (car expr) :or)
     (let ((clauses (mapcar #'compile-query-expr (cdr expr))))
       (format nil "(~{~A~^ OR ~})" clauses)))

    ;; NOT: (:not expr)
    ((eq (car expr) :not)
     (format nil "NOT (~A)" (compile-query-expr (second expr))))

    (t
     (error "Unknown query operator: ~S" (car expr)))))

;;; -------------------------------------------------------
;;; Public API
;;; -------------------------------------------------------

(defun compile-query (expr)
  "Compile a query expression into (sql-string . reversed-parameter-list).
Example:
  (compile-query '(:and (:= name \"Alice\") (:> age 21)))
  => (\"(\\\"name\\\" = ? AND \\\"age\\\" > ?)\" \"Alice\" 21)"
  (let ((*params* nil))
    (let ((sql (compile-query-expr expr)))
      (cons sql (nreverse *params*)))))

(defmacro query (expr)
  "Compile a query DSL expression at macro-expansion time when possible.
Returns a (sql-string . parameter-list) cons at runtime.

Usage:
  (db:query :all)
  (db:query (:= 'name \"Alice\"))
  (db:query (:and (:= 'role \"admin\") (:> 'age 21)))"
  ;; For now, all compilation happens at runtime since queries may
  ;; contain variables. A future optimization could detect constant
  ;; queries and compile at macro-expansion time.
  `(compile-query ',expr))

;;; -------------------------------------------------------
;;; SQL generation helpers for backends
;;; -------------------------------------------------------

(defun compile-fields (fields)
  "Compile a field list to a SQL column list string.
NIL means all columns (*)."
  (if fields
      (format nil "~{~A~^, ~}" (mapcar #'quote-identifier fields))
      "*"))

(defun compile-sort (sort)
  "Compile a sort specification to a SQL ORDER BY clause.
SORT is a list of (field . :asc/:desc) pairs.
Returns a string like: ORDER BY \"name\" ASC, \"age\" DESC
or NIL if sort is empty."
  (when sort
    (format nil "ORDER BY ~{~A~^, ~}"
            (mapcar (lambda (s)
                      (format nil "~A ~A"
                              (quote-identifier (car s))
                              (ecase (cdr s)
                                (:asc "ASC")
                                (:desc "DESC"))))
                    sort))))

(defun compile-create-table (name structure)
  "Generate a CREATE TABLE SQL string for NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs.
An _id INTEGER PRIMARY KEY AUTOINCREMENT column is prepended.
Returns the SQL string (no parameters needed)."
  (let* ((cols (mapcar (lambda (spec)
                         (format nil "~A ~A"
                                 (quote-identifier (first spec))
                                 (field-type-sql (second spec))))
                       structure))
         (all-cols (cons "\"_id\" INTEGER PRIMARY KEY AUTOINCREMENT" cols)))
    (format nil "CREATE TABLE ~A (~{~A~^, ~})"
            (quote-identifier name) all-cols)))

(defun field-type-sql (type)
  "Convert a portable field type keyword to SQL type string."
  (ecase type
    (:text "TEXT")
    (:integer "INTEGER")
    (:float "REAL")
    (:boolean "INTEGER")
    (:timestamp "TEXT")))

(defun compile-alter-table (name new-columns)
  "Generate ALTER TABLE statements to add NEW-COLUMNS to NAME.
Returns a list of SQL strings."
  (mapcar (lambda (spec)
            (format nil "ALTER TABLE ~A ADD COLUMN ~A ~A"
                    (quote-identifier name)
                    (quote-identifier (first spec))
                    (field-type-sql (second spec))))
          new-columns))

(defun compile-insert (table data)
  "Generate an INSERT statement for TABLE with DATA (alist).
Returns (sql-string . parameter-list)."
  (let ((columns (mapcar #'car data))
        (values (mapcar #'cdr data)))
    (let ((col-str (format nil "~{~A~^, ~}" (mapcar #'quote-identifier columns)))
          (val-str (format nil "~{~A~^, ~}" (make-list (length values)
                                                        :initial-element "?"))))
      (cons (format nil "INSERT INTO ~A (~A) VALUES (~A)"
                    (quote-identifier table) col-str val-str)
            values))))

(defun compile-update (table query-compiled data)
  "Generate an UPDATE statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
DATA is an alist of fields to set.
Returns (sql-string . parameter-list)."
  (let* ((set-parts (mapcar (lambda (pair)
                              (format nil "~A = ?" (quote-identifier (car pair))))
                            data))
         (set-values (mapcar #'cdr data))
         (where-sql (car query-compiled))
         (where-params (cdr query-compiled)))
    (cons (format nil "UPDATE ~A SET ~{~A~^, ~} WHERE ~A"
                  (quote-identifier table) set-parts where-sql)
          (append set-values where-params))))

(defun compile-delete (table query-compiled)
  "Generate a DELETE statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
Returns (sql-string . parameter-list)."
  (cons (format nil "DELETE FROM ~A WHERE ~A"
                (quote-identifier table) (car query-compiled))
        (cdr query-compiled)))

(defun compile-select (table query-compiled &key fields sort skip amount unique)
  "Generate a SELECT statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
Returns (sql-string . parameter-list)."
  (let ((col-str (if unique
                     (format nil "DISTINCT ~A" (compile-fields fields))
                     (compile-fields fields)))
        (where-sql (car query-compiled))
        (where-params (cdr query-compiled)))
    (let ((sql (format nil "SELECT ~A FROM ~A WHERE ~A"
                       col-str (quote-identifier table) where-sql)))
      ;; Append ORDER BY
      (let ((order (compile-sort sort)))
        (when order
          (setf sql (format nil "~A ~A" sql order))))
      ;; Append LIMIT/OFFSET
      (when amount
        (setf sql (format nil "~A LIMIT ~D" sql amount)))
      (when (and skip (plusp skip))
        (setf sql (format nil "~A OFFSET ~D" sql skip)))
      (cons sql where-params))))
