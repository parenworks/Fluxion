;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Logging system tests

(in-package #:fluxion.db.tests)

(def-suite :log-suite
  :description "Logging system tests"
  :in :db-suite)

(in-suite :log-suite)

;;; -------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------

(defmacro with-captured-log ((&key (level :trace)) &body body)
  "Execute BODY capturing log output to a string. Returns the output."
  (let ((stream (gensym "STREAM"))
        (backend (gensym "BACKEND")))
    `(let* ((,stream (make-string-output-stream))
            (,backend (fluxion.log:make-stream-log-backend :stream ,stream))
            (fluxion.log:*backend* ,backend)
            (fluxion.log:*level* ,level))
       ,@body
       (get-output-stream-string ,stream))))

;;; -------------------------------------------------------
;;; Level checks
;;; -------------------------------------------------------

(test log-level-ordering
  "Levels have correct ordering"
  (is (< (fluxion.log:level-value :trace)
          (fluxion.log:level-value :debug)))
  (is (< (fluxion.log:level-value :debug)
          (fluxion.log:level-value :info)))
  (is (< (fluxion.log:level-value :info)
          (fluxion.log:level-value :warn)))
  (is (< (fluxion.log:level-value :warn)
          (fluxion.log:level-value :error)))
  (is (< (fluxion.log:level-value :error)
          (fluxion.log:level-value :severe)))
  (is (< (fluxion.log:level-value :severe)
          (fluxion.log:level-value :fatal))))

;;; -------------------------------------------------------
;;; Basic logging
;;; -------------------------------------------------------

(test log-info-writes
  "info level writes to backend"
  (let ((output (with-captured-log ()
                  (fluxion.log:info "Server started"))))
    (is (search "Server started" output))
    (is (search "[INFO]" output))))

(test log-format-args
  "Format arguments are applied"
  (let ((output (with-captured-log ()
                  (fluxion.log:info "Port ~D ready" 5000))))
    (is (search "Port 5000 ready" output))))

(test log-category-appears
  "Category appears in output"
  (let ((output (with-captured-log ()
                  (fluxion.log:info "Connected" :category :db))))
    (is (search "[db]" output))))

(test log-all-levels
  "Each level function writes"
  (let ((output (with-captured-log ()
                  (fluxion.log:trace "t")
                  (fluxion.log:debug "d")
                  (fluxion.log:info "i")
                  (fluxion.log:warn "w")
                  (fluxion.log:error "e")
                  (fluxion.log:severe "s")
                  (fluxion.log:fatal "f"))))
    (is (search "[TRACE]" output))
    (is (search "[DEBUG]" output))
    (is (search "[INFO]" output))
    (is (search "[WARN]" output))
    (is (search "[ERROR]" output))
    (is (search "[SEVERE]" output))
    (is (search "[FATAL]" output))))

;;; -------------------------------------------------------
;;; Level filtering
;;; -------------------------------------------------------

(test log-level-filters
  "Messages below *level* are suppressed"
  (let ((output (with-captured-log (:level :warn)
                  (fluxion.log:info "should not appear")
                  (fluxion.log:warn "should appear"))))
    (is (not (search "should not appear" output)))
    (is (search "should appear" output))))

(test log-category-level-override
  "Per-category level overrides global level"
  (let ((output (with-captured-log (:level :warn)
                  (fluxion.log:set-category-level :db :trace)
                  (fluxion.log:debug "db detail" :category :db)
                  (fluxion.log:debug "other detail" :category :http))))
    (fluxion.log:set-category-level :db nil)
    (is (search "db detail" output))
    (is (not (search "other detail" output)))))

;;; -------------------------------------------------------
;;; Structured data
;;; -------------------------------------------------------

(test log-with-data
  "Structured data appears in output"
  (let ((output (with-captured-log ()
                  (fluxion.log:log :info "Request handled"
                    :data '(:method "GET" :path "/api/users")))))
    (is (search "Request handled" output))
    (is (search "method: GET" output))
    (is (search "path: /api/users" output))))

;;; -------------------------------------------------------
;;; Null backend
;;; -------------------------------------------------------

(test log-null-backend
  "Null backend discards messages without error"
  (let ((fluxion.log:*backend* (fluxion.log:make-null-log-backend))
        (fluxion.log:*level* :trace))
    (finishes (fluxion.log:info "discarded"))))

;;; -------------------------------------------------------
;;; Multi backend
;;; -------------------------------------------------------

(test log-multi-backend
  "Multi backend writes to all backends"
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (b1 (fluxion.log:make-stream-log-backend :stream s1))
         (b2 (fluxion.log:make-stream-log-backend :stream s2))
         (fluxion.log:*backend* (fluxion.log:make-multi-log-backend b1 b2))
         (fluxion.log:*level* :trace))
    (fluxion.log:info "broadcast")
    (is (search "broadcast" (get-output-stream-string s1)))
    (is (search "broadcast" (get-output-stream-string s2)))))

;;; -------------------------------------------------------
;;; Core log function
;;; -------------------------------------------------------

(test log-core-function
  "log function works directly"
  (let ((output (with-captured-log ()
                  (fluxion.log:log :warn "Direct warning"
                    :category :test))))
    (is (search "[WARN]" output))
    (is (search "Direct warning" output))
    (is (search "[test]" output))))
