;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Database Layer - PostgreSQL Backend
;;;;
;;;; Production-grade database backend using Postmodern.
;;;; Supports connection pooling, prepared statements, and full SQL types.

(defpackage #:fluxion.db.postgresql
  (:use #:cl)
  (:local-nicknames (#:db #:fluxion.db)
                    (#:q #:fluxion.db.query)
                    (#:pomo #:postmodern))
  (:export
   #:postgresql-backend
   #:make-postgresql-backend))

(in-package #:fluxion.db.postgresql)

;;; -------------------------------------------------------
;;; Backend class
;;; -------------------------------------------------------

(defclass postgresql-backend (db:backend)
  ((database :initarg :database
             :initform "fluxion"
             :accessor backend-database
             :documentation "Database name.")
   (user :initarg :user
         :initform "postgres"
         :accessor backend-user
         :documentation "Database user.")
   (password :initarg :password
             :initform ""
             :accessor backend-password
             :documentation "Database password.")
   (host :initarg :host
         :initform "localhost"
         :accessor backend-host
         :documentation "Database host.")
   (port :initarg :port
         :initform 5432
         :accessor backend-port
         :documentation "Database port.")
   (use-ssl :initarg :use-ssl
            :initform :no
            :accessor backend-use-ssl
            :documentation "SSL mode (:no, :yes, :try).")
   (connection :initform nil
               :accessor backend-connection
               :documentation "Active Postmodern connection.")
   (lock :initform (bt:make-lock "pg-backend")
         :accessor backend-lock
         :documentation "Lock to serialize access to the single connection."))
  (:documentation "PostgreSQL database backend for Fluxion using Postmodern."))

(defun make-postgresql-backend (&key (database "fluxion") (user "postgres")
                                     (password "") (host "localhost")
                                     (port 5432) (use-ssl :no))
  "Create a new PostgreSQL backend."
  (make-instance 'postgresql-backend
                 :database database :user user :password password
                 :host host :port port :use-ssl use-ssl))

;;; -------------------------------------------------------
;;; Placeholder conversion
;;; -------------------------------------------------------

(defun convert-placeholders (sql)
  "Convert ? placeholders to PostgreSQL $N style.
Returns the converted SQL string."
  (let ((counter 0)
        (result (make-string-output-stream)))
    (loop for char across sql
          do (if (char= char #\?)
                 (format result "$~D" (incf counter))
                 (write-char char result)))
    (get-output-stream-string result)))

;;; -------------------------------------------------------
;;; Connection
;;; -------------------------------------------------------

(defmethod db:connect ((backend postgresql-backend) &key database user password host port use-ssl)
  (when database (setf (backend-database backend) database))
  (when user (setf (backend-user backend) user))
  (when password (setf (backend-password backend) password))
  (when host (setf (backend-host backend) host))
  (when port (setf (backend-port backend) port))
  (when use-ssl (setf (backend-use-ssl backend) use-ssl))
  (when (backend-connection backend)
    (warn 'db:connection-already-open)
    (return-from db:connect backend))
  (handler-case
      (let ((conn (pomo:connect (backend-database backend)
                                (backend-user backend)
                                (backend-password backend)
                                (backend-host backend)
                                :port (backend-port backend)
                                :use-ssl (backend-use-ssl backend))))
        (setf (backend-connection backend) conn)
        (setf pomo:*database* conn)
        (setf db:*backend* backend)
        backend)
    (error (e)
      (error 'db:connection-failed
             :message (format nil "PostgreSQL connection to ~A@~A:~D/~A failed: ~A"
                              (backend-user backend)
                              (backend-host backend)
                              (backend-port backend)
                              (backend-database backend) e)))))

(defmethod db:disconnect ((backend postgresql-backend))
  (when (backend-connection backend)
    (pomo:disconnect (backend-connection backend))
    (setf (backend-connection backend) nil))
  (when (eq db:*backend* backend)
    (setf db:*backend* nil)))

(defmethod db:connected-p ((backend postgresql-backend))
  (and (backend-connection backend)
       (pomo:connected-p (backend-connection backend))))

(defun %ensure-conn (backend)
  "Return the active connection or signal an error."
  (or (backend-connection backend)
      (error 'db:connection-failed :message "PostgreSQL backend not connected")))

(defmacro with-pg-conn (backend &body body)
  "Execute BODY with *database* bound to BACKEND's connection.
Serializes access via the backend lock to prevent concurrent query errors."
  (let ((b (gensym "BACKEND")))
    `(let ((,b ,backend))
       (bt:with-lock-held ((backend-lock ,b))
         (let ((pomo:*database* (%ensure-conn ,b)))
           ,@body)))))

;;; -------------------------------------------------------
;;; SQL execution helpers
;;; -------------------------------------------------------

(defun %coerce-param (value)
  "Coerce a Lisp value to a string for cl-postgres parameterized queries.
cl-postgres parameters must be strings, :null, or NIL."
  (cond
    ((null value) :null)
    ((eq value t) "true")
    ((stringp value) value)
    ((integerp value) (format nil "~D" value))
    ((floatp value) (format nil "~F" value))
    (t (format nil "~A" value))))

(defun %execute (backend sql &optional params)
  "Execute a SQL statement with parameters via prepared statements."
  (with-pg-conn backend
    (let ((pg-sql (convert-placeholders sql))
          (str-params (mapcar #'%coerce-param params)))
      (cl-postgres:prepare-query pomo:*database* "" pg-sql str-params)
      (cl-postgres:exec-prepared pomo:*database* "" str-params
                                 'cl-postgres:ignore-row-reader))))

(defun %keyword-alist-to-string-alist (alist)
  "Convert a postmodern keyword-keyed alist to string-keyed alist.
Converts :NAME to \"name\" and :-ID to \"_id\"."
  (mapcar (lambda (pair)
            (let* ((key-str (symbol-name (car pair)))
                   (str (cond
                          ;; :-ID becomes _id
                          ((string= key-str "-ID") "_id")
                          ;; Leading dash becomes underscore
                          ((and (> (length key-str) 0)
                                (char= (char key-str 0) #\-))
                           (concatenate 'string "_" (string-downcase (subseq key-str 1))))
                          (t (string-downcase key-str)))))
              (cons str (cdr pair))))
          alist))

(defun %query-rows (backend sql &optional params)
  "Execute a query and return results as a list of string-keyed alists."
  (with-pg-conn backend
    (let* ((pg-sql (convert-placeholders sql))
           (str-params (mapcar #'%coerce-param params)))
      (cl-postgres:prepare-query pomo:*database* "" pg-sql str-params)
      (let ((raw (cl-postgres:exec-prepared
                  pomo:*database* "" str-params
                  'postmodern::symbol-alist-row-reader)))
        (mapcar #'%keyword-alist-to-string-alist raw)))))

(defun pg-escape-value (value)
  "Escape a value for inline SQL (used in INSERT/UPDATE value embedding).
Uses Postmodern's sql-escape for strings."
  (cond
    ((null value) "NULL")
    ((eq value t) "TRUE")
    ((stringp value) (pomo:sql-escape-string value))
    ((integerp value) (format nil "~D" value))
    ((floatp value) (format nil "~F" value))
    (t (pomo:sql-escape-string (format nil "~A" value)))))

;;; -------------------------------------------------------
;;; PostgreSQL type mapping
;;; -------------------------------------------------------

(defun field-type-pg (type)
  "Convert a portable field type keyword to PostgreSQL type string."
  (ecase type
    (:text "TEXT")
    (:integer "INTEGER")
    (:bigint "BIGINT")
    (:float "DOUBLE PRECISION")
    (:boolean "BOOLEAN")
    (:timestamp "TIMESTAMP")))

(defun pg-type-to-keyword (pg-type)
  "Convert a PostgreSQL type name back to a Fluxion field-type keyword."
  (let ((up (string-upcase pg-type)))
    (cond
      ((string= up "TEXT") :text)
      ((string= up "BIGINT") :bigint)
      ((or (string= up "INTEGER") (search "INT" up)) :integer)
      ((or (string= up "DOUBLE PRECISION") (search "FLOAT" up)
           (string= up "REAL") (search "NUMERIC" up)) :float)
      ((string= up "BOOLEAN") :boolean)
      ((search "TIMESTAMP" up) :timestamp)
      (t :text))))

(defun pg-create-table-sql (name structure)
  "Generate a CREATE TABLE SQL string for PostgreSQL.
Uses SERIAL for auto-incrementing primary key."
  (let* ((cols (mapcar (lambda (spec)
                         (format nil "~A ~A"
                                 (q:quote-identifier (first spec))
                                 (field-type-pg (second spec))))
                       structure))
         (all-cols (cons "\"_id\" SERIAL PRIMARY KEY" cols)))
    (format nil "CREATE TABLE ~A (~{~A~^, ~})"
            (q:quote-identifier name) all-cols)))

;;; -------------------------------------------------------
;;; Collection management
;;; -------------------------------------------------------

(defmethod db:%collections ((backend postgresql-backend))
  (with-pg-conn backend
    (mapcar #'car
            (pomo:query "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
                        :rows))))

(defmethod db:%collection-exists-p ((backend postgresql-backend) name)
  (with-pg-conn backend
    (pomo:table-exists-p name)))

(defmethod db:%create ((backend postgresql-backend) name structure &key (if-exists :error))
  (when (db:%collection-exists-p backend name)
    (ecase if-exists
      (:error (error 'db:collection-already-exists :name name
                     :message "Collection already exists"))
      (:ignore (return-from db:%create nil))))
  (with-pg-conn backend
    (pomo:execute (pg-create-table-sql name structure))))

(defmethod db:%drop ((backend postgresql-backend) name)
  (unless (db:%collection-exists-p backend name)
    (error 'db:invalid-collection :name name
           :message "Collection does not exist"))
  (with-pg-conn backend
    (pomo:execute (format nil "DROP TABLE ~A" (q:quote-identifier name)))))

(defmethod db:%empty ((backend postgresql-backend) name)
  (with-pg-conn backend
    (pomo:execute (format nil "DELETE FROM ~A" (q:quote-identifier name)))))

(defmethod db:%alter ((backend postgresql-backend) name structure)
  (let* ((current (db:%collection-structure backend name))
         (current-names (mapcar (lambda (s) (string-downcase (first s))) current))
         (new-cols (remove-if (lambda (spec)
                                (member (string-downcase
                                         (q:field-name-sql (first spec)))
                                        current-names :test #'string=))
                              structure)))
    (when new-cols
      (with-pg-conn backend
        (dolist (spec new-cols)
          (pomo:execute
           (format nil "ALTER TABLE ~A ADD COLUMN ~A ~A"
                   (q:quote-identifier name)
                   (q:quote-identifier (first spec))
                   (field-type-pg (second spec)))))))))

(defmethod db:%collection-structure ((backend postgresql-backend) name)
  (with-pg-conn backend
    (let ((rows (pomo:query
                 (format nil "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = ~A AND table_schema = 'public' ORDER BY ordinal_position"
                         (pomo:sql-escape-string name))
                 :rows)))
      (mapcar (lambda (row)
                (list (first row)
                      (pg-type-to-keyword (second row))))
              (remove-if (lambda (row)
                           (string= "_id" (first row)))
                         rows)))))

;;; -------------------------------------------------------
;;; Data operations
;;; -------------------------------------------------------

(defmethod db:%insert ((backend postgresql-backend) collection data)
  (let* ((columns (mapcar #'car data))
         (values (mapcar #'cdr data))
         (col-str (format nil "~{~A~^, ~}" (mapcar #'q:quote-identifier columns)))
         (placeholders (loop for i from 1 to (length values)
                             collect (format nil "$~D" i)))
         (val-str (format nil "~{~A~^, ~}" placeholders))
         (sql (format nil "INSERT INTO ~A (~A) VALUES (~A) RETURNING \"_id\""
                      (q:quote-identifier collection) col-str val-str))
         (str-params (mapcar #'%coerce-param values)))
    (with-pg-conn backend
      (cl-postgres:prepare-query pomo:*database* "" sql str-params)
      (let ((raw (cl-postgres:exec-prepared
                  pomo:*database* "" str-params
                  'postmodern::symbol-alist-row-reader)))
        (when raw
          (cdr (first (first raw))))))))

(defmethod db:%select ((backend postgresql-backend) collection query
                        &key fields skip amount sort unique)
  (let ((compiled (q:compile-select collection query
                                    :fields fields :skip skip
                                    :amount amount :sort sort
                                    :unique unique)))
    (%query-rows backend (car compiled) (cdr compiled))))

(defmethod db:%count ((backend postgresql-backend) collection query)
  (let* ((where-sql (car query))
         (where-params (cdr query))
         (sql (format nil "SELECT COUNT(*) AS \"count\" FROM ~A WHERE ~A"
                      (q:quote-identifier collection) where-sql))
         (rows (%query-rows backend sql where-params)))
    (if rows
        (cdr (first (first rows)))
        0)))

(defmethod db:%update ((backend postgresql-backend) collection query data
                        &key skip amount sort)
  (declare (ignore skip amount sort))
  (let* ((set-values (mapcar #'cdr data))
         (where-params (cdr query))
         (all-params (append set-values where-params))
         ;; SET clause: "col" = $1, "col2" = $2, ...
         (set-parts (loop for pair in data
                          for i from 1
                          collect (format nil "~A = $~D"
                                          (q:quote-identifier (car pair)) i)))
         ;; WHERE clause: replace ? with $N continuing from SET count
         (where-sql (car query))
         (param-offset (length set-values))
         (pg-where (let ((counter param-offset)
                         (result (make-string-output-stream)))
                     (loop for ch across where-sql
                           do (if (char= ch #\?)
                                  (format result "$~D" (incf counter))
                                  (write-char ch result)))
                     (get-output-stream-string result)))
         (sql (format nil "UPDATE ~A SET ~{~A~^, ~} WHERE ~A"
                      (q:quote-identifier collection) set-parts pg-where)))
    (%execute backend sql all-params)))

(defmethod db:%remove ((backend postgresql-backend) collection query
                        &key skip amount sort)
  (declare (ignore skip amount sort))
  (let ((compiled (q:compile-delete collection query)))
    (%execute backend (car compiled) (cdr compiled))))

(defmethod db:%iterate ((backend postgresql-backend) collection query function
                         &key fields skip amount sort unique)
  (let ((rows (db:%select backend collection query
                          :fields fields :skip skip :amount amount
                          :sort sort :unique unique)))
    (dolist (row rows)
      (funcall function row))))

(defmethod db:%execute-transaction ((backend postgresql-backend) thunk)
  (with-pg-conn backend
    (pomo:with-transaction ()
      (funcall thunk))))

;;; -------------------------------------------------------
;;; Relational extension (fluxion.rdb) support
;;; -------------------------------------------------------

(defmethod fluxion.rdb:%join ((backend postgresql-backend) type left right
                              &key on query fields sort skip amount)
  (let ((compiled (fluxion.rdb::compile-join-sql
                   type left right
                   :on on :query query :fields fields
                   :sort sort :skip skip :amount amount)))
    (%query-rows backend (car compiled) (cdr compiled))))

(defmethod fluxion.rdb:%sql-query ((backend postgresql-backend) sql params)
  (%query-rows backend sql params))

(defmethod fluxion.rdb:%sql-execute ((backend postgresql-backend) sql params)
  (%execute backend sql params))
