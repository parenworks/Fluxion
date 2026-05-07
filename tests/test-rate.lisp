;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Rate limiting tests

(in-package #:fluxion.db.tests)

(def-suite :rate-suite
  :description "Rate limiting tests"
  :in :db-suite)

(in-suite :rate-suite)

;;; -------------------------------------------------------
;;; Test fixtures
;;; -------------------------------------------------------

(defun make-test-env (&key (ip "127.0.0.1"))
  "Create a minimal Clack-like environment for testing."
  (list :remote-addr ip :request-method :get :path-info "/test"))

;;; -------------------------------------------------------
;;; Limit definition
;;; -------------------------------------------------------

(test rate-define-limit
  "define-limit creates a named limit"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-limit :window 60 :max-requests 5)
         (is (not (null (fluxion.rate:find-limit :test-limit)))))
    (fluxion.rate:remove-limit :test-limit)))

(test rate-remove-limit
  "remove-limit removes a named limit"
  (fluxion.rate:define-limit :temp :window 10 :max-requests 1)
  (fluxion.rate:remove-limit :temp)
  (is (null (fluxion.rate:find-limit :temp))))

;;; -------------------------------------------------------
;;; Check limit
;;; -------------------------------------------------------

(test rate-check-allows-within-limit
  "Requests within the limit are allowed"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-allow :window 60 :max-requests 3)
         (let ((env (make-test-env)))
           (multiple-value-bind (allowed remaining)
               (fluxion.rate:check-limit :test-allow env)
             (is (eq t allowed))
             (is (= 2 remaining)))))
    (fluxion.rate:remove-limit :test-allow)))

(test rate-check-denies-over-limit
  "Requests over the limit are denied"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-deny :window 60 :max-requests 2)
         (let ((env (make-test-env)))
           ;; Use up the limit
           (fluxion.rate:check-limit :test-deny env)
           (fluxion.rate:check-limit :test-deny env)
           ;; Third should be denied
           (multiple-value-bind (allowed remaining retry)
               (fluxion.rate:check-limit :test-deny env)
             (is (null allowed))
             (is (= 0 remaining))
             (is (plusp retry)))))
    (fluxion.rate:remove-limit :test-deny)))

(test rate-check-per-client
  "Different clients have separate counters"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-client :window 60 :max-requests 1)
         (let ((env1 (make-test-env :ip "10.0.0.1"))
               (env2 (make-test-env :ip "10.0.0.2")))
           ;; Client 1 uses their single request
           (is (eq t (fluxion.rate:check-limit :test-client env1)))
           ;; Client 1 is now denied
           (is (null (fluxion.rate:check-limit :test-client env1)))
           ;; Client 2 still has their request
           (is (eq t (fluxion.rate:check-limit :test-client env2)))))
    (fluxion.rate:remove-limit :test-client)))

(test rate-check-unknown-limit
  "Unknown limit allows all requests"
  (multiple-value-bind (allowed remaining)
      (fluxion.rate:check-limit :nonexistent (make-test-env))
    (is (eq t allowed))
    (is (= 999 remaining))))

;;; -------------------------------------------------------
;;; Left
;;; -------------------------------------------------------

(test rate-left-full
  "left returns max-requests when no requests made"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-left :window 60 :max-requests 5)
         (is (= 5 (fluxion.rate:left :test-left (make-test-env)))))
    (fluxion.rate:remove-limit :test-left)))

(test rate-left-decreases
  "left decreases as requests are made"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-left2 :window 60 :max-requests 3)
         (let ((env (make-test-env)))
           (fluxion.rate:check-limit :test-left2 env)
           (is (= 2 (fluxion.rate:left :test-left2 env)))
           (fluxion.rate:check-limit :test-left2 env)
           (is (= 1 (fluxion.rate:left :test-left2 env)))))
    (fluxion.rate:remove-limit :test-left2)))

;;; -------------------------------------------------------
;;; with-limitation macro
;;; -------------------------------------------------------

(test rate-with-limitation-allows
  "with-limitation executes body when within limits"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-macro :window 60 :max-requests 5)
         (let ((env (make-test-env)))
           (let ((result (fluxion.rate:with-limitation (:test-macro env)
                           '(200 () ("OK")))))
             (is (= 200 (first result))))))
    (fluxion.rate:remove-limit :test-macro)))

(test rate-with-limitation-returns-429
  "with-limitation returns 429 when limit exceeded"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-macro2 :window 60 :max-requests 1)
         (let ((env (make-test-env)))
           (fluxion.rate:with-limitation (:test-macro2 env)
             '(200 () ("OK")))
           ;; Second request should be 429
           (let ((result (fluxion.rate:with-limitation (:test-macro2 env)
                           '(200 () ("OK")))))
             (is (= 429 (first result))))))
    (fluxion.rate:remove-limit :test-macro2)))

(test rate-with-limitation-custom-handler
  "with-limitation uses on-exceeded when defined"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-custom :window 60 :max-requests 1
                                    :on-exceeded (lambda (env)
                                                   (declare (ignore env))
                                                   '(503 () ("Custom"))))
         (let ((env (make-test-env)))
           ;; Use up the limit
           (fluxion.rate:with-limitation (:test-custom env)
             '(200 () ("OK")))
           ;; Exceeded: custom handler
           (let ((result (fluxion.rate:with-limitation (:test-custom env)
                           '(200 () ("OK")))))
             (is (= 503 (first result)))
             (is (string= "Custom" (first (third result)))))))
    (fluxion.rate:remove-limit :test-custom)))

;;; -------------------------------------------------------
;;; Reset
;;; -------------------------------------------------------

(test rate-reset-limit
  "reset-limit clears all tracking data"
  (unwind-protect
       (progn
         (fluxion.rate:define-limit :test-reset :window 60 :max-requests 1)
         (let ((env (make-test-env)))
           (fluxion.rate:check-limit :test-reset env)
           (is (null (fluxion.rate:check-limit :test-reset env)))
           (fluxion.rate:reset-limit :test-reset)
           (is (eq t (fluxion.rate:check-limit :test-reset env)))))
    (fluxion.rate:remove-limit :test-reset)))
