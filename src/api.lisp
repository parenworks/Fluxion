;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - API endpoint system
;;;;
;;;; REST API definition alongside component pages. Provides define-api
;;;; for declaring JSON endpoints that integrate with Fluxion's router,
;;;; authentication, and rate limiting.
;;;;
;;;; Usage:
;;;;   (api:define-api *router* :get "/api/users" (app session env)
;;;;     :auth t
;;;;     :rate-limit :api-default
;;;;     :handler (lambda (params)
;;;;               (list :users (fetch-users))))
;;;;
;;;;   ;; Simpler form:
;;;;   (api:endpoint *router* :get "/api/status"
;;;;     (lambda (params)
;;;;       (list :status "ok" :uptime (get-uptime))))

(defpackage #:fluxion.api
  (:use #:cl)
  (:export
   ;; Core
   #:endpoint
   #:define-api
   ;; Responses
   #:json-response
   #:sexp-response
   #:error-response
   #:not-found-response
   #:success-response
   ;; Request helpers
   #:parse-query-params
   #:request-param
   #:request-json-body
   #:request-content-type
   #:request-accepts-json-p
   ;; Serialization
   #:*default-format*
   #:encode-json
   #:encode-sexp
   ;; Middleware helpers
   #:*require-auth*
   #:*auth-failure-response*))

(in-package #:fluxion.api)

;;; -------------------------------------------------------
;;; Configuration
;;; -------------------------------------------------------

(defvar *default-format* :json
  "Default response format. :json or :sexp.")

(defvar *require-auth* nil
  "When T, API endpoints require authentication by default.")

(defvar *auth-failure-response*
  '(401 (:content-type "application/json") ("{\"error\":\"Unauthorized\"}"))
  "Default response when authentication fails.")

;;; -------------------------------------------------------
;;; Serialization
;;; -------------------------------------------------------

(defun encode-json (data)
  "Encode DATA as a JSON string. DATA can be a plist, alist, hash table, or atom."
  (with-output-to-string (s)
    (encode-json-value data s)))

(defun encode-json-value (data stream)
  "Write DATA as JSON to STREAM."
  (cond
    ((null data)
     (write-string "null" stream))
    ((eq data t)
     (write-string "true" stream))
    ((stringp data)
     (cl-json:encode-json data stream))
    ((numberp data)
     (princ data stream))
    ((keywordp data)
     (cl-json:encode-json (string-downcase (symbol-name data)) stream))
    ((hash-table-p data)
     (cl-json:encode-json data stream))
    ;; Plist check: starts with keyword
    ((and (listp data) (keywordp (car data)))
     (encode-plist-as-json data stream))
    ;; Alist check: list of conses
    ((and (listp data) (consp (car data)))
     (encode-alist-as-json data stream))
    ;; Plain list -> JSON array
    ((listp data)
     (write-char #\[ stream)
     (loop for (item . rest) on data
           do (encode-json-value item stream)
           when rest do (write-char #\, stream))
     (write-char #\] stream))
    (t
     (cl-json:encode-json data stream))))

(defun encode-plist-as-json (plist stream)
  "Encode a plist as a JSON object."
  (write-char #\{ stream)
  (loop for (key value . rest) on plist by #'cddr
        for first = t then nil
        unless first do (write-char #\, stream)
        do (cl-json:encode-json (string-downcase (symbol-name key)) stream)
           (write-char #\: stream)
           (encode-json-value value stream))
  (write-char #\} stream))

(defun encode-alist-as-json (alist stream)
  "Encode an alist as a JSON object."
  (write-char #\{ stream)
  (loop for (pair . rest) on alist
        for first = t then nil
        unless first do (write-char #\, stream)
        do (let ((key (car pair))
                 (val (cdr pair)))
             (cl-json:encode-json
              (etypecase key
                (keyword (string-downcase (symbol-name key)))
                (symbol (string-downcase (symbol-name key)))
                (string key))
              stream)
             (write-char #\: stream)
             (encode-json-value val stream)))
  (write-char #\} stream))

(defun encode-sexp (data)
  "Encode DATA as a readable s-expression string."
  (with-output-to-string (s)
    (let ((*print-case* :downcase)
          (*print-pretty* t))
      (prin1 data s))))

;;; -------------------------------------------------------
;;; Request helpers
;;; -------------------------------------------------------

(defun parse-query-params (query-string)
  "Parse a URL query string into an alist of (name . value) pairs."
  (when (and query-string (plusp (length query-string)))
    (loop for pair in (uiop:split-string query-string :separator "&")
          for eq-pos = (position #\= pair)
          collect (if eq-pos
                      (cons (subseq pair 0 eq-pos)
                            (url-decode (subseq pair (1+ eq-pos))))
                      (cons pair "")))))

(defun url-decode (string)
  "Decode a URL-encoded string."
  (with-output-to-string (out)
    (let ((i 0) (len (length string)))
      (loop while (< i len) do
        (let ((c (char string i)))
          (cond
            ((char= c #\+)
             (write-char #\Space out)
             (incf i))
            ((and (char= c #\%) (< (+ i 2) len))
             (let ((hex (subseq string (1+ i) (+ i 3))))
               (write-char (code-char (parse-integer hex :radix 16)) out)
               (incf i 3)))
            (t
             (write-char c out)
             (incf i))))))))

(defun request-param (env name)
  "Get a query parameter by NAME from the Clack ENV."
  (let ((params (parse-query-params (getf env :query-string))))
    (cdr (assoc name params :test #'string=))))

(defun request-json-body (env)
  "Parse the request body as JSON. Returns a decoded Lisp structure or NIL."
  (let ((body-stream (getf env :raw-body)))
    (when body-stream
      (handler-case
          (let ((buf (make-array 4096 :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0)))
            (loop for byte = (read-byte body-stream nil nil)
                  while byte do (vector-push-extend byte buf))
            (let ((str (babel:octets-to-string buf :encoding :utf-8)))
              (when (plusp (length str))
                (cl-json:decode-json-from-string str))))
        (error () nil)))))

(defun request-content-type (env)
  "Return the Content-Type of the request."
  (getf env :content-type))

(defun request-accepts-json-p (env)
  "Return T if the request Accept header includes application/json."
  (let ((accept (getf env :http-accept "")))
    (or (search "application/json" accept)
        (search "*/*" accept))))

;;; -------------------------------------------------------
;;; Response constructors
;;; -------------------------------------------------------

(defun json-response (data &key (status 200) (headers nil))
  "Create a JSON response from DATA."
  (list status
        (append '(:content-type "application/json; charset=utf-8") headers)
        (list (encode-json data))))

(defun sexp-response (data &key (status 200) (headers nil))
  "Create an s-expression response from DATA."
  (list status
        (append '(:content-type "application/x-sexp; charset=utf-8") headers)
        (list (encode-sexp data))))

(defun error-response (message &key (status 400) (code nil))
  "Create a JSON error response."
  (json-response
   (if code
       (list :error message :code code)
       (list :error message))
   :status status))

(defun not-found-response (&optional (message "Not found"))
  "Create a 404 JSON response."
  (error-response message :status 404))

(defun success-response (&optional data)
  "Create a success JSON response."
  (if data
      (json-response data)
      (json-response (list :status "ok"))))

;;; -------------------------------------------------------
;;; Endpoint registration
;;; -------------------------------------------------------

(defun endpoint (router method pattern handler &key guard name
                                                     (auth nil auth-p)
                                                     rate-limit)
  "Register an API endpoint on ROUTER.
METHOD is :get, :post, :put, :delete, or :any.
PATTERN is a URL path like \"/api/users/:id\".
HANDLER is a function (params) -> data, where params is an alist merging
  path parameters, query parameters, and JSON body fields.
  The return value is automatically serialized.
GUARD is an optional guard function (session) -> response-or-nil.
AUTH if T requires the session to be authenticated.
RATE-LIMIT is an optional rate limit name (for fluxion.rate integration)."
  (let ((require-auth (if auth-p auth *require-auth*)))
    (fluxion.server:add-route
     router method pattern
     (lambda (app session env &key params)
       (declare (ignore app))
       (block endpoint-handler
         ;; Auth check
         (when require-auth
           (let ((auth-pkg (find-package "FLUXION.AUTH")))
             (when auth-pkg
               (let ((current-fn (find-symbol "CURRENT" auth-pkg)))
                 (when (and current-fn (fboundp current-fn))
                   (unless (funcall current-fn session)
                     (return-from endpoint-handler
                       *auth-failure-response*)))))))
         ;; Rate limit check
         (when rate-limit
           (let ((rate-pkg (find-package "FLUXION.RATE")))
             (when rate-pkg
               (let ((check-fn (find-symbol "CHECK-LIMIT" rate-pkg)))
                 (when (and check-fn (fboundp check-fn))
                   (let ((result (funcall check-fn rate-limit
                                          (getf env :remote-addr "unknown"))))
                     (when (eq result :exceeded)
                       (return-from endpoint-handler
                         (error-response "Rate limit exceeded"
                                         :status 429)))))))))
         ;; Merge params: path + query + body
         (let* ((query-params (parse-query-params (getf env :query-string)))
                (body-params (when (member method '(:post :put :patch :any))
                               (let ((body (request-json-body env)))
                                 (when (and (listp body) (consp (car body)))
                                   body))))
                (all-params (append params query-params body-params)))
           ;; Call handler
           (handler-case
               (let ((result (funcall handler all-params)))
                 (ecase *default-format*
                   (:json (json-response result))
                   (:sexp (sexp-response result))))
             (error (e)
               (error-response (format nil "~A" e) :status 500))))))
     :guard guard
     :name name)))

(defmacro define-api (router method pattern lambda-list &body body)
  "Define an API endpoint with a body.
LAMBDA-LIST is (params) or (params &key auth rate-limit).

Example:
  (define-api *router* :get \"/api/users\" (params)
    (list :users (fetch-all-users)))

  (define-api *router* :post \"/api/users\" (params &key auth)
    :auth t
    (let ((name (cdr (assoc :name params))))
      (create-user name)
      (list :created t :name name)))"
  (let ((options '())
        (real-body body))
    ;; Extract leading keyword options
    (loop while (and (cdr real-body) (keywordp (car real-body)))
          do (push (cadr real-body) options)
             (push (car real-body) options)
             (setf real-body (cddr real-body)))
    (let ((params-var (if (listp lambda-list) (car lambda-list) lambda-list)))
      `(endpoint ,router ,method ,pattern
                 (lambda (,params-var) ,@real-body)
                 ,@options))))
