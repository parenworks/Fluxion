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
  :description "Database abstraction layer with query DSL, data model, and backend protocol."
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
  :description "Relational database extension with joins and raw SQL."
  :depends-on ("fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "rdb")))))

(defsystem "fluxion/db-sqlite"
  :description "SQLite backend for the Fluxion database layer."
  :depends-on ("fluxion/db" "fluxion/rdb" "sqlite")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "sqlite")))))

(defsystem "fluxion/db-pg"
  :description "PostgreSQL backend for the Fluxion database layer."
  :depends-on ("fluxion/db" "fluxion/rdb" "postmodern")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "postgresql")))))

(defsystem "fluxion/user"
  :description "User/account system with extensible fields and hierarchical permissions."
  :depends-on ("fluxion/db" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "user")))))

(defsystem "fluxion/auth"
  :description "Authentication interface with login/logout and session binding."
  :depends-on ("fluxion" "fluxion/user" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "auth")))))

(defsystem "fluxion/ban"
  :description "IP-based ban system with database persistence."
  :depends-on ("fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "ban")))))

(defsystem "fluxion/rate"
  :description "Granular per-resource rate limiting."
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "rate")))))

(defsystem "fluxion/cache"
  :description "Named caching interface with TTL and multiple backends."
  :depends-on ("fluxion/db" "bordeaux-threads" "babel" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "cache")))))

(defsystem "fluxion/profile"
  :description "Extensible user profile system."
  :depends-on ("fluxion/user" "babel" "ironclad")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "profile")))))

(defsystem "fluxion/mail"
  :description "Minimal email sending with pluggable backends."
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "mail")))))

(defsystem "fluxion/migrate"
  :description "Versioned schema migrations with sequential execution and rollback."
  :depends-on ("fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "migrate")))))

(defsystem "fluxion/hooks"
  :description "Inter-module hooks and triggers for event communication."
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "hooks")))))

(defsystem "fluxion/api"
  :description "REST API endpoint system with JSON serialization."
  :depends-on ("fluxion" "cl-json" "babel")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "api")))))

(defsystem "fluxion/log"
  :description "Structured, leveled logging with swappable backends."
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "log")))))

(defsystem "fluxion/config"
  :description "Per-module persistent configuration with s-expression storage."
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "config")))))

(defsystem "fluxion/session-db"
  :description "Database-backed session persistence."
  :depends-on ("fluxion" "fluxion/db")
  :serial t
  :components
  ((:module "db"
    :components
    ((:file "session-store")))))

(defsystem "fluxion/db-tests"
  :description "Test suite for the Fluxion database and extension layers."
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
  :description "PostgreSQL contract tests for the Fluxion database layer."
  :depends-on ("fluxion/db-tests" "fluxion/db-pg" "fluxion/db-sqlite")
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "test-db-postgresql")))))
