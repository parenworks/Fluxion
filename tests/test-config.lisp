;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Configuration system tests

(in-package #:fluxion.db.tests)

(def-suite :config-suite
  :description "Configuration system tests"
  :in :db-suite)

(in-suite :config-suite)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defmacro with-clean-config (&body body)
  `(progn
     ;; Clear all state
     (clrhash fluxion.config::*defaults*)
     (clrhash fluxion.config::*values*)
     (setf fluxion.config:*config-path* nil)
     (setf fluxion.config:*on-change* nil)
     (unwind-protect (progn ,@body)
       (clrhash fluxion.config::*defaults*)
       (clrhash fluxion.config::*values*)
       (setf fluxion.config:*config-path* nil)
       (setf fluxion.config:*on-change* nil))))

;;; -------------------------------------------------------
;;; Section definition
;;; -------------------------------------------------------

(test config-define-section
  "define-section registers defaults"
  (with-clean-config
    (fluxion.config:define-section :database
      (:host "localhost")
      (:port 5432))
    (is (member :database (fluxion.config:sections)))
    (is (equal '(:host :port) (fluxion.config:section-keys :database)))))

(test config-undefine-section
  "undefine-section removes section"
  (with-clean-config
    (fluxion.config:define-section :temp (:key "val"))
    (fluxion.config:undefine-section :temp)
    (is (not (member :temp (fluxion.config:sections))))))

(test config-section-defaults
  "section-defaults returns default alist"
  (with-clean-config
    (fluxion.config:define-section :app (:name "test") (:debug nil))
    (let ((defs (fluxion.config:section-defaults :app)))
      (is (string= "test" (cdr (assoc :name defs))))
      (is (null (cdr (assoc :debug defs)))))))

;;; -------------------------------------------------------
;;; Get / Set
;;; -------------------------------------------------------

(test config-get-default
  "get returns default when no override set"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (is (string= "localhost" (fluxion.config:get :db :host)))))

(test config-get-fallback
  "get returns fallback when key not in section"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (is (eq :missing (fluxion.config:get :db :nonexistent :missing)))))

(test config-set-overrides
  "set overrides the default"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (fluxion.config:set :db :host "production-db")
    (is (string= "production-db" (fluxion.config:get :db :host)))))

(test config-set-new-key
  "set can add keys not in defaults"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (fluxion.config:set :db :password "secret")
    (is (string= "secret" (fluxion.config:get :db :password)))))

;;; -------------------------------------------------------
;;; Reset
;;; -------------------------------------------------------

(test config-reset-key
  "reset restores a key to default"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (fluxion.config:set :db :host "custom")
    (fluxion.config:reset :db :host)
    (is (string= "localhost" (fluxion.config:get :db :host)))))

(test config-reset-section
  "reset-section restores all keys in a section"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost") (:port 5432))
    (fluxion.config:set :db :host "custom")
    (fluxion.config:set :db :port 9999)
    (fluxion.config:reset-section :db)
    (is (string= "localhost" (fluxion.config:get :db :host)))
    (is (= 5432 (fluxion.config:get :db :port)))))

(test config-reset-all
  "reset-all restores all sections"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (fluxion.config:define-section :app (:name "test"))
    (fluxion.config:set :db :host "x")
    (fluxion.config:set :app :name "y")
    (fluxion.config:reset-all)
    (is (string= "localhost" (fluxion.config:get :db :host)))
    (is (string= "test" (fluxion.config:get :app :name)))))

;;; -------------------------------------------------------
;;; On-change hook
;;; -------------------------------------------------------

(test config-on-change-fires
  "on-change fires when value changes"
  (with-clean-config
    (let ((changes '()))
      (fluxion.config:define-section :db (:host "localhost"))
      (setf fluxion.config:*on-change*
            (lambda (section key old new)
              (push (list section key old new) changes)))
      (fluxion.config:set :db :host "new-host")
      (is (= 1 (length changes)))
      (is (equal '(:db :host "localhost" "new-host") (first changes))))))

(test config-on-change-skips-same
  "on-change does not fire when value is unchanged"
  (with-clean-config
    (let ((count 0))
      (fluxion.config:define-section :db (:host "localhost"))
      (setf fluxion.config:*on-change*
            (lambda (section key old new)
              (declare (ignore section key old new))
              (incf count)))
      (fluxion.config:set :db :host "localhost")
      (is (= 0 count)))))

;;; -------------------------------------------------------
;;; Persistence (save/load)
;;; -------------------------------------------------------

(test config-save-and-load
  "Config round-trips through save/load"
  (with-clean-config
    (let ((path (merge-pathnames
                 (format nil "fluxion-test-config-~D.lisp" (get-universal-time))
                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (fluxion.config:define-section :db
               (:host "localhost") (:port 5432))
             (fluxion.config:set :db :host "production")
             (fluxion.config:save-to path)
             ;; Reset and reload
             (fluxion.config:reset-all)
             (is (string= "localhost" (fluxion.config:get :db :host)))
             (fluxion.config:load-file path)
             (is (string= "production" (fluxion.config:get :db :host)))
             (is (= 5432 (fluxion.config:get :db :port))))
        (when (probe-file path)
          (delete-file path))))))

(test config-load-nonexistent
  "load-file returns NIL for missing file"
  (with-clean-config
    (is (null (fluxion.config:load-file "/tmp/nonexistent-fluxion-config.lisp")))))

;;; -------------------------------------------------------
;;; Introspection
;;; -------------------------------------------------------

(test config-section-values
  "section-values returns current values"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (fluxion.config:set :db :host "custom")
    (let ((vals (fluxion.config:section-values :db)))
      (is (string= "custom" (cdr (assoc :host vals)))))))

(test config-all-values
  "all-values returns all sections"
  (with-clean-config
    (fluxion.config:define-section :db (:host "localhost"))
    (fluxion.config:define-section :app (:name "test"))
    (let ((all (fluxion.config:all-values)))
      (is (= 2 (length all))))))

;;; -------------------------------------------------------
;;; Environment
;;; -------------------------------------------------------

(test config-environment-path
  "environment-config-path generates correct path"
  (let ((path (fluxion.config:environment-config-path "/etc/myapp/"
                                                       :production)))
    (is (search "production.lisp" (namestring path)))))
