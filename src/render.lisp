;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Rendering helpers (Spinneret)

(in-package #:fluxion.render)

;;; -------------------------------------------------------
;;; Render helpers
;;; -------------------------------------------------------

(defun render-to-string (component)
  "Call the RENDER generic function on COMPONENT and return the HTML string."
  (render component))

(defun fluxion-script-tag (&key (path "/static/fluxion.js"))
  "Return an HTML <script> tag that loads the Fluxion client runtime."
  (format nil "<script src=\"~A\"></script>" path))

(defun csrf-meta-tag (token)
  "Return an HTML meta tag containing the CSRF token.
The client runtime reads this and includes it in every POST request."
  (format nil "<meta name=\"fluxion-csrf\" content=\"~A\">" token))

(defun render-page (&key title body-html head-html csrf-token (script-path "/static/fluxion.js"))
  "Render a full HTML page shell with the Fluxion client runtime included.
TITLE is the page title.
BODY-HTML is a string of HTML to place in the <body>.
HEAD-HTML is optional extra HTML for the <head>.
CSRF-TOKEN is the session's CSRF token (included as a meta tag).
SCRIPT-PATH is the URL path to fluxion.js."
  (spinneret:with-html-string
    (:doctype)
    (:html
     (:head
      (:meta :charset "utf-8")
      (:meta :name "viewport" :content "width=device-width, initial-scale=1")
      (when csrf-token
        (:raw (csrf-meta-tag csrf-token)))
      (when head-html
        (:raw head-html))
      (:title title))
     (:body
      (:raw body-html)
      (:script :src script-path)))))
