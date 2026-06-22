;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Package definitions
;;;;
;;;; Three packages:
;;;;   fluxion.db       - The contract (generic functions, conditions, query DSL)
;;;;   fluxion.db.model - Data model objects (hull, field access, CRUD)
;;;;   fluxion.db.query - Query DSL compiler (s-expressions to SQL)
;;;;
;;;; Backend packages are defined in their own files:
;;;;   fluxion.db.sqlite      - SQLite backend
;;;;   fluxion.db.postgresql   - PostgreSQL backend

(defpackage #:fluxion.db.query
  (:use #:cl)
  (:export
   ;; Query compiler
   #:compile-query
   #:compile-fields
   #:compile-sort
   #:compile-create-table
   #:compile-alter-table
   #:compile-insert
   #:compile-update
   #:compile-delete
   #:compile-select
   ;; Helpers for backends
   #:field-name-sql
   #:quote-identifier
   #:field-type-sql
   ;; Query constructor
   #:query))

(defpackage #:fluxion.db
  (:use #:cl)
  (:nicknames #:fxdb)
  (:shadow #:count #:remove #:delete)
  (:export
   ;; Backend protocol
   #:backend
   #:backend-name
   #:backend-connected-p
   #:*backend*
   #:current-backend

   ;; Connection management
   #:connect
   #:disconnect
   #:connected-p
   #:with-connection

   ;; Collection (table) management
   #:collections
   #:collection-exists-p
   #:create
   #:drop
   #:empty
   #:alter
   #:collection-structure

   ;; Data operations
   #:insert
   #:select
   #:select-one
   #:count
   #:update
   #:remove
   #:iterate
   #:with-transaction

   ;; Convenience
   #:find-by-id
   #:delete-by-id
   #:exists-p

   ;; Query DSL (imported and re-exported from fluxion.db.query)
   #:query
   #:compile-query

   ;; Conditions
   #:database-error
   #:database-error-message
   #:connection-failed
   #:connection-already-open
   #:collection-error
   #:collection-error-name
   #:invalid-collection
   #:collection-already-exists
   #:invalid-field
   #:invalid-field-name

   ;; Types
   #:field-type
   #:id
   #:ensure-id

   ;; Backend protocol generics (for backend implementations)
   #:%collections
   #:%collection-exists-p
   #:%create
   #:%drop
   #:%empty
   #:%alter
   #:%collection-structure
   #:select-query
   #:%select-query
   #:update-expr
   #:%update-expr
   #:ensure-index
   #:%ensure-index
   #:%insert
   #:%select
   #:%count
   #:%update
   #:%remove
   #:%iterate
   #:%execute-transaction))

(defpackage #:fluxion.db.model
  (:use #:cl)
  (:nicknames #:fxdm)
  (:export
   ;; Data model
   #:data-model
   #:model-collection
   #:model-id
   #:model-fields
   #:model-field
   #:model-field-table
   #:model-new-p
   #:hull
   #:hull-p

   ;; CRUD via data model
   #:get-all
   #:get-one
   #:save
   #:insert-model
   #:delete-model

   ;; Conversion
   #:model-to-alist
   #:alist-to-model))
