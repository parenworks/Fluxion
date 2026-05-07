;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - Test package and suite definitions

(defpackage #:fluxion.db.tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:db #:fluxion.db)
                    (#:q #:fluxion.db.query)
                    (#:dm #:fluxion.db.model))
  (:export #:run-db-tests))

(in-package #:fluxion.db.tests)

(def-suite :db-suite
  :description "Fluxion database layer tests")

(def-suite :db-query-suite
  :description "Query DSL tests"
  :in :db-suite)

(def-suite :db-contract-suite
  :description "Backend contract tests (run against each backend)"
  :in :db-suite)

(def-suite :db-model-suite
  :description "Data model tests"
  :in :db-suite)

(defun run-db-tests ()
  (run! :db-suite))
