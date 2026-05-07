;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Migration system tests

(in-package #:fluxion.db.tests)

(def-suite :migrate-suite
  :description "Migration system tests"
  :in :db-suite)

(in-suite :migrate-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-migrate-db (&body body)
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (fluxion.db:*backend* backend))
     (fluxion.db:connect backend)
     (unwind-protect
          (progn
            (fluxion.migrate:setup)
            (fluxion.migrate:clear-migrations)
            ,@body)
       (fluxion.migrate:clear-migrations)
       (fluxion.db:disconnect backend))))

;;; -------------------------------------------------------
;;; Registration
;;; -------------------------------------------------------

(test migrate-define-migration
  "define-migration registers a migration"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil)
      :description "Initial schema")
    (let ((migs (fluxion.migrate:migrations-for "test-app")))
      (is (= 1 (length migs)))
      (is (= 1 (fluxion.migrate::migration-version (first migs)))))))

(test migrate-define-multiple-sorted
  "Migrations are sorted by version"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 3
      :up (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 2
      :up (lambda () nil))
    (let ((versions (mapcar #'fluxion.migrate::migration-version
                            (fluxion.migrate:migrations-for "test-app"))))
      (is (equal '(1 2 3) versions)))))

(test migrate-replace-existing
  "Redefining a migration replaces it"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil) :description "old")
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil) :description "new")
    (let ((migs (fluxion.migrate:migrations-for "test-app")))
      (is (= 1 (length migs)))
      (is (string= "new" (fluxion.migrate::migration-description (first migs)))))))

;;; -------------------------------------------------------
;;; Running migrations
;;; -------------------------------------------------------

(test migrate-runs-pending
  "migrate runs all pending migrations"
  (with-migrate-db
    (let ((log '()))
      (fluxion.migrate:define-migration "test-app" 1
        :up (lambda () (push 1 log)))
      (fluxion.migrate:define-migration "test-app" 2
        :up (lambda () (push 2 log)))
      (let ((count (fluxion.migrate:migrate "test-app")))
        (is (= 2 count))
        (is (equal '(2 1) log))
        (is (= 2 (fluxion.migrate:current-version "test-app")))))))

(test migrate-skips-applied
  "migrate skips already-applied migrations"
  (with-migrate-db
    (let ((counter 0))
      (fluxion.migrate:define-migration "test-app" 1
        :up (lambda () (incf counter)))
      (fluxion.migrate:define-migration "test-app" 2
        :up (lambda () (incf counter)))
      (fluxion.migrate:migrate "test-app")
      (is (= 2 counter))
      ;; Run again
      (fluxion.migrate:migrate "test-app")
      (is (= 2 counter)))))

(test migrate-to-version
  "migrate :to limits execution"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 2
      :up (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 3
      :up (lambda () nil))
    (fluxion.migrate:migrate "test-app" :to 2)
    (is (= 2 (fluxion.migrate:current-version "test-app")))
    ;; Version 3 is still pending
    (is (= 1 (length (fluxion.migrate:pending "test-app"))))))

(test migrate-current-version-default
  "current-version returns 0 when no migrations applied"
  (with-migrate-db
    (is (= 0 (fluxion.migrate:current-version "nonexistent")))))

(test migrate-pending-list
  "pending returns unapplied migrations"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 2
      :up (lambda () nil))
    (is (= 2 (length (fluxion.migrate:pending "test-app"))))
    (fluxion.migrate:migrate "test-app" :to 1)
    (is (= 1 (length (fluxion.migrate:pending "test-app"))))))

(test migrate-history
  "history returns applied migration records"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil) :description "Create tables")
    (fluxion.migrate:migrate "test-app")
    (let ((hist (fluxion.migrate:history "test-app")))
      (is (= 1 (length hist)))
      (is (string= "Create tables"
                    (cdr (assoc "description" (first hist) :test #'string=)))))))

;;; -------------------------------------------------------
;;; Rollback
;;; -------------------------------------------------------

(test migrate-rollback-one
  "rollback reverses the last migration"
  (with-migrate-db
    (let ((state '()))
      (fluxion.migrate:define-migration "test-app" 1
        :up (lambda () (push :v1-up state))
        :down (lambda () (push :v1-down state)))
      (fluxion.migrate:define-migration "test-app" 2
        :up (lambda () (push :v2-up state))
        :down (lambda () (push :v2-down state)))
      (fluxion.migrate:migrate "test-app")
      (is (= 2 (fluxion.migrate:current-version "test-app")))
      (fluxion.migrate:rollback "test-app")
      (is (= 1 (fluxion.migrate:current-version "test-app")))
      (is (eq :v2-down (first state))))))

(test migrate-rollback-multiple
  "rollback :steps rolls back multiple"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil) :down (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 2
      :up (lambda () nil) :down (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 3
      :up (lambda () nil) :down (lambda () nil))
    (fluxion.migrate:migrate "test-app")
    (let ((count (fluxion.migrate:rollback "test-app" :steps 2)))
      (is (= 2 count))
      (is (= 1 (fluxion.migrate:current-version "test-app"))))))

(test migrate-rollback-to-version
  "rollback-to rolls back to a specific version"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil) :down (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 2
      :up (lambda () nil) :down (lambda () nil))
    (fluxion.migrate:define-migration "test-app" 3
      :up (lambda () nil) :down (lambda () nil))
    (fluxion.migrate:migrate "test-app")
    (fluxion.migrate:rollback-to "test-app" 1)
    (is (= 1 (fluxion.migrate:current-version "test-app")))))

(test migrate-rollback-then-migrate
  "Rolled-back migrations can be re-applied"
  (with-migrate-db
    (let ((counter 0))
      (fluxion.migrate:define-migration "test-app" 1
        :up (lambda () (incf counter))
        :down (lambda () (decf counter)))
      (fluxion.migrate:migrate "test-app")
      (is (= 1 counter))
      (fluxion.migrate:rollback "test-app")
      (is (= 0 counter))
      (fluxion.migrate:migrate "test-app")
      (is (= 1 counter)))))

;;; -------------------------------------------------------
;;; Error handling
;;; -------------------------------------------------------

(test migrate-error-no-up
  "Error when :up is missing"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :down (lambda () nil))
    (signals fluxion.migrate::migration-error
      (fluxion.migrate:migrate "test-app"))))

(test migrate-error-no-down
  "Error on rollback when :down is missing"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () nil))
    (fluxion.migrate:migrate "test-app")
    (signals fluxion.migrate::migration-error
      (fluxion.migrate:rollback "test-app"))))

(test migrate-error-in-up
  "Error in :up is wrapped in migration-error"
  (with-migrate-db
    (fluxion.migrate:define-migration "test-app" 1
      :up (lambda () (error "boom")))
    (signals fluxion.migrate::migration-error
      (fluxion.migrate:migrate "test-app"))))

;;; -------------------------------------------------------
;;; Module isolation
;;; -------------------------------------------------------

(test migrate-modules-independent
  "Different modules have independent migration state"
  (with-migrate-db
    (fluxion.migrate:define-migration "app-a" 1
      :up (lambda () nil))
    (fluxion.migrate:define-migration "app-b" 1
      :up (lambda () nil))
    (fluxion.migrate:define-migration "app-b" 2
      :up (lambda () nil))
    (fluxion.migrate:migrate "app-a")
    (fluxion.migrate:migrate "app-b")
    (is (= 1 (fluxion.migrate:current-version "app-a")))
    (is (= 2 (fluxion.migrate:current-version "app-b")))))
