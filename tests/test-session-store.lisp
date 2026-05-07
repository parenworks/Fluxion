;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Session persistence tests
;;;;
;;;; Tests the database-backed session store using SQLite in-memory.

(in-package #:fluxion.db.tests)

(def-suite :session-store-suite
  :description "Database session store tests"
  :in :db-suite)

(in-suite :session-store-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-session-store (&body body)
  "Set up an in-memory SQLite backend with a db-session-store and run BODY."
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (store (fluxion.session.db:make-db-session-store backend)))
     (fluxion.db:connect backend)
     (unwind-protect
          (progn
            (fluxion.server:store-setup store)
            ,@body)
       (fluxion.db:disconnect backend))))

(defun make-test-session (&key (id "test-session-001")
                               (user nil)
                               (roles nil))
  "Create a session for testing."
  (let ((s (make-instance 'fluxion.server:session :id id)))
    (when user
      (setf (fluxion.server:session-user s) user))
    (when roles
      (setf (fluxion.server:session-user-roles s) roles))
    s))

;;; -------------------------------------------------------
;;; Setup tests
;;; -------------------------------------------------------

(test session-store-setup-creates-table
  "store-setup creates the sessions table"
  (with-session-store
    (is (fluxion.db:collection-exists-p "fluxion_sessions"))))

(test session-store-setup-idempotent
  "store-setup can be called multiple times safely"
  (with-session-store
    (fluxion.server:store-setup store)
    (is (fluxion.db:collection-exists-p "fluxion_sessions"))))

;;; -------------------------------------------------------
;;; Store and load tests
;;; -------------------------------------------------------

(test session-store-roundtrip
  "Storing and loading a session preserves its fields"
  (with-session-store
    (let ((s (make-test-session :id "abc123")))
      (fluxion.server:store-session store s)
      (let ((loaded (fluxion.server:load-session store "abc123")))
        (is (not (null loaded)))
        (is (string= "abc123" (fluxion.server:session-id loaded)))
        (is (= (fluxion.server:session-created-at s)
               (fluxion.server:session-created-at loaded)))
        (is (= (fluxion.server:session-last-accessed-at s)
               (fluxion.server:session-last-accessed-at loaded)))
        (is (string= (fluxion.server:session-csrf-token s)
                      (fluxion.server:session-csrf-token loaded)))))))

(test session-store-with-user
  "Session user data survives roundtrip via prin1/read"
  (with-session-store
    (let ((s (make-test-session :id "user-sess"
                                :user '(:username "alice" :email "alice@example.com")
                                :roles '(:admin :editor))))
      (fluxion.server:store-session store s)
      (let ((loaded (fluxion.server:load-session store "user-sess")))
        (is (equal '(:username "alice" :email "alice@example.com")
                   (fluxion.server:session-user loaded)))
        (is (equal '(:admin :editor)
                   (fluxion.server:session-user-roles loaded)))))))

(test session-store-nil-user
  "Session with no user data loads back with NIL user"
  (with-session-store
    (let ((s (make-test-session :id "no-user")))
      (fluxion.server:store-session store s)
      (let ((loaded (fluxion.server:load-session store "no-user")))
        (is (null (fluxion.server:session-user loaded)))
        (is (null (fluxion.server:session-user-roles loaded)))))))

(test session-store-upsert
  "Storing a session twice updates rather than duplicates"
  (with-session-store
    (let ((s (make-test-session :id "upsert-test")))
      (fluxion.server:store-session store s)
      ;; Mutate and store again
      (setf (fluxion.server:session-user s) "updated-user")
      (fluxion.server:store-session store s)
      ;; Should only be one record
      (let ((all (fluxion.server:load-all-sessions store)))
        (is (= 1 (length all)))
        (is (equal "updated-user"
                   (fluxion.server:session-user (first all))))))))

(test session-load-nonexistent
  "Loading a nonexistent session returns NIL"
  (with-session-store
    (is (null (fluxion.server:load-session store "does-not-exist")))))

;;; -------------------------------------------------------
;;; Delete tests
;;; -------------------------------------------------------

(test session-delete
  "Deleting a session removes it from the store"
  (with-session-store
    (let ((s (make-test-session :id "delete-me")))
      (fluxion.server:store-session store s)
      (is (not (null (fluxion.server:load-session store "delete-me"))))
      (fluxion.server:delete-session store "delete-me")
      (is (null (fluxion.server:load-session store "delete-me"))))))

(test session-delete-nonexistent
  "Deleting a nonexistent session does not error"
  (with-session-store
    (finishes (fluxion.server:delete-session store "no-such-session"))))

;;; -------------------------------------------------------
;;; Load all tests
;;; -------------------------------------------------------

(test session-load-all
  "load-all-sessions returns all stored sessions"
  (with-session-store
    (fluxion.server:store-session store (make-test-session :id "s1"))
    (fluxion.server:store-session store (make-test-session :id "s2"))
    (fluxion.server:store-session store (make-test-session :id "s3"))
    (let ((all (fluxion.server:load-all-sessions store)))
      (is (= 3 (length all)))
      (is (member "s1" all :key #'fluxion.server:session-id :test #'string=))
      (is (member "s2" all :key #'fluxion.server:session-id :test #'string=))
      (is (member "s3" all :key #'fluxion.server:session-id :test #'string=)))))

(test session-load-all-empty
  "load-all-sessions returns empty list when no sessions"
  (with-session-store
    (is (null (fluxion.server:load-all-sessions store)))))

;;; -------------------------------------------------------
;;; Garbage collection tests
;;; -------------------------------------------------------

(test session-gc-removes-expired
  "gc-sessions removes sessions older than TTL"
  (with-session-store
    (let ((old (make-test-session :id "old-session"))
          (fresh (make-test-session :id "fresh-session")))
      ;; Make old-session appear stale
      (setf (fluxion.server:session-last-accessed-at old)
            (- (get-universal-time) 7200))
      (fluxion.server:store-session store old)
      (fluxion.server:store-session store fresh)
      ;; GC with 1 hour TTL
      (let ((removed (fluxion.server:gc-sessions store 3600)))
        (is (= 1 removed))
        (is (null (fluxion.server:load-session store "old-session")))
        (is (not (null (fluxion.server:load-session store "fresh-session"))))))))

(test session-gc-none-expired
  "gc-sessions returns 0 when nothing is expired"
  (with-session-store
    (fluxion.server:store-session store (make-test-session :id "active"))
    (is (= 0 (fluxion.server:gc-sessions store 3600)))))

;;; -------------------------------------------------------
;;; Memory store tests
;;; -------------------------------------------------------

(test memory-store-noop
  "Memory session store methods are no-ops"
  (let ((store (make-instance 'fluxion.server:memory-session-store)))
    (finishes (fluxion.server:store-setup store))
    (finishes (fluxion.server:store-session store (make-test-session)))
    (is (null (fluxion.server:load-session store "any")))
    (finishes (fluxion.server:delete-session store "any"))
    (is (null (fluxion.server:load-all-sessions store)))
    (is (= 0 (fluxion.server:gc-sessions store 3600)))))
