;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Backend protocol
;;;;
;;;; Defines the generic functions that every database backend must implement.
;;;; Applications call these via the fluxion.db (fxdb) package and never
;;;; write SQL directly.

(in-package #:fluxion.db)

;;; -------------------------------------------------------
;;; Backend base class and active backend
;;; -------------------------------------------------------

(defclass backend ()
  ()
  (:documentation "Abstract base class for database backends.
Every backend (SQLite, PostgreSQL, etc.) subclasses this and implements
the required generic functions."))

(defvar *backend* nil
  "The currently active database backend instance.")

(defun current-backend ()
  "Return the currently active database backend, signalling an error if none."
  (or *backend*
      (error 'connection-failed
             :message "No database backend is active. Call db:connect first.")))

;;; -------------------------------------------------------
;;; Types
;;; -------------------------------------------------------

(deftype field-type ()
  "Portable field types supported by all backends."
  '(member :text :integer :bigint :float :boolean :timestamp))

(deftype id ()
  "Type for record identifiers. Always a positive integer."
  '(integer 1))

(defun ensure-id (value)
  "Coerce VALUE to a database ID (positive integer).
Accepts integers and strings containing integers."
  (etypecase value
    ((integer 1) value)
    (string (let ((parsed (parse-integer value :junk-allowed t)))
              (if (and parsed (plusp parsed))
                  parsed
                  (error 'database-error
                         :message (format nil "Cannot coerce ~S to a database ID"
                                          value)))))
    (integer (if (plusp value)
                 value
                 (error 'database-error
                        :message (format nil "ID must be positive, got ~D" value))))))

;;; -------------------------------------------------------
;;; Connection management
;;; -------------------------------------------------------

(defgeneric connect (backend &key)
  (:documentation "Open a database connection using BACKEND.
Sets *backend* to the connected backend instance. Returns the backend.
Keyword arguments are backend-specific (e.g. :database, :host, :port)."))

(defgeneric disconnect (backend)
  (:documentation "Close the database connection for BACKEND.
Clears *backend* if it points to this backend."))

(defgeneric connected-p (backend)
  (:documentation "Return T if BACKEND has an active connection."))

(defmacro with-connection ((backend &rest connect-args) &body body)
  "Execute BODY with BACKEND connected. Disconnects on exit."
  (let ((b (gensym "BACKEND")))
    `(let ((,b ,backend))
       (connect ,b ,@connect-args)
       (unwind-protect (progn ,@body)
         (disconnect ,b)))))

;;; Convenience wrappers that dispatch through *backend*

(defun %ensure-connected ()
  "Return the current backend or signal an error."
  (current-backend))

;;; -------------------------------------------------------
;;; Collection (table) management
;;; -------------------------------------------------------

(defgeneric %collections (backend)
  (:documentation "Return a list of collection name strings."))

(defgeneric %collection-exists-p (backend name)
  (:documentation "Return T if collection NAME exists."))

(defgeneric %create (backend name structure &key if-exists)
  (:documentation "Create a collection NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs.
IF-EXISTS is :error (default) or :ignore."))

(defgeneric %drop (backend name)
  (:documentation "Drop (delete) collection NAME."))

(defgeneric %empty (backend name)
  (:documentation "Remove all records from collection NAME."))

(defgeneric %alter (backend name structure)
  (:documentation "Alter collection NAME to match STRUCTURE.
Adds missing columns. Does not remove or rename existing columns."))

(defgeneric %collection-structure (backend name)
  (:documentation "Return the structure of collection NAME as a list
of (field-name field-type) pairs."))

;;; Public API (dispatch through *backend*)

(defun collections ()
  "Return a list of collection name strings."
  (%collections (%ensure-connected)))

(defun collection-exists-p (name)
  "Return T if collection NAME exists."
  (%collection-exists-p (%ensure-connected) (string name)))

(defun create (name structure &key (if-exists :error))
  "Create a collection NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs, e.g.:
  ((title :text) (count :integer) (active :boolean))
An _id :integer primary key is added automatically.
IF-EXISTS may be :error (default) or :ignore."
  (%create (%ensure-connected) (string name) structure :if-exists if-exists))

(defun drop (name)
  "Drop (delete) collection NAME and all its data."
  (%drop (%ensure-connected) (string name)))

(defun empty (name)
  "Remove all records from collection NAME."
  (%empty (%ensure-connected) (string name)))

(defun alter (name structure)
  "Alter collection NAME to match STRUCTURE.
Adds missing columns. Does not remove existing columns."
  (%alter (%ensure-connected) (string name) structure))

(defun collection-structure (name)
  "Return the structure of collection NAME as a list of (field-name field-type) pairs."
  (%collection-structure (%ensure-connected) (string name)))

;;; -------------------------------------------------------
;;; Data operations
;;; -------------------------------------------------------

(defgeneric %insert (backend collection data)
  (:documentation "Insert DATA (an alist of field-value pairs) into COLLECTION.
Returns the new record's ID."))

(defgeneric %select (backend collection query &key fields skip amount sort unique)
  (:documentation "Select records from COLLECTION matching QUERY.
Returns a list of alists. Each alist has string keys.
FIELDS: list of field names to return, or NIL for all.
SKIP: number of records to skip.
AMOUNT: max records to return.
SORT: list of (field . :asc/:desc) pairs.
UNIQUE: if T, return only distinct records."))

(defgeneric %count (backend collection query)
  (:documentation "Count records in COLLECTION matching QUERY."))

(defgeneric %update (backend collection query data &key skip amount sort)
  (:documentation "Update records in COLLECTION matching QUERY with DATA.
DATA is an alist of field-value pairs to set."))

(defgeneric %remove (backend collection query &key skip amount sort)
  (:documentation "Remove records from COLLECTION matching QUERY."))

(defgeneric %iterate (backend collection query function &key fields skip amount sort unique)
  (:documentation "Call FUNCTION once per record from COLLECTION matching QUERY.
FUNCTION receives an alist for each record."))

(defgeneric %execute-transaction (backend thunk)
  (:documentation "Execute THUNK within a database transaction.
Commits on normal return, rolls back on error."))

;;; Public API

(defun insert (collection data)
  "Insert DATA (an alist) into COLLECTION. Returns the new record's ID.
Example: (db:insert \"users\" '((\"name\" . \"Alice\") (\"role\" . \"admin\")))"
  (%insert (%ensure-connected) (string collection) data))

(defun select (collection query &key fields skip amount sort unique)
  "Select records from COLLECTION matching QUERY.
Returns a list of alists.
Example: (db:select \"users\" (db:query (:= name \"Alice\")))"
  (%select (%ensure-connected) (string collection) query
           :fields fields :skip skip :amount amount :sort sort :unique unique))

(defun select-one (collection query &key fields)
  "Select a single record from COLLECTION matching QUERY, or NIL."
  (first (select collection query :fields fields :amount 1)))

(defun count (collection query)
  "Count records in COLLECTION matching QUERY.
Example: (db:count \"users\" (db:query :all))"
  (%count (%ensure-connected) (string collection) query))

(defun update (collection query data &key skip amount sort)
  "Update records in COLLECTION matching QUERY with DATA (alist).
Example: (db:update \"users\" (db:query (:= _id 1)) '((\"role\" . \"admin\")))"
  (%update (%ensure-connected) (string collection) query data
           :skip skip :amount amount :sort sort))

(defun remove (collection query &key skip amount sort)
  "Remove records from COLLECTION matching QUERY.
Example: (db:remove \"users\" (db:query (:= name \"test\")))"
  (%remove (%ensure-connected) (string collection) query
           :skip skip :amount amount :sort sort))

(defun iterate (collection query function &key fields skip amount sort unique)
  "Call FUNCTION once per matching record (as alist) from COLLECTION.
Example: (db:iterate \"users\" (db:query :all) #'print)"
  (%iterate (%ensure-connected) (string collection) query function
            :fields fields :skip skip :amount amount :sort sort :unique unique))

(defmacro with-transaction (() &body body)
  "Execute BODY within a database transaction.
Commits on normal return, rolls back on error."
  `(%execute-transaction (%ensure-connected) (lambda () ,@body)))

;;; -------------------------------------------------------
;;; Convenience functions
;;; -------------------------------------------------------

(defun find-by-id (collection id &key fields)
  "Find a single record by primary key (_id).
Returns an alist or NIL if not found.
Example: (db:find-by-id \"users\" 42)"
  (select-one collection
              (fluxion.db.query:compile-query (list := '_id (ensure-id id)))
              :fields fields))

(defun delete-by-id (collection id)
  "Delete a single record by primary key (_id).
Example: (db:delete-by-id \"tracks\" 7)"
  (remove collection
         (fluxion.db.query:compile-query (list := '_id (ensure-id id)))
         :amount 1))

(defun exists-p (collection query)
  "Return T if at least one record in COLLECTION matches QUERY.
Example: (db:exists-p \"users\" (db:query (:= email \"a@b.com\")))"
  (plusp (count collection query)))


;;; -------------------------------------------------------
;;; Query DSL wrappers
;;; -------------------------------------------------------

(defmacro query (expr)
  "Compile a query DSL expression into (sql-string . parameter-list).
Field names (second element in comparisons) are always treated as symbols.
Value positions are evaluated at runtime, so variables work.

Usage:
  (db:query :all)
  (db:query (:= name \"Alice\"))
  (db:query (:= _id some-variable))
  (db:query (:and (:= role \"admin\") (:> age 21)))"
  (if (eq expr :all)
      `(fluxion.db.query:compile-query :all)
      `(fluxion.db.query:compile-query ,(transform-query-form expr))))

(defun compile-query (expr)
  "Compile a query expression at runtime.
Same as the query macro but accepts a runtime value."
  (fluxion.db.query:compile-query expr))

(defun transform-query-form (form)
  "Walk a query DSL form, quoting field-name symbols and leaving values as expressions.
Returns a backquoted form suitable for embedding in macro expansion."
  (cond
    ;; Keywords pass through
    ((keywordp form) form)
    ;; Atoms (strings, numbers) pass through
    ((atom form) form)
    ;; Comparison ops: (:op field value) - quote field, eval value
    ((member (car form) '(:= :!= :< :> :<= :>=))
     (destructuring-bind (op field value) form
       `(list ,op ',(if (symbolp field) field field) ,value)))
    ;; LIKE/NOT-LIKE: (:like field pattern) - quote field, eval pattern
    ((member (car form) '(:like :not-like))
     (destructuring-bind (op field pattern) form
       `(list ,op ',(if (symbolp field) field field) ,pattern)))
    ;; IN/NOT-IN: (:in field values) - quote field, eval values
    ((member (car form) '(:in :not-in))
     (destructuring-bind (op field values) form
       `(list ,op ',(if (symbolp field) field field) ,values)))
    ;; BETWEEN: (:between field low high) - quote field, eval low/high
    ((eq (car form) :between)
     (destructuring-bind (op field low high) form
       `(list ,op ',(if (symbolp field) field field) ,low ,high)))
    ;; AND/OR: (:and expr ...) - recurse
    ((member (car form) '(:and :or))
     `(list ,(car form) ,@(mapcar #'transform-query-form (cdr form))))
    ;; NOT: (:not expr) - recurse
    ((eq (car form) :not)
     `(list :not ,(transform-query-form (second form))))
    (t
     (error "Unknown query operator in macro: ~S" (car form)))))
