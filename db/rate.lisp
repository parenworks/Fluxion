;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Rate limiting interface (fluxion.rate)
;;;;
;;;; Granular, named, per-resource rate limiting. Complements the existing
;;;; global rate limiter middleware with fine-grained control.
;;;;
;;;; Usage:
;;;;   ;; Define a limit (at load time)
;;;;   (rate:define-limit :login
;;;;     :window 60 :max-requests 5
;;;;     :key-fn #'rate:client-ip)
;;;;
;;;;   ;; Use in a handler
;;;;   (rate:with-limitation (:login env)
;;;;     (handle-login ...))
;;;;
;;;;   ;; Check remaining
;;;;   (rate:left :login env)   ; => 3

(defpackage #:fluxion.rate
  (:use #:cl)
  (:export
   ;; Limit definition
   #:define-limit
   #:remove-limit
   #:find-limit

   ;; Usage
   #:with-limitation
   #:check-limit
   #:left

   ;; Key extractors
   #:client-ip
   #:client-session
   #:client-user

   ;; Conditions
   #:rate-limit-exceeded

   ;; Internals for testing
   #:reset-limit
   #:*limits*))

(in-package #:fluxion.rate)

;;; -------------------------------------------------------
;;; Conditions
;;; -------------------------------------------------------

(define-condition rate-limit-exceeded (error)
  ((limit-name :initarg :name :reader rate-limit-name)
   (retry-after :initarg :retry-after :reader rate-limit-retry-after))
  (:report (lambda (c s)
             (format s "Rate limit ~A exceeded. Retry after ~D seconds."
                     (rate-limit-name c) (rate-limit-retry-after c)))))

;;; -------------------------------------------------------
;;; Limit registry
;;; -------------------------------------------------------

(defstruct rate-limit
  "A named rate limit definition."
  (name     nil :type keyword)
  (window   60  :type fixnum :read-only t)
  (max-reqs 10  :type fixnum :read-only t)
  (key-fn   nil :type (or function null) :read-only t)
  (on-exceeded nil :type (or function null) :read-only t)
  ;; Tracking: hash of client-key -> (list of timestamps)
  (tracker  (make-hash-table :test 'equal) :type hash-table)
  (lock     (bordeaux-threads:make-lock "rate-limit") :type t))

(defvar *limits* (make-hash-table :test 'eq)
  "Registry of named rate limits, keyed by keyword.")

(defun define-limit (name &key (window 60) (max-requests 10)
                               (key-fn nil) (on-exceeded nil))
  "Define or redefine a named rate limit.
NAME: keyword identifier.
WINDOW: time window in seconds (default 60).
MAX-REQUESTS: maximum requests per window (default 10).
KEY-FN: function (env) returning a string key for per-client tracking.
         NIL means use client IP.
ON-EXCEEDED: optional function (env) called when limit is hit.
             If it returns a response list, that response is used."
  (setf (gethash name *limits*)
        (make-rate-limit :name name
                         :window window
                         :max-reqs max-requests
                         :key-fn (or key-fn #'client-ip)
                         :on-exceeded on-exceeded)))

(defun remove-limit (name)
  "Remove a named rate limit."
  (remhash name *limits*))

(defun find-limit (name)
  "Look up a rate limit by name. Returns the rate-limit struct or NIL."
  (gethash name *limits*))

(defun reset-limit (name)
  "Clear all tracking data for a named limit. Useful for testing."
  (let ((limit (find-limit name)))
    (when limit
      (bordeaux-threads:with-lock-held ((rate-limit-lock limit))
        (clrhash (rate-limit-tracker limit))))))

;;; -------------------------------------------------------
;;; Key extractors
;;; -------------------------------------------------------

(defun client-ip (env)
  "Extract client IP from a Clack environment."
  (or (getf env :remote-addr) "unknown"))

(defun client-session (env)
  "Extract session ID from a Clack environment (via cookie)."
  (let ((cookies (getf env :cookies)))
    (if cookies
        (or (cdr (assoc "fluxion-session" cookies :test #'string=))
            (client-ip env))
        (client-ip env))))

(defun client-user (env)
  "Extract authenticated user identifier from the current session.
Falls back to IP if no user is bound."
  (declare (ignore env))
  (if (and (boundp 'fluxion.server:*current-session*)
           (symbol-value 'fluxion.server:*current-session*))
      (let ((user (fluxion.server:session-user
                   (symbol-value 'fluxion.server:*current-session*))))
        (if user
            (format nil "user:~A" (prin1-to-string user))
            "anonymous"))
      "anonymous"))

;;; -------------------------------------------------------
;;; Core tracking
;;; -------------------------------------------------------

(defun %prune-timestamps (timestamps window now)
  "Remove timestamps older than WINDOW seconds from NOW."
  (remove-if (lambda (ts) (> (- now ts) window)) timestamps))

(defun check-limit (name env)
  "Check if the named rate limit allows this request.
Returns (values allowed-p remaining retry-after).
ALLOWED-P is T if the request is within limits.
REMAINING is the number of requests left in the current window.
RETRY-AFTER is seconds until the window resets (only meaningful when denied)."
  (let ((limit (find-limit name)))
    (unless limit
      (return-from check-limit (values t 999 0)))
    (let* ((key (funcall (rate-limit-key-fn limit) env))
           (now (get-universal-time))
           (window (rate-limit-window limit))
           (max-reqs (rate-limit-max-reqs limit)))
      (bordeaux-threads:with-lock-held ((rate-limit-lock limit))
        (let* ((tracker (rate-limit-tracker limit))
               (timestamps (%prune-timestamps
                            (gethash key tracker) window now))
               (count (length timestamps)))
          (if (< count max-reqs)
              ;; Allowed: record this request
              (progn
                (setf (gethash key tracker) (cons now timestamps))
                (values t (- max-reqs count 1) 0))
              ;; Denied: calculate retry-after
              (let* ((oldest (reduce #'min timestamps))
                     (retry (max 1 (- (+ oldest window) now))))
                (setf (gethash key tracker) timestamps)
                (values nil 0 retry))))))))

(defun left (name env)
  "Return the number of requests remaining for the named limit.
Does not consume a request."
  (let ((limit (find-limit name)))
    (unless limit (return-from left 999))
    (let* ((key (funcall (rate-limit-key-fn limit) env))
           (now (get-universal-time))
           (window (rate-limit-window limit)))
      (bordeaux-threads:with-lock-held ((rate-limit-lock limit))
        (let* ((timestamps (%prune-timestamps
                            (gethash key (rate-limit-tracker limit))
                            window now))
               (count (length timestamps)))
          (max 0 (- (rate-limit-max-reqs limit) count)))))))

;;; -------------------------------------------------------
;;; Macro for handler use
;;; -------------------------------------------------------

(defmacro with-limitation ((name env) &body body)
  "Execute BODY if the named rate limit allows the request.
If the limit is exceeded:
  - Calls the on-exceeded handler if defined (uses its return value if non-nil)
  - Otherwise returns a 429 Too Many Requests response
ENV is the Clack request environment."
  (let ((allowed (gensym "ALLOWED-"))
        (remaining (gensym "REMAINING-"))
        (retry (gensym "RETRY-"))
        (limit-var (gensym "LIMIT-"))
        (response (gensym "RESPONSE-")))
    `(multiple-value-bind (,allowed ,remaining ,retry)
         (check-limit ,name ,env)
       (declare (ignore ,remaining))
       (if ,allowed
           (progn ,@body)
           (let ((,limit-var (find-limit ,name)))
             (if (and ,limit-var (rate-limit-on-exceeded ,limit-var))
                 (let ((,response (funcall (rate-limit-on-exceeded ,limit-var)
                                           ,env)))
                   (or ,response
                       (list 429
                             (list :content-type "text/plain"
                                   :retry-after (format nil "~D" ,retry))
                             (list "Too Many Requests"))))
                 (list 429
                       (list :content-type "text/plain"
                             :retry-after (format nil "~D" ,retry))
                       (list "Too Many Requests"))))))))
