;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Hooks and triggers system
;;;;
;;;; Inter-module event communication. Hooks are named extension points.
;;;; Triggers are handlers registered on hooks. When a hook fires, all
;;;; registered triggers run in priority order.
;;;;
;;;; Usage:
;;;;   (hooks:define-hook :user-created
;;;;     :description "Fires after a new user account is created."
;;;;     :args '(username fields))
;;;;
;;;;   (hooks:add-trigger :user-created :send-welcome-email
;;;;     :priority 10
;;;;     :handler (lambda (username fields)
;;;;               (mail:send (cdr (assoc "email" fields :test #'string=))
;;;;                          "Welcome" "...")))
;;;;
;;;;   (hooks:trigger :user-created "alice" '(("email" . "a@e.com")))

(defpackage #:fluxion.hooks
  (:use #:cl)
  (:export
   ;; Defining hooks
   #:define-hook
   #:undefine-hook
   #:hook-defined-p
   #:hook-info
   #:all-hooks
   ;; Triggers
   #:add-trigger
   #:remove-trigger
   #:triggers-for
   #:enable-trigger
   #:disable-trigger
   ;; Firing
   #:trigger
   #:trigger-collect
   ;; Utilities
   #:clear-all
   ;; Conditions
   #:hook-not-found
   #:trigger-error))

(in-package #:fluxion.hooks)

;;; -------------------------------------------------------
;;; Data structures
;;; -------------------------------------------------------

(defstruct hook-def
  "A named extension point."
  (name nil :type symbol)
  (description "" :type string)
  (args '() :type list))

(defstruct trigger-def
  "A handler registered on a hook."
  (name nil :type symbol)
  (hook nil :type symbol)
  (priority 0 :type integer)
  (handler nil :type (or null function))
  (enabled t :type boolean))

;;; -------------------------------------------------------
;;; Registry
;;; -------------------------------------------------------

(defvar *hooks* (make-hash-table :test 'eq)
  "Registry of defined hooks. Keys are hook name symbols.")

(defvar *triggers* (make-hash-table :test 'eq)
  "Registry of triggers per hook. Keys are hook name symbols,
values are lists of trigger-def structs.")

;;; -------------------------------------------------------
;;; Conditions
;;; -------------------------------------------------------

(define-condition hook-not-found (error)
  ((name :initarg :name :reader hook-not-found-name))
  (:report (lambda (c stream)
             (format stream "Hook not defined: ~S" (hook-not-found-name c)))))

(define-condition trigger-error (error)
  ((hook :initarg :hook :reader trigger-error-hook)
   (trigger :initarg :trigger :reader trigger-error-trigger)
   (cause :initarg :cause :reader trigger-error-cause))
  (:report (lambda (c stream)
             (format stream "Trigger ~S on hook ~S failed: ~A"
                     (trigger-error-trigger c)
                     (trigger-error-hook c)
                     (trigger-error-cause c)))))

;;; -------------------------------------------------------
;;; Hook management
;;; -------------------------------------------------------

(defun define-hook (name &key (description "") (args '()))
  "Define a named hook (extension point).
NAME is a keyword symbol identifying the hook.
DESCRIPTION documents what the hook does.
ARGS is a list of argument names for documentation."
  (setf (gethash name *hooks*)
        (make-hook-def :name name
                       :description description
                       :args args))
  ;; Ensure trigger list exists
  (unless (gethash name *triggers*)
    (setf (gethash name *triggers*) '()))
  name)

(defun undefine-hook (name)
  "Remove a hook definition and all its triggers."
  (remhash name *hooks*)
  (remhash name *triggers*))

(defun hook-defined-p (name)
  "Return T if a hook with NAME is defined."
  (not (null (gethash name *hooks*))))

(defun hook-info (name)
  "Return the hook-def struct for NAME, or NIL."
  (gethash name *hooks*))

(defun all-hooks ()
  "Return a list of all defined hook-def structs."
  (let ((result '()))
    (maphash (lambda (k v)
               (declare (ignore k))
               (push v result))
             *hooks*)
    (sort result #'string< :key (lambda (h) (symbol-name (hook-def-name h))))))

;;; -------------------------------------------------------
;;; Trigger management
;;; -------------------------------------------------------

(defun sorted-triggers (hook-name)
  "Return triggers for HOOK-NAME sorted by priority (lower first)."
  (sort (copy-list (gethash hook-name *triggers*))
        #'< :key #'trigger-def-priority))

(defun add-trigger (hook-name trigger-name &key (priority 0) handler)
  "Register a trigger on a hook.
HOOK-NAME is the hook to attach to.
TRIGGER-NAME is a unique identifier for this trigger.
PRIORITY controls execution order (lower runs first).
HANDLER is a function that receives the hook's arguments."
  (unless (hook-defined-p hook-name)
    (error 'hook-not-found :name hook-name))
  (let ((existing (gethash hook-name *triggers*)))
    ;; Replace if trigger with same name exists
    (setf existing (remove trigger-name existing :key #'trigger-def-name))
    (setf (gethash hook-name *triggers*)
          (cons (make-trigger-def :name trigger-name
                                  :hook hook-name
                                  :priority priority
                                  :handler handler
                                  :enabled t)
                existing)))
  trigger-name)

(defun remove-trigger (hook-name trigger-name)
  "Remove a trigger from a hook."
  (when (gethash hook-name *triggers*)
    (setf (gethash hook-name *triggers*)
          (remove trigger-name (gethash hook-name *triggers*)
                 :key #'trigger-def-name))))

(defun triggers-for (hook-name)
  "Return the list of trigger-def structs for a hook, sorted by priority."
  (sorted-triggers hook-name))

(defun enable-trigger (hook-name trigger-name)
  "Enable a previously disabled trigger."
  (let ((trig (find trigger-name (gethash hook-name *triggers*)
                    :key #'trigger-def-name)))
    (when trig
      (setf (trigger-def-enabled trig) t))))

(defun disable-trigger (hook-name trigger-name)
  "Disable a trigger without removing it."
  (let ((trig (find trigger-name (gethash hook-name *triggers*)
                    :key #'trigger-def-name)))
    (when trig
      (setf (trigger-def-enabled trig) nil))))

;;; -------------------------------------------------------
;;; Firing hooks
;;; -------------------------------------------------------

(defun trigger (hook-name &rest args)
  "Fire a hook, running all enabled triggers in priority order.
Returns the result of the last trigger, or NIL if none ran.
Signals TRIGGER-ERROR if a handler fails."
  (unless (hook-defined-p hook-name)
    (error 'hook-not-found :name hook-name))
  (let ((result nil))
    (dolist (trig (sorted-triggers hook-name))
      (when (trigger-def-enabled trig)
        (handler-case
            (setf result (apply (trigger-def-handler trig) args))
          (error (e)
            (error 'trigger-error
                   :hook hook-name
                   :trigger (trigger-def-name trig)
                   :cause e)))))
    result))

(defun trigger-collect (hook-name &rest args)
  "Fire a hook and collect results from all enabled triggers.
Returns a list of (trigger-name . result) pairs."
  (unless (hook-defined-p hook-name)
    (error 'hook-not-found :name hook-name))
  (let ((results '()))
    (dolist (trig (sorted-triggers hook-name))
      (when (trigger-def-enabled trig)
        (handler-case
            (push (cons (trigger-def-name trig)
                        (apply (trigger-def-handler trig) args))
                  results)
          (error (e)
            (error 'trigger-error
                   :hook hook-name
                   :trigger (trigger-def-name trig)
                   :cause e)))))
    (nreverse results)))

;;; -------------------------------------------------------
;;; Utilities
;;; -------------------------------------------------------

(defun clear-all ()
  "Remove all hooks and triggers."
  (clrhash *hooks*)
  (clrhash *triggers*))
