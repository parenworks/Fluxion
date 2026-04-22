;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Client - Parenscript browser runtime
;;;;
;;;; This file is compiled to JavaScript via Parenscript and served
;;;; as /static/fluxion.js.  It handles:
;;;;   - Scanning for data-* attributes and binding events
;;;;   - Opening SSE connections to the server
;;;;   - Receiving and dispatching SSE events
;;;;   - Patching/morphing/appending/removing DOM elements
;;;;   - Client-side signal state

(in-package #:fluxion.client)

;;; -------------------------------------------------------
;;; Build function - compiles this runtime to JS
;;; -------------------------------------------------------

(defun client-js-string ()
  "Return the Fluxion browser runtime as a JavaScript string."
  (ps:ps

    ;;; =====================================================
    ;;; Fluxion client runtime
    ;;; =====================================================

    ;; Signal store (client-side reactive state)
    (defvar *fluxion-signals* (create))
    (defvar *fluxion-event-source* nil)
    (defvar *fluxion-initialized* false)

    ;;; ---------------------------------------------------
    ;;; DOM helpers
    ;;; ---------------------------------------------------

    (defun fluxion-qs (selector)
      "Query a single element by CSS selector."
      (chain document (query-selector selector)))

    (defun fluxion-qsa (selector)
      "Query all elements matching CSS selector."
      (chain document (query-selector-all selector)))

    ;;; ---------------------------------------------------
    ;;; Signal management
    ;;; ---------------------------------------------------

    (defun fluxion-get-signal (name)
      (getprop *fluxion-signals* name))

    (defun fluxion-set-signal (name value)
      (setf (getprop *fluxion-signals* name) value))

    (defun fluxion-get-all-signals ()
      (let ((result (create)))
        (for-in (key *fluxion-signals*)
          (when (chain *fluxion-signals* (has-own-property key))
            (setf (getprop result key) (getprop *fluxion-signals* key))))
        result))

    ;;; ---------------------------------------------------
    ;;; DOM patching
    ;;; ---------------------------------------------------

    (defun fluxion-patch-replace (selector fragment)
      "Replace the outerHTML of the element matching SELECTOR."
      (let ((el (fluxion-qs selector)))
        (when el
          (setf (@ el outer-h-t-m-l) fragment)
          ;; Re-bind events on new content
          (fluxion-bind-actions (or (fluxion-qs selector)
                                    (@ el parent-element))))))

    (defun fluxion-patch-morph (selector fragment)
      "Morph the element matching SELECTOR to match FRAGMENT.
For v0.1 this is a simple outerHTML replacement.
A proper morphing algorithm (idiomorph-style) can be added later."
      (fluxion-patch-replace selector fragment))

    (defun fluxion-patch-inner (selector fragment)
      "Replace the innerHTML of the element matching SELECTOR."
      (let ((el (fluxion-qs selector)))
        (when el
          (setf (@ el inner-h-t-m-l) fragment)
          (fluxion-bind-actions el))))

    (defun fluxion-append-element (selector fragment)
      "Append FRAGMENT as the last child of the element matching SELECTOR."
      (let ((el (fluxion-qs selector)))
        (when el
          (chain el (insert-adjacent-h-t-m-l "beforeend" fragment))
          (fluxion-bind-actions el))))

    (defun fluxion-prepend-element (selector fragment)
      "Prepend FRAGMENT as the first child of the element matching SELECTOR."
      (let ((el (fluxion-qs selector)))
        (when el
          (chain el (insert-adjacent-h-t-m-l "afterbegin" fragment))
          (fluxion-bind-actions el))))

    (defun fluxion-remove-element (selector)
      "Remove the element matching SELECTOR from the DOM."
      (let ((el (fluxion-qs selector)))
        (when el
          (chain el (remove)))))

    ;;; ---------------------------------------------------
    ;;; SSE event handlers
    ;;; ---------------------------------------------------

    (defun fluxion-handle-patch (data)
      (let ((selector (@ data selector))
            (fragment (@ data fragment))
            (mode     (or (@ data mode) "morph")))
        (cond
          ((string= mode "morph")   (fluxion-patch-morph selector fragment))
          ((string= mode "replace") (fluxion-patch-replace selector fragment))
          ((string= mode "inner")   (fluxion-patch-inner selector fragment))
          (t (fluxion-patch-morph selector fragment)))))

    (defun fluxion-handle-remove (data)
      (fluxion-remove-element (@ data selector)))

    (defun fluxion-handle-append (data)
      (fluxion-append-element (@ data selector) (@ data fragment)))

    (defun fluxion-handle-prepend (data)
      (fluxion-prepend-element (@ data selector) (@ data fragment)))

    (defun fluxion-handle-signals (data)
      (let ((signals (@ data signals)))
        (when signals
          (for-in (key signals)
            (when (chain signals (has-own-property key))
              (fluxion-set-signal key (getprop signals key))))
          ;; Update any data-text bindings
          (fluxion-update-text-bindings))))

    (defun fluxion-handle-script (data)
      (let ((script (@ data script)))
        (when script
          (eval script))))

    (defun fluxion-handle-redirect (data)
      (let ((url (@ data url)))
        (when url
          (setf (@ window location href) url))))

    ;;; ---------------------------------------------------
    ;;; SSE connection
    ;;; ---------------------------------------------------

    (defun fluxion-post (url &optional body callback)
      "Send a POST request to URL with optional JSON BODY.
The response is expected to be text/event-stream (SSE).
Parses the SSE response and dispatches events."
      (let ((xhr (new (-x-m-l-http-request))))
        (chain xhr (open "POST" url t))
        (chain xhr (set-request-header "Content-Type" "application/json"))
        (chain xhr (set-request-header "Accept" "text/event-stream"))
        (setf (@ xhr onreadystatechange)
              (lambda ()
                (when (and (= (@ xhr ready-state) 4)
                           (= (@ xhr status) 200))
                  (fluxion-parse-sse-response (@ xhr response-text))
                  (when callback
                    (funcall callback)))))
        (chain xhr (send (if body
                             (chain -j-s-o-n (stringify body))
                             "")))))

    (defun fluxion-parse-sse-response (text)
      "Parse an SSE text response and dispatch events."
      (let ((blocks (chain text (split (ps:regex "\\n\\n")))))
        (chain blocks (for-each
                       (lambda (block)
                         (when (and block (> (@ block length) 0))
                           (let ((event-type nil)
                                 (data-lines (array)))
                             (let ((lines (chain block (split (ps:regex "\\n")))))
                               (chain lines (for-each
                                             (lambda (line)
                                               (cond
                                                 ((chain line (starts-with "event: "))
                                                  (setf event-type (chain line (substring 7))))
                                                 ((chain line (starts-with "data: "))
                                                  (chain data-lines (push (chain line (substring 6))))))))))
                             (when (and event-type (> (@ data-lines length) 0))
                               (let ((data-str (chain data-lines (join (chain -string (from-char-code 10))))))
                                 (let ((data (chain -j-s-o-n (parse data-str))))
                                   (fluxion-dispatch-event event-type data)))))))))))

    (defun fluxion-dispatch-event (event-type data)
      "Dispatch a parsed SSE event to the appropriate handler."
      (cond
        ((string= event-type "fluxion-patch")    (fluxion-handle-patch data))
        ((string= event-type "fluxion-remove")   (fluxion-handle-remove data))
        ((string= event-type "fluxion-append")   (fluxion-handle-append data))
        ((string= event-type "fluxion-prepend")  (fluxion-handle-prepend data))
        ((string= event-type "fluxion-signals")  (fluxion-handle-signals data))
        ((string= event-type "fluxion-script")   (fluxion-handle-script data))
        ((string= event-type "fluxion-redirect") (fluxion-handle-redirect data))
        (t (chain console (log "Fluxion: unknown event type:" event-type)))))

    ;;; ---------------------------------------------------
    ;;; Param collection
    ;;; ---------------------------------------------------

    (defun fluxion-collect-params (el)
      "Collect data-param-* attributes from EL into an object.
E.g. data-param-id='42' becomes {id: '42'} in the result."
      (let ((params (create)))
        (let ((attrs (@ el attributes)))
          (let ((i 0))
            (loop while (< i (@ attrs length)) do
              (let ((attr (aref attrs i)))
                (when (chain (@ attr name) (starts-with "data-param-"))
                  (let ((key (chain (@ attr name) (substring 11))))
                    (setf (getprop params key) (@ attr value)))))
              (incf i))))
        params))

    (defun fluxion-merge-body (el)
      "Build the POST body: signals merged with element data-param-* attributes."
      (let ((body (fluxion-get-all-signals))
            (params (fluxion-collect-params el)))
        (for-in (key params)
          (when (chain params (has-own-property key))
            (setf (getprop body key) (getprop params key))))
        body))

    ;;; ---------------------------------------------------
    ;;; Action binding (data-* attributes)
    ;;; ---------------------------------------------------

    (defun fluxion-bind-actions (&optional root)
      "Scan for data-on-* attributes and bind event listeners.
ROOT defaults to document."
      (let ((root (or root document)))

        ;; data-on-click=\"/path\"
        (let ((click-els (chain root (query-selector-all "[data-on-click]"))))
          (chain click-els (for-each
                            (lambda (el)
                              (unless (@ el _fluxion-click-bound)
                                (let ((action-url (chain el (get-attribute "data-on-click"))))
                                  (chain el (add-event-listener "click"
                                                                (lambda (e)
                                                                  (chain e (prevent-default))
                                                                  (let ((confirm-msg (chain el (get-attribute "data-confirm"))))
                                                                    (when (or (not confirm-msg)
                                                                              (chain window (confirm confirm-msg)))
                                                                      (fluxion-post action-url
                                                                                    (fluxion-merge-body el)))))))
                                  (setf (@ el _fluxion-click-bound) t)))))))

        ;; data-on-submit=\"/path\"
        (let ((submit-els (chain root (query-selector-all "[data-on-submit]"))))
          (chain submit-els (for-each
                             (lambda (el)
                               (unless (@ el _fluxion-submit-bound)
                                 (let ((action-url (chain el (get-attribute "data-on-submit"))))
                                   (chain el (add-event-listener "submit"
                                                                 (lambda (e)
                                                                   (chain e (prevent-default))
                                                                   ;; Collect form data as signals
                                                                   (let ((form-data (new (-form-data el))))
                                                                     (chain form-data (for-each
                                                                                       (lambda (value key)
                                                                                         (fluxion-set-signal key value))))
                                                                     (fluxion-post action-url
                                                                                   (fluxion-merge-body el))))))
                                   (setf (@ el _fluxion-submit-bound) t)))))))

        ;; data-on-change=\"/path\" - for checkboxes, selects, radio buttons
        (let ((change-els (chain root (query-selector-all "[data-on-change]"))))
          (chain change-els (for-each
                             (lambda (el)
                               (unless (@ el _fluxion-change-bound)
                                 (let ((action-url (chain el (get-attribute "data-on-change"))))
                                   (chain el (add-event-listener "change"
                                                                 (lambda (e)
                                                                   (chain e (prevent-default))
                                                                   ;; Include element value/checked state
                                                                   (let ((body (fluxion-merge-body el)))
                                                                     (if (string= (@ el type) "checkbox")
                                                                         (setf (getprop body "checked")
                                                                               (if (@ el checked) "true" "false"))
                                                                         (setf (getprop body "value") (@ el value)))
                                                                     (fluxion-post action-url body)))))
                                   (setf (@ el _fluxion-change-bound) t)))))))

        ;; data-on-keydown=\"/path\" with optional data-key=\"Enter\" filter
        (let ((keydown-els (chain root (query-selector-all "[data-on-keydown]"))))
          (chain keydown-els (for-each
                              (lambda (el)
                                (unless (@ el _fluxion-keydown-bound)
                                  (let ((action-url (chain el (get-attribute "data-on-keydown")))
                                        (key-filter (chain el (get-attribute "data-key"))))
                                    (chain el (add-event-listener "keydown"
                                                                  (lambda (e)
                                                                    (when (or (not key-filter)
                                                                              (string= (@ e key) key-filter))
                                                                      (chain e (prevent-default))
                                                                      (let ((body (fluxion-merge-body el)))
                                                                        (setf (getprop body "value") (@ el value))
                                                                        (fluxion-post action-url body))))))
                                    (setf (@ el _fluxion-keydown-bound) t)))))))

        ;; data-on-input=\"/path\" - fires on each input keystroke
        (let ((input-els (chain root (query-selector-all "[data-on-input]"))))
          (chain input-els (for-each
                            (lambda (el)
                              (unless (@ el _fluxion-input-bound)
                                (let ((action-url (chain el (get-attribute "data-on-input"))))
                                  (chain el (add-event-listener "input"
                                                                (lambda (e)
                                                                  (let ((body (fluxion-merge-body el)))
                                                                    (setf (getprop body "value") (@ el value))
                                                                    (fluxion-post action-url body)))))
                                  (setf (@ el _fluxion-input-bound) t)))))))

        ;; data-bind=\"signal-name\" - two-way binding for inputs
        (let ((bind-els (chain root (query-selector-all "[data-bind]"))))
          (chain bind-els (for-each
                           (lambda (el)
                             (unless (@ el _fluxion-bind-bound)
                               (let ((signal-name (chain el (get-attribute "data-bind"))))
                                 ;; Set initial value from signals if present
                                 (let ((current (fluxion-get-signal signal-name)))
                                   (when (not (= current undefined))
                                     (setf (@ el value) current)))
                                 ;; Bind input event
                                 (chain el (add-event-listener "input"
                                                               (lambda (e)
                                                                 (fluxion-set-signal signal-name (@ el value))
                                                                 (fluxion-update-text-bindings))))
                                 (setf (@ el _fluxion-bind-bound) t)))))))))

    ;;; ---------------------------------------------------
    ;;; Text bindings (data-text)
    ;;; ---------------------------------------------------

    (defun fluxion-update-text-bindings ()
      "Update all elements with data-text attribute from signal values."
      (let ((text-els (chain document (query-selector-all "[data-text]"))))
        (chain text-els (for-each
                         (lambda (el)
                           (let* ((expr (chain el (get-attribute "data-text")))
                                  (signal-name (if (chain expr (starts-with "$"))
                                                   (chain expr (substring 1))
                                                   expr))
                                  (value (fluxion-get-signal signal-name)))
                             (when (not (= value undefined))
                               (setf (@ el text-content) value))))))))

    ;;; ---------------------------------------------------
    ;;; Initialization
    ;;; ---------------------------------------------------

    (defun fluxion-init ()
      "Initialize the Fluxion client runtime."
      (when *fluxion-initialized*
        (return-from fluxion-init))
      (setf *fluxion-initialized* t)
      (chain console (log "Fluxion: initializing client runtime"))
      (fluxion-bind-actions)
      (fluxion-update-text-bindings)
      (chain console (log "Fluxion: ready")))

    ;; Auto-initialize when DOM is ready
    (if (string= (@ document ready-state) "loading")
        (chain document (add-event-listener "DOMContentLoaded" fluxion-init))
        (fluxion-init))

    ))

(defun build-client (&key (output-path
                           (asdf:system-relative-pathname "fluxion" "static/fluxion.js")))
  "Compile the Fluxion Parenscript runtime and write it to OUTPUT-PATH."
  (ensure-directories-exist output-path)
  (let ((js (client-js-string)))
    (with-open-file (stream output-path
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string js stream))
    (format t "Fluxion: client runtime written to ~A (~A bytes)~%"
            output-path (length js))
    output-path))
