# Fluxion API Reference

Auto-generated from source docstrings.

---

## Database - backend protocol, connection management, collection CRUD, query DSL

Package: `fluxion.db`

### Class: `backend`

Abstract base class for database backends.
Every backend (SQLite, PostgreSQL, etc.) subclasses this and implements
the required generic functions.

### Class: `collection-already-exists`

### Class: `collection-error`

Slots:

- **`name`**

### Class: `connection-already-open`

### Class: `connection-failed`

### Class: `database-error`

Slots:

- **`message`**

### Class: `invalid-collection`

### Class: `invalid-field`

Slots:

- **`name`**

### Generic Functions

**`%alter (backend name structure)`** - Alter collection NAME to match STRUCTURE.
Adds missing columns. Does not remove or rename existing columns.

**`%collection-exists-p (backend name)`** - Return T if collection NAME exists.

**`%collection-structure (backend name)`** - Return the structure of collection NAME as a list
of (field-name field-type) pairs.

**`%collections (backend)`** - Return a list of collection name strings.

**`%count (backend collection query)`** - Count records in COLLECTION matching QUERY.

**`%create (backend name structure &key if-exists)`** - Create a collection NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs.
IF-EXISTS is :error (default) or :ignore.

**`%drop (backend name)`** - Drop (delete) collection NAME.

**`%empty (backend name)`** - Remove all records from collection NAME.

**`%execute-transaction (backend thunk)`** - Execute THUNK within a database transaction.
Commits on normal return, rolls back on error.

**`%insert (backend collection data)`** - Insert DATA (an alist of field-value pairs) into COLLECTION.
Returns the new record's ID.

**`%iterate (backend collection query function &key fields skip amount sort unique)`** - Call FUNCTION once per record from COLLECTION matching QUERY.
FUNCTION receives an alist for each record.

**`%remove (backend collection query &key skip amount sort)`** - Remove records from COLLECTION matching QUERY.

**`%select (backend collection query &key fields skip amount sort unique)`** - Select records from COLLECTION matching QUERY.
Returns a list of alists. Each alist has string keys.
FIELDS: list of field names to return, or NIL for all.
SKIP: number of records to skip.
AMOUNT: max records to return.
SORT: list of (field . :asc/:desc) pairs.
UNIQUE: if T, return only distinct records.

**`%update (backend collection query data &key skip amount sort)`** - Update records in COLLECTION matching QUERY with DATA.
DATA is an alist of field-value pairs to set.

**`collection-error-name (condition)`**

**`connect (backend &key)`** - Open a database connection using BACKEND.
Sets *backend* to the connected backend instance. Returns the backend.
Keyword arguments are backend-specific (e.g. :database, :host, :port).

**`connected-p (backend)`** - Return T if BACKEND has an active connection.

**`database-error-message (condition)`**

**`disconnect (backend)`** - Close the database connection for BACKEND.
Clears *backend* if it points to this backend.

**`invalid-field-name (condition)`**

### Macros

**`query (expr)`** *(macro)* - Compile a query DSL expression into (sql-string . parameter-list).
Field names (second element in comparisons) are always treated as symbols.
Value positions are evaluated at runtime, so variables work.

Usage:
  (db:query :all)
  (db:query (:= name "Alice"))
  (db:query (:= _id some-variable))
  (db:query (:and (:= role "admin") (:> age 21)))

**`with-connection ((backend &rest connect-args) &body body)`** *(macro)* - Execute BODY with BACKEND connected. Disconnects on exit.

**`with-transaction (nil &body body)`** *(macro)* - Execute BODY within a database transaction.
Commits on normal return, rolls back on error.

### Functions

**`alter (name structure)`** - Alter collection NAME to match STRUCTURE.
Adds missing columns. Does not remove existing columns.

**`collection-exists-p (name)`** - Return T if collection NAME exists.

**`collection-structure (name)`** - Return the structure of collection NAME as a list of (field-name field-type) pairs.

**`collections ()`** - Return a list of collection name strings.

**`compile-query (expr)`** - Compile a query expression at runtime.
Same as the query macro but accepts a runtime value.

**`count (collection query)`** - Count records in COLLECTION matching QUERY.
Example: (db:count "users" (db:query :all))

**`create (name structure &key (if-exists error))`** - Create a collection NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs, e.g.:
  ((title :text) (count :integer) (active :boolean))
An _id :integer primary key is added automatically.
IF-EXISTS may be :error (default) or :ignore.

**`current-backend ()`** - Return the currently active database backend, signalling an error if none.

**`drop (name)`** - Drop (delete) collection NAME and all its data.

**`empty (name)`** - Remove all records from collection NAME.

**`ensure-id (value)`** - Coerce VALUE to a database ID (positive integer).
Accepts integers and strings containing integers.

**`insert (collection data)`** - Insert DATA (an alist) into COLLECTION. Returns the new record's ID.
Example: (db:insert "users" '(("name" . "Alice") ("role" . "admin")))

**`iterate (collection query function &key fields skip amount sort unique)`** - Call FUNCTION once per matching record (as alist) from COLLECTION.
Example: (db:iterate "users" (db:query :all) #'print)

**`remove (collection query &key skip amount sort)`** - Remove records from COLLECTION matching QUERY.
Example: (db:remove "users" (db:query (:= name "test")))

**`select (collection query &key fields skip amount sort unique)`** - Select records from COLLECTION matching QUERY.
Returns a list of alists.
Example: (db:select "users" (db:query (:= name "Alice")))

**`select-one (collection query &key fields)`** - Select a single record from COLLECTION matching QUERY, or NIL.

**`update (collection query data &key skip amount sort)`** - Update records in COLLECTION matching QUERY with DATA (alist).
Example: (db:update "users" (db:query (:= _id 1)) '(("role" . "admin")))

### Variables

**`*backend*`** *(variable)* - The currently active database backend instance.

### Other

**`backend-connected-p`**

**`backend-name`**

**`field-type`**

**`id`**

---

## Query DSL - s-expression query compiler, SQL generation helpers

Package: `fluxion.db.query`

### Macros

**`query (expr)`** *(macro)* - Compile a query DSL expression at macro-expansion time when possible.
Returns a (sql-string . parameter-list) cons at runtime.

Usage:
  (db:query :all)
  (db:query (:= 'name "Alice"))
  (db:query (:and (:= 'role "admin") (:> 'age 21)))

### Functions

**`compile-alter-table (name new-columns)`** - Generate ALTER TABLE statements to add NEW-COLUMNS to NAME.
Returns a list of SQL strings.

**`compile-create-table (name structure)`** - Generate a CREATE TABLE SQL string for NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs.
An _id INTEGER PRIMARY KEY AUTOINCREMENT column is prepended.
Returns the SQL string (no parameters needed).

**`compile-delete (table query-compiled)`** - Generate a DELETE statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
Returns (sql-string . parameter-list).

**`compile-fields (fields)`** - Compile a field list to a SQL column list string.
NIL means all columns (*).

**`compile-insert (table data)`** - Generate an INSERT statement for TABLE with DATA (alist).
Returns (sql-string . parameter-list).

**`compile-query (expr)`** - Compile a query expression into (sql-string . reversed-parameter-list).
Example:
  (compile-query '(:and (:= name "Alice") (:> age 21)))
  => ("(\"name\" = ? AND \"age\" > ?)" "Alice" 21)

**`compile-select (table query-compiled &key fields sort skip amount unique)`** - Generate a SELECT statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
Returns (sql-string . parameter-list).

**`compile-sort (sort)`** - Compile a sort specification to a SQL ORDER BY clause.
SORT is a list of (field . :asc/:desc) pairs.
Returns a string like: ORDER BY "name" ASC, "age" DESC
or NIL if sort is empty.

**`compile-update (table query-compiled data)`** - Generate an UPDATE statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
DATA is an alist of fields to set.
Returns (sql-string . parameter-list).

**`field-name-sql (field)`** - Convert a field name (symbol or string) to a SQL column name string.
Symbols are lowercased and hyphens become underscores.

**`field-type-sql (type)`** - Convert a portable field type keyword to SQL type string.

**`quote-identifier (name)`** - Quote a SQL identifier (table or column name) with double quotes.

---

## Data Model - record objects with field access, model-level CRUD

Package: `fluxion.db.model`

### Class: `data-model`

A database record as a first-class object.
Provides field-level access without SQL.

Slots:

- **`collection`** - The collection (table) this model belongs to.
- **`id`** - The record's database ID, or NIL if not yet persisted.
- **`fields`** - Hash table of field-name -> value.

### Generic Functions

**`model-collection (object)`**

**`model-field-table (object)`**

**`model-id (object)`**

### Functions

**`alist-to-model (collection alist)`** - Create a data model for COLLECTION from ALIST.
If ALIST contains an "_id" key, it is set as the model ID.

**`delete-model (model)`** - Delete MODEL from the database.

**`get-all (collection query &key fields skip amount sort unique)`** - Select records from COLLECTION matching QUERY, returning data models.

**`get-one (collection query &key fields)`** - Select a single record from COLLECTION matching QUERY, returning a data model or NIL.

**`hull (collection)`** - Create an empty, unsaved data model for COLLECTION.
This is a blank record ready to have fields set on it.

**`hull-p (model)`** - Return T if MODEL is an empty hull (no ID and no fields set).

**`insert-model (model)`** - Insert MODEL into the database. Sets MODEL's ID from the returned value.
Returns MODEL.

**`model-field (model field)`** - Get the value of FIELD (string) from MODEL.

**`model-fields (model)`** - Return a list of field name strings for MODEL.

**`model-new-p (model)`** - Return T if MODEL has not yet been persisted (no ID).

**`model-to-alist (model)`** - Convert MODEL's fields to an alist of (field-name . value) pairs.
Includes _id if set.

**`save (model)`** - Save MODEL to the database.
If the model is new (no ID), inserts it.
If the model has an ID, updates the existing record.

---

