;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Hooks and triggers tests

(in-package #:fluxion.db.tests)

(def-suite :hooks-suite
  :description "Hooks and triggers system tests"
  :in :db-suite)

(in-suite :hooks-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defmacro with-clean-hooks (&body body)
  `(progn
     (fluxion.hooks:clear-all)
     (unwind-protect (progn ,@body)
       (fluxion.hooks:clear-all))))

;;; -------------------------------------------------------
;;; Hook definition
;;; -------------------------------------------------------

(test hooks-define-hook
  "define-hook creates a hook"
  (with-clean-hooks
    (fluxion.hooks:define-hook :test-event
      :description "A test hook"
      :args '(name value))
    (is (fluxion.hooks:hook-defined-p :test-event))
    (let ((info (fluxion.hooks:hook-info :test-event)))
      (is (string= "A test hook"
                    (fluxion.hooks::hook-def-description info))))))

(test hooks-undefine-hook
  "undefine-hook removes hook and its triggers"
  (with-clean-hooks
    (fluxion.hooks:define-hook :ephemeral)
    (fluxion.hooks:add-trigger :ephemeral :my-trigger
      :handler (lambda () nil))
    (fluxion.hooks:undefine-hook :ephemeral)
    (is (not (fluxion.hooks:hook-defined-p :ephemeral)))
    (is (null (fluxion.hooks:triggers-for :ephemeral)))))

(test hooks-all-hooks
  "all-hooks returns all defined hooks"
  (with-clean-hooks
    (fluxion.hooks:define-hook :alpha)
    (fluxion.hooks:define-hook :beta)
    (let ((hooks (fluxion.hooks:all-hooks)))
      (is (= 2 (length hooks))))))

;;; -------------------------------------------------------
;;; Trigger registration
;;; -------------------------------------------------------

(test hooks-add-trigger
  "add-trigger registers a handler"
  (with-clean-hooks
    (fluxion.hooks:define-hook :event)
    (fluxion.hooks:add-trigger :event :handler-a
      :handler (lambda () "a"))
    (is (= 1 (length (fluxion.hooks:triggers-for :event))))))

(test hooks-add-trigger-replaces
  "Adding a trigger with same name replaces it"
  (with-clean-hooks
    (fluxion.hooks:define-hook :event)
    (fluxion.hooks:add-trigger :event :handler-a
      :handler (lambda () "old"))
    (fluxion.hooks:add-trigger :event :handler-a
      :handler (lambda () "new"))
    (is (= 1 (length (fluxion.hooks:triggers-for :event))))))

(test hooks-add-trigger-undefined-hook
  "add-trigger signals hook-not-found for undefined hooks"
  (with-clean-hooks
    (signals fluxion.hooks:hook-not-found
      (fluxion.hooks:add-trigger :nonexistent :my-handler
        :handler (lambda () nil)))))

(test hooks-remove-trigger
  "remove-trigger removes a specific handler"
  (with-clean-hooks
    (fluxion.hooks:define-hook :event)
    (fluxion.hooks:add-trigger :event :a :handler (lambda () nil))
    (fluxion.hooks:add-trigger :event :b :handler (lambda () nil))
    (fluxion.hooks:remove-trigger :event :a)
    (is (= 1 (length (fluxion.hooks:triggers-for :event))))))

;;; -------------------------------------------------------
;;; Priority ordering
;;; -------------------------------------------------------

(test hooks-priority-order
  "Triggers fire in priority order (lower first)"
  (with-clean-hooks
    (let ((log '()))
      (fluxion.hooks:define-hook :ordered)
      (fluxion.hooks:add-trigger :ordered :last
        :priority 30 :handler (lambda () (push :last log)))
      (fluxion.hooks:add-trigger :ordered :first
        :priority 10 :handler (lambda () (push :first log)))
      (fluxion.hooks:add-trigger :ordered :middle
        :priority 20 :handler (lambda () (push :middle log)))
      (fluxion.hooks:trigger :ordered)
      (is (equal '(:last :middle :first) log)))))

;;; -------------------------------------------------------
;;; Firing
;;; -------------------------------------------------------

(test hooks-trigger-fires
  "trigger runs all enabled handlers"
  (with-clean-hooks
    (let ((sum 0))
      (fluxion.hooks:define-hook :add)
      (fluxion.hooks:add-trigger :add :plus-one
        :handler (lambda (n) (incf sum n)))
      (fluxion.hooks:add-trigger :add :plus-two
        :handler (lambda (n) (incf sum (* 2 n))))
      (fluxion.hooks:trigger :add 5)
      (is (= 15 sum)))))

(test hooks-trigger-returns-last
  "trigger returns result of last handler"
  (with-clean-hooks
    (fluxion.hooks:define-hook :compute)
    (fluxion.hooks:add-trigger :compute :a
      :priority 1 :handler (lambda () "first"))
    (fluxion.hooks:add-trigger :compute :b
      :priority 2 :handler (lambda () "second"))
    (is (string= "second" (fluxion.hooks:trigger :compute)))))

(test hooks-trigger-collect
  "trigger-collect returns all results"
  (with-clean-hooks
    (fluxion.hooks:define-hook :gather)
    (fluxion.hooks:add-trigger :gather :a
      :priority 1 :handler (lambda () "result-a"))
    (fluxion.hooks:add-trigger :gather :b
      :priority 2 :handler (lambda () "result-b"))
    (let ((results (fluxion.hooks:trigger-collect :gather)))
      (is (= 2 (length results)))
      (is (string= "result-a" (cdr (first results))))
      (is (string= "result-b" (cdr (second results)))))))

(test hooks-trigger-undefined-hook
  "trigger signals hook-not-found for undefined hooks"
  (with-clean-hooks
    (signals fluxion.hooks:hook-not-found
      (fluxion.hooks:trigger :nonexistent))))

(test hooks-trigger-no-handlers
  "trigger returns NIL when no handlers registered"
  (with-clean-hooks
    (fluxion.hooks:define-hook :empty)
    (is (null (fluxion.hooks:trigger :empty)))))

(test hooks-trigger-passes-args
  "trigger passes arguments to handlers"
  (with-clean-hooks
    (let ((received nil))
      (fluxion.hooks:define-hook :with-args)
      (fluxion.hooks:add-trigger :with-args :capture
        :handler (lambda (a b c)
                   (setf received (list a b c))))
      (fluxion.hooks:trigger :with-args 1 "two" :three)
      (is (equal '(1 "two" :three) received)))))

;;; -------------------------------------------------------
;;; Enable/disable
;;; -------------------------------------------------------

(test hooks-disable-trigger
  "Disabled triggers are skipped"
  (with-clean-hooks
    (let ((fired '()))
      (fluxion.hooks:define-hook :toggle)
      (fluxion.hooks:add-trigger :toggle :a
        :handler (lambda () (push :a fired)))
      (fluxion.hooks:add-trigger :toggle :b
        :handler (lambda () (push :b fired)))
      (fluxion.hooks:disable-trigger :toggle :b)
      (fluxion.hooks:trigger :toggle)
      (is (equal '(:a) fired)))))

(test hooks-enable-trigger
  "Re-enabled triggers fire again"
  (with-clean-hooks
    (let ((fired '()))
      (fluxion.hooks:define-hook :toggle)
      (fluxion.hooks:add-trigger :toggle :a
        :handler (lambda () (push :a fired)))
      (fluxion.hooks:disable-trigger :toggle :a)
      (fluxion.hooks:trigger :toggle)
      (is (null fired))
      (fluxion.hooks:enable-trigger :toggle :a)
      (fluxion.hooks:trigger :toggle)
      (is (equal '(:a) fired)))))

;;; -------------------------------------------------------
;;; Error handling
;;; -------------------------------------------------------

(test hooks-trigger-error-wraps
  "Handler errors are wrapped in trigger-error"
  (with-clean-hooks
    (fluxion.hooks:define-hook :failing)
    (fluxion.hooks:add-trigger :failing :bad
      :handler (lambda () (error "boom")))
    (signals fluxion.hooks:trigger-error
      (fluxion.hooks:trigger :failing))))
