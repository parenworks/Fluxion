;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Live server-rendered interfaces for Common Lisp

(defsystem "fluxion"
  :name "fluxion"
  :version "1.0.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "A Common Lisp framework for live, server-driven reactive web interfaces built around CLOS."
  :depends-on ("alexandria"
               "spinneret"
               "clack"
               "lack"
               "cl-json"
               "babel"
               "ironclad"
               "bordeaux-threads"
               "hunchentoot"
               "clack-handler-woo"
               "cl-ppcre")
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "package")
     (:file "protocol")
     (:file "events")
     (:file "signals")
     (:file "components")
     (:file "cells")
     (:file "render")
     (:file "validation")
     (:file "conditions")
     (:file "csrf")
     (:file "event-queue")
     (:file "session")
     (:file "session-store")
     (:file "auth")
     (:file "app")
     (:file "middleware")
     (:file "router")
     (:file "reaper")
     (:file "handler")))))

(defsystem "fluxion/tests"
  :name "fluxion-tests"
  :version "0.1.0"
  :description "Test suite for Fluxion."
  :depends-on ("fluxion" "fluxion/client" "fiveam" "dexador" "usocket")
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "package")
     (:file "test-protocol")
     (:file "test-events")
     (:file "test-cells")
     (:file "test-computed")
     (:file "test-transactions")
     (:file "test-thread-safety")
     (:file "test-session-reaper")
     (:file "test-propagators")
     (:file "test-convergence")
     (:file "test-middleware")
     (:file "test-lifecycle")
     (:file "test-composition")
     (:file "test-components")
     (:file "test-server")
     (:file "test-router")
     (:file "test-validation")
     (:file "test-observability")
     (:file "test-integration")))))

(defsystem "fluxion/client"
  :name "fluxion-client"
  :version "0.1.0"
  :description "Parenscript browser runtime for Fluxion."
  :depends-on ("parenscript" "fluxion")
  :serial t
  :components
  ((:module "client"
    :serial t
    :components
    ((:file "package")
     (:file "runtime")))))

(defsystem "fluxion/examples"
  :name "fluxion-examples"
  :version "0.1.0"
  :description "Example applications for Fluxion."
  :depends-on ("fluxion" "fluxion/client")
  :serial t
  :components
  ((:module "examples"
    :serial t
    :components
    ((:file "counter")
     (:file "todo")
     (:file "converter")
     (:file "colour-picker")))))

(defsystem "fluxion/db"
  :name "fluxion-db"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Database abstraction layer for Fluxion. Query DSL, data model, and backend protocol."
  :depends-on ("alexandria")
  :serial t
  :components
  ((:module "db"
    :serial t
    :components
    ((:file "package")
     (:file "conditions")
     (:file "query")
     (:file "backend")
     (:file "model")))))

(defsystem "fluxion/rdb"
  :name "fluxion-rdb"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Relational database extension for Fluxion. Joins and raw SQL."
  :depends-on ("fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "rdb")))))

(defsystem "fluxion/db-sqlite"
  :name "fluxion-db-sqlite"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "SQLite backend for the Fluxion database layer."
  :depends-on ("fluxion/db" "fluxion/rdb" "sqlite")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "sqlite")))))

(defsystem "fluxion/db-pg"
  :name "fluxion-db-postgresql"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "PostgreSQL backend for the Fluxion database layer."
  :depends-on ("fluxion/db" "fluxion/rdb" "postmodern")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "postgresql")))))

(defsystem "fluxion/user"
  :name "fluxion-user"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "User/account system for Fluxion with extensible fields and hierarchical permissions."
  :depends-on ("fluxion/db" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "user")))))

(defsystem "fluxion/auth"
  :name "fluxion-auth"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Authentication interface for Fluxion. Login/logout and session binding."
  :depends-on ("fluxion" "fluxion/user" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "auth")))))

(defsystem "fluxion/ban"
  :name "fluxion-ban"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "IP-based ban system for Fluxion with database persistence."
  :depends-on ("fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "ban")))))

(defsystem "fluxion/rate"
  :name "fluxion-rate"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Granular per-resource rate limiting for Fluxion."
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "rate")))))

(defsystem "fluxion/cache"
  :name "fluxion-cache"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Named caching interface with TTL and multiple backends."
  :depends-on ("fluxion/db" "bordeaux-threads" "babel" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "cache")))))

(defsystem "fluxion/profile"
  :name "fluxion-profile"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Extensible user profile system for Fluxion."
  :depends-on ("fluxion/user" "babel" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "profile")))))

(defsystem "fluxion/mail"
  :name "fluxion-mail"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Minimal email sending with pluggable backends."
  :depends-on ()
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "mail")))))

(defsystem "fluxion/migrate"
  :name "fluxion-migrate"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Versioned schema migrations with sequential execution and rollback."
  :depends-on ("fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "migrate")))))

(defsystem "fluxion/hooks"
  :name "fluxion-hooks"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Inter-module hooks and triggers for event communication."
  :depends-on ()
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "hooks")))))

(defsystem "fluxion/api"
  :name "fluxion-api"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "REST API endpoint system with JSON serialization."
  :depends-on ("fluxion" "cl-json" "babel")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "api")))))

(defsystem "fluxion/log"
  :name "fluxion-log"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Structured, leveled logging with swappable backends."
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "log")))))

(defsystem "fluxion/config"
  :name "fluxion-config"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Per-module persistent configuration with s-expression storage."
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "config")))))

(defsystem "fluxion/session-db"
  :name "fluxion-session-db"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "Database-backed session persistence for Fluxion."
  :depends-on ("fluxion" "fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "session-store")))))

(defsystem "fluxion/db-tests"
  :name "fluxion-db-tests"
  :version "0.1.0"
  :description "Test suite for the Fluxion database layer."
  :depends-on ("fluxion/db" "fluxion/rdb" "fluxion/db-sqlite"
               "fluxion/session-db" "fluxion/user" "fluxion/auth"
               "fluxion/ban" "fluxion/rate"
               "fluxion/cache" "fluxion/profile" "fluxion/mail"
               "fluxion/migrate" "fluxion/hooks"
               "fluxion/log" "fluxion/config"
               "fluxion/api"
               "fiveam")
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "test-db-package")
     (:file "test-db-query")
     (:file "test-db-contract")
     (:file "test-db-model")
     (:file "test-rdb")
     (:file "test-session-store")
     (:file "test-user")
     (:file "test-auth")
     (:file "test-ban")
     (:file "test-rate")
     (:file "test-cache")
     (:file "test-profile")
     (:file "test-mail")
     (:file "test-migrate")
     (:file "test-hooks")
     (:file "test-log")
     (:file "test-config")
     (:file "test-api")))))

(defsystem "fluxion/db-pg-tests"
  :name "fluxion-db-pg-tests"
  :version "0.1.0"
  :description "PostgreSQL contract tests for the Fluxion database layer."
  :depends-on ("fluxion/db-tests" "fluxion/db-pg" "fluxion/db-sqlite")
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "test-db-postgresql")))))
