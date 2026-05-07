;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Ban system (fluxion.ban)
;;;;
;;;; IP-based access control with optional duration and database persistence.
;;;;
;;;; Usage:
;;;;   (ban:jail "192.168.1.100")                    ; permanent ban
;;;;   (ban:jail "10.0.0.5" :duration 3600)          ; 1 hour ban
;;;;   (ban:jail "10.0.0.5" :reason "brute force")   ; with reason
;;;;   (ban:release "192.168.1.100")                  ; unban
;;;;   (ban:banned-p "192.168.1.100")                 ; => T or NIL
;;;;   (ban:jail-time "10.0.0.5")                     ; seconds remaining
;;;;   (ban:list-bans)                                ; all active bans
;;;;
;;;; Middleware integration:
;;;;   (ban:make-ban-middleware)  ; returns Clack middleware

(defpackage #:fluxion.ban
  (:use #:cl)
  (:local-nicknames (#:db #:fluxion.db)
                    (#:q #:fluxion.db.query))
  (:export
   ;; Core API
   #:setup
   #:jail
   #:release
   #:banned-p
   #:jail-time
   #:list-bans
   #:clear-expired

   ;; Middleware
   #:make-ban-middleware))

(in-package #:fluxion.ban)

;;; -------------------------------------------------------
;;; Table definition
;;; -------------------------------------------------------

(defparameter *bans-table* "fluxion_bans"
  "Name of the bans table.")

(defparameter *bans-structure*
  '((ip :text)
    (reason :text)
    (banned_at :integer)
    (expires_at :integer))
  "Structure for the bans table.
expires_at = 0 means permanent ban.")

;;; -------------------------------------------------------
;;; Setup
;;; -------------------------------------------------------

(defun setup ()
  "Create the bans table if it does not exist. Idempotent."
  (unless (db:collection-exists-p *bans-table*)
    (db:create *bans-table* *bans-structure*)))

;;; -------------------------------------------------------
;;; Core API
;;; -------------------------------------------------------

(defun jail (ip &key (duration nil) (reason ""))
  "Ban an IP address.
DURATION is optional seconds until expiry (NIL = permanent).
REASON is an optional description.
If the IP is already banned, the ban is updated."
  (let ((now (get-universal-time))
        (expires (if duration
                     (+ (get-universal-time) duration)
                     0)))
    ;; Remove existing ban for this IP (upsert)
    (handler-case
        (db:remove *bans-table* (q:compile-query `(:= ip ,ip)))
      (error () nil))
    (db:insert *bans-table*
               `(("ip" . ,ip)
                 ("reason" . ,reason)
                 ("banned_at" . ,now)
                 ("expires_at" . ,expires)))))

(defun release (ip)
  "Remove the ban on IP. Idempotent (no error if not banned)."
  (handler-case
      (db:remove *bans-table* (q:compile-query `(:= ip ,ip)))
    (error () nil)))

(defun banned-p (ip)
  "Return T if IP is currently banned, NIL otherwise.
Expired bans are treated as not banned (and cleaned up)."
  (let ((row (db:select-one *bans-table*
                            (q:compile-query `(:= ip ,ip)))))
    (when row
      (let ((expires (cdr (assoc "expires_at" row :test #'string=))))
        (cond
          ;; Permanent ban (expires_at = 0)
          ((or (null expires) (zerop expires)) t)
          ;; Not yet expired
          ((> expires (get-universal-time)) t)
          ;; Expired: clean up and return NIL
          (t (release ip) nil))))))

(defun jail-time (ip)
  "Return seconds remaining on the ban for IP, or NIL if not banned.
Returns :permanent for permanent bans."
  (let ((row (db:select-one *bans-table*
                            (q:compile-query `(:= ip ,ip)))))
    (when row
      (let ((expires (cdr (assoc "expires_at" row :test #'string=))))
        (cond
          ((or (null expires) (zerop expires)) :permanent)
          ((> expires (get-universal-time))
           (- expires (get-universal-time)))
          (t (release ip) nil))))))

(defun list-bans ()
  "Return a list of all active ban records (alists).
Expired bans are excluded."
  (let ((all (db:select *bans-table* (q:compile-query :all)))
        (now (get-universal-time)))
    (remove-if (lambda (row)
                 (let ((expires (cdr (assoc "expires_at" row :test #'string=))))
                   (and expires (plusp expires) (<= expires now))))
               all)))

(defun clear-expired ()
  "Remove all expired bans from the database.
Returns the number of bans removed."
  (let* ((now (get-universal-time))
         (expired (db:select *bans-table*
                             (q:compile-query `(:and (:> expires_at 0)
                                                     (:<= expires_at ,now))))))
    (when expired
      (db:remove *bans-table*
                 (q:compile-query `(:and (:> expires_at 0)
                                         (:<= expires_at ,now)))))
    (length expired)))

;;; -------------------------------------------------------
;;; Middleware
;;; -------------------------------------------------------

(defun make-ban-middleware (&key (response-code 403)
                                 (response-body "Forbidden"))
  "Return a Clack middleware that rejects requests from banned IPs.
RESPONSE-CODE: HTTP status for banned requests (default 403).
RESPONSE-BODY: response body string."
  (lambda (handler)
    (lambda (env)
      (let ((ip (getf env :remote-addr)))
        (if (and ip (banned-p ip))
            (list response-code
                  '(:content-type "text/plain")
                  (list response-body))
            (funcall handler env))))))
