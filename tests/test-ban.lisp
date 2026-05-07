;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Ban system tests

(in-package #:fluxion.db.tests)

(def-suite :ban-suite
  :description "Ban system tests"
  :in :db-suite)

(in-suite :ban-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-ban-db (&body body)
  "Set up an in-memory SQLite backend with ban tables and run BODY."
  `(let* ((backend (fluxion.db.sqlite:make-sqlite-backend :database ":memory:"))
          (fluxion.db:*backend* backend))
     (fluxion.db:connect backend)
     (unwind-protect
          (progn
            (fluxion.ban:setup)
            ,@body)
       (fluxion.db:disconnect backend))))

;;; -------------------------------------------------------
;;; Setup
;;; -------------------------------------------------------

(test ban-setup-creates-table
  "setup creates the bans table"
  (with-ban-db
    (is (fluxion.db:collection-exists-p "fluxion_bans"))))

(test ban-setup-idempotent
  "setup can be called multiple times"
  (with-ban-db
    (fluxion.ban:setup)
    (is (fluxion.db:collection-exists-p "fluxion_bans"))))

;;; -------------------------------------------------------
;;; Jail and release
;;; -------------------------------------------------------

(test ban-jail-permanent
  "Permanent ban marks IP as banned"
  (with-ban-db
    (fluxion.ban:jail "192.168.1.100")
    (is (fluxion.ban:banned-p "192.168.1.100"))))

(test ban-jail-with-duration
  "Timed ban marks IP as banned"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.5" :duration 3600)
    (is (fluxion.ban:banned-p "10.0.0.5"))))

(test ban-jail-with-reason
  "Ban stores reason"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.5" :reason "brute force")
    (let ((bans (fluxion.ban:list-bans)))
      (is (= 1 (length bans)))
      (is (string= "brute force"
                    (cdr (assoc "reason" (first bans) :test #'string=)))))))

(test ban-release
  "Release removes the ban"
  (with-ban-db
    (fluxion.ban:jail "192.168.1.100")
    (is (fluxion.ban:banned-p "192.168.1.100"))
    (fluxion.ban:release "192.168.1.100")
    (is (not (fluxion.ban:banned-p "192.168.1.100")))))

(test ban-release-idempotent
  "Release on unbanned IP does not error"
  (with-ban-db
    (finishes (fluxion.ban:release "10.0.0.1"))))

(test ban-not-banned
  "banned-p returns NIL for unbanned IP"
  (with-ban-db
    (is (not (fluxion.ban:banned-p "10.0.0.1")))))

(test ban-jail-upsert
  "Banning same IP twice updates the ban"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.5" :reason "first")
    (fluxion.ban:jail "10.0.0.5" :reason "second")
    (let ((bans (fluxion.ban:list-bans)))
      (is (= 1 (length bans)))
      (is (string= "second"
                    (cdr (assoc "reason" (first bans) :test #'string=)))))))

;;; -------------------------------------------------------
;;; Jail time
;;; -------------------------------------------------------

(test ban-jail-time-permanent
  "jail-time returns :permanent for permanent bans"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.5")
    (is (eq :permanent (fluxion.ban:jail-time "10.0.0.5")))))

(test ban-jail-time-timed
  "jail-time returns seconds remaining for timed bans"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.5" :duration 3600)
    (let ((remaining (fluxion.ban:jail-time "10.0.0.5")))
      (is (integerp remaining))
      (is (> remaining 3590)))))

(test ban-jail-time-not-banned
  "jail-time returns NIL for unbanned IP"
  (with-ban-db
    (is (null (fluxion.ban:jail-time "10.0.0.1")))))

;;; -------------------------------------------------------
;;; List and clear
;;; -------------------------------------------------------

(test ban-list-bans
  "list-bans returns all active bans"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.1")
    (fluxion.ban:jail "10.0.0.2")
    (fluxion.ban:jail "10.0.0.3")
    (is (= 3 (length (fluxion.ban:list-bans))))))

(test ban-list-excludes-expired
  "list-bans excludes expired bans"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.1")
    ;; Create an expired ban by manipulating the DB directly
    (fluxion.db:insert "fluxion_bans"
                       `(("ip" . "10.0.0.2")
                         ("reason" . "")
                         ("banned_at" . ,(- (get-universal-time) 7200))
                         ("expires_at" . ,(- (get-universal-time) 3600))))
    (let ((bans (fluxion.ban:list-bans)))
      (is (= 1 (length bans)))
      (is (string= "10.0.0.1"
                    (cdr (assoc "ip" (first bans) :test #'string=)))))))

(test ban-clear-expired
  "clear-expired removes only expired bans"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.1")  ; permanent
    ;; Insert an expired ban
    (fluxion.db:insert "fluxion_bans"
                       `(("ip" . "10.0.0.2")
                         ("reason" . "")
                         ("banned_at" . ,(- (get-universal-time) 7200))
                         ("expires_at" . ,(- (get-universal-time) 3600))))
    (let ((removed (fluxion.ban:clear-expired)))
      (is (= 1 removed))
      ;; Permanent ban still exists
      (is (fluxion.ban:banned-p "10.0.0.1")))))

;;; -------------------------------------------------------
;;; Middleware
;;; -------------------------------------------------------

(test ban-middleware-allows-unbanned
  "Middleware passes through unbanned requests"
  (with-ban-db
    (let* ((inner (lambda (env) (declare (ignore env)) '(200 () ("OK"))))
           (mw (fluxion.ban:make-ban-middleware))
           (handler (funcall mw inner))
           (env (list :remote-addr "10.0.0.1")))
      (let ((response (funcall handler env)))
        (is (= 200 (first response)))))))

(test ban-middleware-blocks-banned
  "Middleware returns 403 for banned IPs"
  (with-ban-db
    (fluxion.ban:jail "10.0.0.1")
    (let* ((inner (lambda (env) (declare (ignore env)) '(200 () ("OK"))))
           (mw (fluxion.ban:make-ban-middleware))
           (handler (funcall mw inner))
           (env (list :remote-addr "10.0.0.1")))
      (let ((response (funcall handler env)))
        (is (= 403 (first response)))))))
