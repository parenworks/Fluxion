;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - API endpoint system tests

(in-package #:fluxion.db.tests)

(def-suite :api-suite
  :description "API endpoint system tests"
  :in :db-suite)

(in-suite :api-suite)

;;; -------------------------------------------------------
;;; JSON encoding
;;; -------------------------------------------------------

(test api-encode-plist
  "Plist encodes as JSON object"
  (let ((json (fluxion.api:encode-json (list :name "alice" :age 30))))
    (is (search "\"name\"" json))
    (is (search "\"alice\"" json))
    (is (search "30" json))))

(test api-encode-alist
  "Alist encodes as JSON object"
  (let ((json (fluxion.api:encode-json '(("name" . "bob") ("active" . t)))))
    (is (search "\"name\"" json))
    (is (search "\"bob\"" json))
    (is (search "true" json))))

(test api-encode-null
  "NIL encodes as null"
  (is (string= "null" (fluxion.api:encode-json nil))))

(test api-encode-boolean
  "T encodes as true"
  (is (string= "true" (fluxion.api:encode-json t))))

(test api-encode-string
  "String encodes as JSON string"
  (let ((json (fluxion.api:encode-json "hello")))
    (is (search "hello" json))))

(test api-encode-number
  "Number encodes as number"
  (is (string= "42" (fluxion.api:encode-json 42))))

(test api-encode-list-as-array
  "Plain list (non-plist, non-alist) encodes as array"
  (let ((json (fluxion.api:encode-json '(1 2 3))))
    (is (search "[" json))
    (is (search "1" json))
    (is (search "3" json))))

(test api-encode-nested
  "Nested structures encode correctly"
  (let ((json (fluxion.api:encode-json
               (list :users (list (list :name "alice")
                                  (list :name "bob"))))))
    (is (search "\"users\"" json))
    (is (search "\"alice\"" json))
    (is (search "\"bob\"" json))))

(test api-encode-sexp
  "S-expression format encodes readably"
  (let ((sexp (fluxion.api:encode-sexp (list :status "ok"))))
    (is (search ":status" sexp))
    (is (search "\"ok\"" sexp))))

;;; -------------------------------------------------------
;;; Query parameter parsing
;;; -------------------------------------------------------

(test api-parse-query-empty
  "Empty query string returns NIL"
  (is (null (fluxion.api:parse-query-params nil)))
  (is (null (fluxion.api:parse-query-params ""))))

(test api-parse-query-simple
  "Simple query parameters are parsed"
  (let ((params (fluxion.api:parse-query-params "page=1&limit=10")))
    (is (string= "1" (cdr (assoc "page" params :test #'string=))))
    (is (string= "10" (cdr (assoc "limit" params :test #'string=))))))

(test api-parse-query-encoded
  "URL-encoded values are decoded"
  (let ((params (fluxion.api:parse-query-params "name=hello+world&q=a%26b")))
    (is (string= "hello world" (cdr (assoc "name" params :test #'string=))))
    (is (string= "a&b" (cdr (assoc "q" params :test #'string=))))))

(test api-parse-query-no-value
  "Key without value gets empty string"
  (let ((params (fluxion.api:parse-query-params "flag")))
    (is (string= "" (cdr (assoc "flag" params :test #'string=))))))

;;; -------------------------------------------------------
;;; Response constructors
;;; -------------------------------------------------------

(test api-json-response
  "json-response creates proper Clack response"
  (let ((resp (fluxion.api:json-response (list :status "ok"))))
    (is (= 200 (first resp)))
    (is (string= "application/json; charset=utf-8"
                  (getf (second resp) :content-type)))
    (is (search "\"status\"" (first (third resp))))))

(test api-error-response
  "error-response creates error JSON"
  (let ((resp (fluxion.api:error-response "Bad input" :status 422)))
    (is (= 422 (first resp)))
    (is (search "\"Bad input\"" (first (third resp))))))

(test api-not-found-response
  "not-found-response returns 404"
  (let ((resp (fluxion.api:not-found-response)))
    (is (= 404 (first resp)))))

(test api-success-response
  "success-response returns 200 with data"
  (let ((resp (fluxion.api:success-response (list :count 5))))
    (is (= 200 (first resp)))
    (is (search "5" (first (third resp))))))

(test api-success-response-empty
  "success-response without data returns ok"
  (let ((resp (fluxion.api:success-response)))
    (is (search "\"ok\"" (first (third resp))))))

;;; -------------------------------------------------------
;;; Endpoint registration and dispatch
;;; -------------------------------------------------------

(defun make-api-env (&key (path "/api/test") (method :get)
                            query-string)
  "Create a minimal Clack-like env for testing."
  (list :path-info path
        :request-method method
        :query-string query-string
        :remote-addr "127.0.0.1"))

(test api-endpoint-simple
  "Endpoint registers and dispatches"
  (let ((router (fluxion.server:make-router)))
    (fluxion.api:endpoint router :get "/api/status"
      (lambda (params)
        (declare (ignore params))
        (list :status "ok")))
    (let ((resp (fluxion.server:dispatch-route
                 router nil nil (make-api-env :path "/api/status"))))
      (is (= 200 (first resp)))
      (is (search "\"ok\"" (first (third resp)))))))

(test api-endpoint-path-params
  "Endpoint receives path parameters"
  (let ((router (fluxion.server:make-router)))
    (fluxion.api:endpoint router :get "/api/users/:id"
      (lambda (params)
        (list :id (cdr (assoc :id params)))))
    (let ((resp (fluxion.server:dispatch-route
                 router nil nil (make-api-env :path "/api/users/42"))))
      (is (= 200 (first resp)))
      (is (search "\"42\"" (first (third resp)))))))

(test api-endpoint-query-params
  "Endpoint receives query parameters"
  (let ((router (fluxion.server:make-router)))
    (fluxion.api:endpoint router :get "/api/search"
      (lambda (params)
        (list :q (cdr (assoc "q" params :test #'string=)))))
    (let ((resp (fluxion.server:dispatch-route
                 router nil nil
                 (make-api-env :path "/api/search"
                                :query-string "q=lisp"))))
      (is (= 200 (first resp)))
      (is (search "\"lisp\"" (first (third resp)))))))

(test api-endpoint-error-handling
  "Handler errors return 500"
  (let ((router (fluxion.server:make-router)))
    (fluxion.api:endpoint router :get "/api/fail"
      (lambda (params)
        (declare (ignore params))
        (error "Something broke")))
    (let ((resp (fluxion.server:dispatch-route
                 router nil nil (make-api-env :path "/api/fail"))))
      (is (= 500 (first resp)))
      (is (search "Something broke" (first (third resp)))))))

(test api-endpoint-sexp-format
  "S-expression format works"
  (let ((router (fluxion.server:make-router))
        (fluxion.api:*default-format* :sexp))
    (fluxion.api:endpoint router :get "/api/sexp"
      (lambda (params)
        (declare (ignore params))
        (list :format "sexp")))
    (let ((resp (fluxion.server:dispatch-route
                 router nil nil (make-api-env :path "/api/sexp"))))
      (is (= 200 (first resp)))
      (is (search "application/x-sexp" (getf (second resp) :content-type))))))

;;; -------------------------------------------------------
;;; define-api macro
;;; -------------------------------------------------------

(test api-define-api-macro
  "define-api macro works"
  (let ((router (fluxion.server:make-router)))
    (fluxion.api:define-api router :get "/api/macro-test" (params)
      (declare (ignore params))
      (list :source "macro"))
    (let ((resp (fluxion.server:dispatch-route
                 router nil nil (make-api-env :path "/api/macro-test"))))
      (is (= 200 (first resp)))
      (is (search "\"macro\"" (first (third resp)))))))

;;; -------------------------------------------------------
;;; Request helpers
;;; -------------------------------------------------------

(test api-request-param
  "request-param extracts from env"
  (let ((env (make-api-env :query-string "page=3&sort=name")))
    (is (string= "3" (fluxion.api:request-param env "page")))
    (is (string= "name" (fluxion.api:request-param env "sort")))
    (is (null (fluxion.api:request-param env "missing")))))

(test api-request-content-type
  "request-content-type extracts header"
  (let ((env (list :content-type "application/json")))
    (is (string= "application/json"
                  (fluxion.api:request-content-type env)))))

(test api-request-accepts-json
  "request-accepts-json-p detects JSON accept"
  (is (fluxion.api:request-accepts-json-p
       (list :http-accept "application/json")))
  (is (fluxion.api:request-accepts-json-p
       (list :http-accept "text/html, application/json")))
  (is (not (fluxion.api:request-accepts-json-p
            (list :http-accept "text/html")))))
