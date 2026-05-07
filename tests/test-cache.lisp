;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Cache system tests

(in-package #:fluxion.db.tests)

(def-suite :cache-suite
  :description "Cache system tests"
  :in :db-suite)

(in-suite :cache-suite)

;;; -------------------------------------------------------
;;; Memory backend
;;; -------------------------------------------------------

(defmacro with-memory-cache (&body body)
  `(let ((fluxion.cache:*backend* (fluxion.cache:make-memory-cache-backend)))
     ,@body))

(test cache-put-and-get
  "Put a value and retrieve it"
  (with-memory-cache
    (fluxion.cache:put :greeting "hello" :ttl 60)
    (multiple-value-bind (val found)
        (fluxion.cache:get :greeting)
      (is (string= "hello" val))
      (is (eq t found)))))

(test cache-get-missing
  "Get returns NIL for missing keys"
  (with-memory-cache
    (multiple-value-bind (val found)
        (fluxion.cache:get :nonexistent)
      (is (null val))
      (is (null found)))))

(test cache-remove
  "Remove deletes an entry"
  (with-memory-cache
    (fluxion.cache:put :temp "value")
    (fluxion.cache:remove :temp)
    (is (null (fluxion.cache:exists-p :temp)))))

(test cache-clear
  "Clear removes all entries"
  (with-memory-cache
    (fluxion.cache:put :a "1")
    (fluxion.cache:put :b "2")
    (fluxion.cache:clear)
    (is (null (fluxion.cache:exists-p :a)))
    (is (null (fluxion.cache:exists-p :b)))))

(test cache-renew
  "Renew invalidates a cache entry"
  (with-memory-cache
    (fluxion.cache:put :data "old")
    (fluxion.cache:renew :data)
    (is (null (fluxion.cache:exists-p :data)))))

(test cache-exists-p
  "exists-p returns T for cached, NIL for missing"
  (with-memory-cache
    (is (not (fluxion.cache:exists-p :x)))
    (fluxion.cache:put :x "val")
    (is (fluxion.cache:exists-p :x))))

(test cache-variant
  "Variants are independent cache entries"
  (with-memory-cache
    (fluxion.cache:put :users "all" :variant "page-1")
    (fluxion.cache:put :users "more" :variant "page-2")
    (is (string= "all" (fluxion.cache:get :users "page-1")))
    (is (string= "more" (fluxion.cache:get :users "page-2")))
    ;; Removing one variant doesn't affect the other
    (fluxion.cache:remove :users "page-1")
    (is (null (fluxion.cache:exists-p :users "page-1")))
    (is (fluxion.cache:exists-p :users "page-2"))))

(test cache-no-ttl-persists
  "Entries without TTL never expire"
  (with-memory-cache
    (fluxion.cache:put :forever "value")
    (is (fluxion.cache:exists-p :forever))))

(test cache-with-cache-macro
  "with-cache caches the result of the body"
  (with-memory-cache
    (let ((counter 0))
      (flet ((compute ()
               (fluxion.cache:with-cache (:expensive 60)
                 (incf counter)
                 (format nil "result-~D" counter))))
        (is (string= "result-1" (compute)))
        (is (string= "result-1" (compute)))
        (is (= 1 counter))))))

(test cache-with-cache-regenerates-on-miss
  "with-cache regenerates when entry is missing"
  (with-memory-cache
    (let ((counter 0))
      (flet ((compute ()
               (fluxion.cache:with-cache (:gen 60)
                 (incf counter)
                 counter)))
        (is (= 1 (compute)))
        (fluxion.cache:renew :gen)
        (is (= 2 (compute)))))))

(test cache-gc-expired
  "gc-expired removes expired entries from memory"
  (with-memory-cache
    ;; Manually insert an expired entry
    (fluxion.cache::cache-put
     fluxion.cache:*backend* :old "stale" :ttl 0)
    ;; Force the created-at to the past
    (let ((store (fluxion.cache::backend-store fluxion.cache:*backend*)))
      (let ((entry (gethash :old store)))
        (setf (fluxion.cache::cache-entry-created-at entry)
              (- (get-universal-time) 100))))
    (let ((removed (fluxion.cache:gc-expired)))
      (is (= 1 removed)))
    (is (null (fluxion.cache:exists-p :old)))))

;;; -------------------------------------------------------
;;; DB backend
;;; -------------------------------------------------------

(defmacro with-db-cache (&body body)
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (fluxion.db:*backend* backend))
     (fluxion.db:connect backend)
     (unwind-protect
          (let ((fluxion.cache:*backend*
                  (fluxion.cache:make-db-cache-backend)))
            (fluxion.cache:setup fluxion.cache:*backend*)
            ,@body)
       (fluxion.db:disconnect backend))))

(test db-cache-put-and-get
  "DB backend: put and get"
  (with-db-cache
    (fluxion.cache:put :key "value" :ttl 60)
    (multiple-value-bind (val found)
        (fluxion.cache:get :key)
      (is (string= "value" val))
      (is (eq t found)))))

(test db-cache-remove
  "DB backend: remove"
  (with-db-cache
    (fluxion.cache:put :key "value")
    (fluxion.cache:remove :key)
    (is (null (fluxion.cache:exists-p :key)))))

(test db-cache-clear
  "DB backend: clear"
  (with-db-cache
    (fluxion.cache:put :a "1")
    (fluxion.cache:put :b "2")
    (fluxion.cache:clear)
    (is (null (fluxion.cache:exists-p :a)))
    (is (null (fluxion.cache:exists-p :b)))))

(test db-cache-variant
  "DB backend: variants are independent"
  (with-db-cache
    (fluxion.cache:put :k "v1" :variant "a")
    (fluxion.cache:put :k "v2" :variant "b")
    (is (string= "v1" (fluxion.cache:get :k "a")))
    (is (string= "v2" (fluxion.cache:get :k "b")))))

(test db-cache-upsert
  "DB backend: put overwrites existing entry"
  (with-db-cache
    (fluxion.cache:put :k "old")
    (fluxion.cache:put :k "new")
    (is (string= "new" (fluxion.cache:get :k)))))

(test db-cache-with-cache
  "DB backend: with-cache works"
  (with-db-cache
    (let ((counter 0))
      (flet ((compute ()
               (fluxion.cache:with-cache (:exp 60)
                 (incf counter)
                 (format nil "r-~D" counter))))
        (is (string= "r-1" (compute)))
        (is (string= "r-1" (compute)))
        (is (= 1 counter))))))
