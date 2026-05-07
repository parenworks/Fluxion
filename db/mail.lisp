;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Mail interface
;;;;
;;;; Minimal email sending with pluggable backends.
;;;; Backends: SMTP (via cl-smtp), sendmail, and null/log for development.
;;;;
;;;; Usage:
;;;;   (mail:send "user@example.com" "Welcome" "Hello!")
;;;;   (mail:send "user@example.com" "Report" "<h1>Report</h1>" :html-p t)

(defpackage #:fluxion.mail
  (:use #:cl)
  (:export
   ;; Backend protocol
   #:mail-backend
   #:backend-send
   ;; Backends
   #:null-mail-backend
   #:make-null-mail-backend
   #:log-mail-backend
   #:make-log-mail-backend
   #:smtp-mail-backend
   #:make-smtp-mail-backend
   #:sendmail-mail-backend
   #:make-sendmail-mail-backend
   ;; High-level API
   #:*backend*
   #:*from*
   #:*on-send*
   #:send
   ;; Accessors
   #:backend-log))

(in-package #:fluxion.mail)

;;; -------------------------------------------------------
;;; Backend protocol
;;; -------------------------------------------------------

(defclass mail-backend () ()
  (:documentation "Abstract base class for mail backends."))

(defgeneric backend-send (backend to subject body &key from html-p headers)
  (:documentation "Send an email via BACKEND.
TO is a string (single recipient) or list of strings.
SUBJECT is the email subject.
BODY is the email body text.
FROM is the sender address (defaults to *from*).
HTML-P if true, the body is HTML.
HEADERS is an alist of additional headers."))

;;; -------------------------------------------------------
;;; Null backend (discard)
;;; -------------------------------------------------------

(defclass null-mail-backend (mail-backend) ()
  (:documentation "Mail backend that silently discards all messages."))

(defun make-null-mail-backend ()
  "Create a null mail backend that discards all messages."
  (make-instance 'null-mail-backend))

(defmethod backend-send ((backend null-mail-backend) to subject body
                         &key from html-p headers)
  (declare (ignore to subject body from html-p headers))
  t)

;;; -------------------------------------------------------
;;; Log backend (development)
;;; -------------------------------------------------------

(defclass log-mail-backend (mail-backend)
  ((stream :initarg :stream
           :initform *standard-output*
           :reader backend-log-stream)
   (messages :initform '()
             :accessor backend-log))
  (:documentation "Mail backend that logs messages to a stream. Useful for development and testing."))

(defun make-log-mail-backend (&key (stream *standard-output*))
  "Create a logging mail backend."
  (make-instance 'log-mail-backend :stream stream))

(defmethod backend-send ((backend log-mail-backend) to subject body
                         &key from html-p headers)
  (let ((msg `((:to . ,to) (:from . ,from) (:subject . ,subject)
               (:body . ,body) (:html-p . ,html-p)
               ,@(when headers `((:headers . ,headers))))))
    (push msg (backend-log backend))
    (let ((stream (backend-log-stream backend)))
      (format stream "~&[MAIL] To: ~A~%" to)
      (format stream "        From: ~A~%" (or from *from*))
      (format stream "        Subject: ~A~%" subject)
      (format stream "        HTML: ~A~%" html-p)
      (format stream "        Body: ~A~%~%" (subseq body 0 (min 200 (length body))))))
  t)

;;; -------------------------------------------------------
;;; SMTP backend
;;; -------------------------------------------------------

(defclass smtp-mail-backend (mail-backend)
  ((host :initarg :host
         :initform "localhost"
         :reader backend-host)
   (port :initarg :port
         :initform 25
         :reader backend-port)
   (ssl :initarg :ssl
        :initform nil
        :reader backend-ssl)
   (username :initarg :username
             :initform nil
             :reader backend-username)
   (password :initarg :password
             :initform nil
             :reader backend-password))
  (:documentation "SMTP mail backend. Requires cl-smtp to be loaded."))

(defun make-smtp-mail-backend (&key (host "localhost") (port 25)
                                     ssl username password)
  "Create an SMTP mail backend."
  (make-instance 'smtp-mail-backend
                 :host host :port port :ssl ssl
                 :username username :password password))

(defmethod backend-send ((backend smtp-mail-backend) to subject body
                         &key from html-p headers)
  (let ((send-fn (or (find-symbol "SEND-EMAIL" (find-package "CL-SMTP"))
                     (error "cl-smtp is not loaded. (ql:quickload :cl-smtp)"))))
    (let ((from-addr (or from *from*)))
      (funcall send-fn
               (backend-host backend)
               from-addr
               (if (listp to) to (list to))
               subject
               body
               :port (backend-port backend)
               :ssl (backend-ssl backend)
               :authentication (when (backend-username backend)
                                 (list (backend-username backend)
                                       (backend-password backend)))
               :extra-headers headers
               :html-message (when html-p body)))))

;;; -------------------------------------------------------
;;; Sendmail backend
;;; -------------------------------------------------------

(defclass sendmail-mail-backend (mail-backend)
  ((command :initarg :command
            :initform "/usr/sbin/sendmail"
            :reader backend-command))
  (:documentation "Mail backend using the sendmail command-line tool."))

(defun make-sendmail-mail-backend (&key (command "/usr/sbin/sendmail"))
  "Create a sendmail mail backend."
  (make-instance 'sendmail-mail-backend :command command))

(defmethod backend-send ((backend sendmail-mail-backend) to subject body
                         &key from html-p headers)
  (let ((recipients (if (listp to) to (list to)))
        (from-addr (or from *from*)))
    (let ((process (uiop:launch-program
                    (list (backend-command backend) "-t")
                    :input :stream)))
      (let ((stream (uiop:process-info-input process)))
        (format stream "From: ~A~%" from-addr)
        (format stream "To: ~{~A~^, ~}~%" recipients)
        (format stream "Subject: ~A~%" subject)
        (when html-p
          (format stream "Content-Type: text/html; charset=utf-8~%"))
        (dolist (h headers)
          (format stream "~A: ~A~%" (car h) (cdr h)))
        (format stream "~%")
        (write-string body stream)
        (close stream))
      (uiop:wait-process process))))

;;; -------------------------------------------------------
;;; High-level API
;;; -------------------------------------------------------

(defvar *backend* (make-log-mail-backend)
  "The currently active mail backend. Defaults to log backend.")

(defvar *from* "noreply@localhost"
  "Default sender address for outgoing mail.")

(defvar *on-send* nil
  "Hook function called before sending. Receives (to subject body &key from html-p headers).
Return NIL to abort the send.")

(defun send (to subject body &key from html-p headers)
  "Send an email.
TO is a string or list of strings (recipients).
SUBJECT is the email subject line.
BODY is the email body.
FROM overrides the default *from* address.
HTML-P if true, the body is HTML content.
HEADERS is an alist of additional email headers."
  (when *on-send*
    (unless (funcall *on-send* to subject body
                     :from from :html-p html-p :headers headers)
      (return-from send nil)))
  (backend-send *backend* to subject body
                :from (or from *from*)
                :html-p html-p
                :headers headers))
