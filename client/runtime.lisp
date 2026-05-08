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
    (defvar *fluxion-sse-reconnect-timer* nil)
    (defvar *fluxion-sse-retry-delay* 1000)
    (defvar *fluxion-sse-retry-count* 0)
    (defvar *fluxion-sse-max-retries* 50)
    (defvar *fluxion-sse-base-delay* 1000)
    (defvar *fluxion-sse-max-delay* 30000)
    (defvar *fluxion-sse-was-connected* false)
    (defvar *fluxion-navigate-callbacks* (array))

    (defun fluxion-on-navigate (callback)
      "Register a CALLBACK to be invoked after SPA content navigation.
CALLBACK receives the container element that was updated."
      (chain *fluxion-navigate-callbacks* (push callback)))

    (defun fluxion-navigated (container)
      "Notify Fluxion that SPA navigation has occurred on CONTAINER.
Re-binds actions and text bindings, then invokes registered callbacks."
      (fluxion-bind-actions container)
      (fluxion-update-text-bindings)
      (chain *fluxion-navigate-callbacks* (for-each
        (lambda (cb) (funcall cb container)))))

    (defun fluxion-get-csrf-token ()
      "Read the CSRF token from the meta tag in the page head."
      (let ((meta (chain document (query-selector "meta[name=fluxion-csrf]"))))
        (if meta
            (chain meta (get-attribute "content"))
            nil)))

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

    (defun fluxion-morph-nodes (old-node new-node)
      "Recursively morph OLD-NODE to match NEW-NODE, preserving focus and input state."
      (when (or (not old-node) (not new-node))
        (return-from fluxion-morph-nodes))

      ;; Different node types or different tag names - replace wholesale
      (when (or (not (= (@ old-node node-type) (@ new-node node-type)))
                (and (= (@ old-node node-type) 1)
                     (not (string= (@ old-node tag-name) (@ new-node tag-name)))))
        (chain (@ old-node parent-node) (replace-child (chain new-node (clone-node t)) old-node))
        (return-from fluxion-morph-nodes))

      ;; Text or comment nodes - just update content
      (when (or (= (@ old-node node-type) 3)
                (= (@ old-node node-type) 8))
        (when (not (string= (@ old-node node-value) (@ new-node node-value)))
          (setf (@ old-node node-value) (@ new-node node-value)))
        (return-from fluxion-morph-nodes))

      ;; Element nodes - sync attributes, then children
      (when (= (@ old-node node-type) 1)
        (fluxion-sync-attrs old-node new-node)
        (fluxion-morph-children old-node new-node)))

    (defun fluxion-sync-attrs (old-el new-el)
      "Synchronise attributes from NEW-EL onto OLD-EL.
Skips the value attribute on the currently focused element to preserve user input.
Also syncs the DOM value property on non-focused inputs so displayed values update
even after user interaction (setAttribute alone does not update the display)."
      (let ((is-focused (= old-el (@ document active-element)))
            (old-attrs (create))
            (i 0))
        ;; Collect old attributes
        (loop while (< i (@ old-el attributes length)) do
          (let ((attr (aref (@ old-el attributes) i)))
            (setf (getprop old-attrs (@ attr name)) (@ attr value)))
          (incf i))
        ;; Set/update attributes from new element
        (setf i 0)
        (loop while (< i (@ new-el attributes length)) do
          (let ((attr (aref (@ new-el attributes) i)))
            (let ((name (@ attr name))
                  (val  (@ attr value)))
              ;; Skip value on focused input to preserve cursor/selection
              (unless (and is-focused (string= name "value"))
                (when (not (string= (chain old-el (get-attribute name)) val))
                  (chain old-el (set-attribute name val)))
                ;; Sync the DOM property for value on non-focused inputs
                (when (and (string= name "value")
                           (or (string= (@ old-el tag-name) "INPUT")
                               (string= (@ old-el tag-name) "TEXTAREA")
                               (string= (@ old-el tag-name) "SELECT"))
                           (not (string= (@ old-el value) val)))
                  (setf (@ old-el value) val)))
              (delete (getprop old-attrs name))))
          (incf i))
        ;; Remove attributes not in new element
        (for-in (name old-attrs)
          (when (chain old-attrs (has-own-property name))
            (chain old-el (remove-attribute name))))))

    (defun fluxion-morph-children (old-el new-el)
      "Morph the child nodes of OLD-EL to match those of NEW-EL."
      (let ((old-children (@ old-el child-nodes))
            (new-children (@ new-el child-nodes))
            (i 0))
        ;; Walk through new children
        (loop while (< i (@ new-children length)) do
          (let ((new-child (aref new-children i)))
            (if (< i (@ old-children length))
                ;; Existing child - morph it
                (let ((old-child (aref old-children i)))
                  (if (and (= (@ old-child node-type) 1)
                           (= (@ new-child node-type) 1)
                           (string= (@ old-child tag-name) (@ new-child tag-name))
                           (@ old-child id)
                           (@ new-child id)
                           (not (string= (@ old-child id) (@ new-child id))))
                      ;; Different IDs on elements - replace, don't morph
                      (chain old-el (replace-child (chain new-child (clone-node t)) old-child))
                      ;; Same structure - recurse
                      (fluxion-morph-nodes old-child new-child)))
                ;; New child beyond old length - append
                (chain old-el (append-child (chain new-child (clone-node t))))))
          (incf i))
        ;; Remove excess old children
        (loop while (> (@ old-el child-nodes length) (@ new-children length)) do
          (chain old-el (remove-child (@ old-el last-child))))))

    (defun fluxion-patch-morph (selector fragment)
      "Morph the element matching SELECTOR to match FRAGMENT.
Diffs the DOM trees and only updates what changed, preserving
focus, input values, and selection state on the active element."
      (let ((old-el (fluxion-qs selector)))
        (if old-el
            ;; Parse the fragment into a temporary DOM node
            (let ((template (chain document (create-element "template"))))
              (setf (@ template inner-h-t-m-l) fragment)
              (let ((new-el (@ template content first-element-child)))
                (if new-el
                    (progn
                      (chain console (log "Fluxion morph:" selector
                                          "old-children=" (@ old-el child-nodes length)
                                          "new-children=" (@ new-el child-nodes length)))
                      (fluxion-morph-nodes old-el new-el)
                      ;; Re-bind actions on new/changed content
                      (fluxion-bind-actions old-el))
                    ;; Fallback to replace if parsing fails
                    (fluxion-patch-replace selector fragment))))
            (chain console (log "Fluxion morph: element not found:" selector)))))

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

    (defun fluxion-post (url &optional body callback retried)
      "Send a POST request to URL with optional JSON BODY.
The response is expected to be text/event-stream (SSE).
Parses the SSE response and dispatches events.
Retries once on network error (status 0) from stale keep-alive."
      (let ((xhr (new (-x-m-l-http-request))))
        (chain xhr (open "POST" url t))
        (chain xhr (set-request-header "Content-Type" "application/json"))
        (chain xhr (set-request-header "Accept" "text/event-stream"))
        (let ((csrf (fluxion-get-csrf-token)))
          (when csrf
            (chain xhr (set-request-header "X-CSRF-Token" csrf))))
        (setf (@ xhr onreadystatechange)
              (lambda ()
                (when (= (@ xhr ready-state) 4)
                  (cond
                    ((= (@ xhr status) 200)
                     (fluxion-parse-sse-response (@ xhr response-text))
                     (when callback
                       (funcall callback)))
                    ;; Status 0 = network error, retry once (stale keep-alive)
                    ((and (= (@ xhr status) 0) (not retried))
                     (chain console (log "Fluxion: retrying POST" url))
                     (fluxion-post url body callback t))
                    (t
                     (fluxion-show-error
                      (+ "Request failed (" (@ xhr status) "): " url)))))))
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
        ;; data-disable-during-request - disables element while request is in flight
        (let ((click-els (chain root (query-selector-all "[data-on-click]"))))
          (chain click-els (for-each
                            (lambda (el)
                              (unless (@ el _fluxion-click-bound)
                                (chain el (add-event-listener "click"
                                                              (lambda (e)
                                                                (chain e (prevent-default))
                                                                (let ((action-url (chain el (get-attribute "data-on-click")))
                                                                      (confirm-msg (chain el (get-attribute "data-confirm")))
                                                                      (should-disable (chain el (has-attribute "data-disable-during-request"))))
                                                                  (when (or (not confirm-msg)
                                                                            (chain window (confirm confirm-msg)))
                                                                    (when should-disable
                                                                      (setf (@ el disabled) t))
                                                                    (fluxion-post action-url
                                                                                  (fluxion-merge-body el)
                                                                                  (when should-disable
                                                                                    (lambda ()
                                                                                      (setf (@ el disabled) false)))))))))
                                (setf (@ el _fluxion-click-bound) t))))))

        ;; data-on-submit=\"/path\"
        (let ((submit-els (chain root (query-selector-all "[data-on-submit]"))))
          (chain submit-els (for-each
                             (lambda (el)
                               (unless (@ el _fluxion-submit-bound)
                                 (chain el (add-event-listener "submit"
                                                               (lambda (e)
                                                                 (chain e (prevent-default))
                                                                 (let ((action-url (chain el (get-attribute "data-on-submit")))
                                                                       (form-data (new (-form-data el))))
                                                                   (chain form-data (for-each
                                                                                     (lambda (value key)
                                                                                       (fluxion-set-signal key value))))
                                                                   (fluxion-post action-url
                                                                                 (fluxion-merge-body el))))))
                                 (setf (@ el _fluxion-submit-bound) t))))))

        ;; data-on-change=\"/path\" - for checkboxes, selects, radio buttons
        (let ((change-els (chain root (query-selector-all "[data-on-change]"))))
          (chain change-els (for-each
                             (lambda (el)
                               (unless (@ el _fluxion-change-bound)
                                 (chain el (add-event-listener "change"
                                                               (lambda (e)
                                                                 (chain e (prevent-default))
                                                                 (let ((action-url (chain el (get-attribute "data-on-change")))
                                                                       (body (fluxion-merge-body el)))
                                                                   (if (string= (@ el type) "checkbox")
                                                                       (setf (getprop body "checked")
                                                                             (if (@ el checked) "true" "false"))
                                                                       (setf (getprop body "value") (@ el value)))
                                                                   (fluxion-post action-url body)))))
                                 (setf (@ el _fluxion-change-bound) t))))))

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

        ;; data-on-input=\"/path\" - fires on input (with optional debounce)
        ;; data-debounce=\"300\" - debounce delay in ms (default: no debounce)
        (let ((input-els (chain root (query-selector-all "[data-on-input]"))))
          (chain input-els (for-each
                            (lambda (el)
                              (unless (@ el _fluxion-input-bound)
                                (let ((action-url (chain el (get-attribute "data-on-input")))
                                      (debounce-ms (parse-int (or (chain el (get-attribute "data-debounce")) "0") 10)))
                                  (if (and debounce-ms (> debounce-ms 0))
                                      ;; Debounced: delay POST until user stops typing
                                      (chain el (add-event-listener "input"
                                                                    (lambda (e)
                                                                      (when (@ el _fluxion-debounce-timer)
                                                                        (clear-timeout (@ el _fluxion-debounce-timer)))
                                                                      (setf (@ el _fluxion-debounce-timer)
                                                                            (set-timeout
                                                                             (lambda ()
                                                                               (let ((body (fluxion-merge-body el)))
                                                                                 (setf (getprop body "value") (@ el value))
                                                                                 (fluxion-post action-url body)))
                                                                             debounce-ms)))))
                                      ;; No debounce: fire immediately
                                      (chain el (add-event-listener "input"
                                                                    (lambda (e)
                                                                      (let ((body (fluxion-merge-body el)))
                                                                        (setf (getprop body "value") (@ el value))
                                                                        (fluxion-post action-url body))))))
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
    ;;; Error toast
    ;;; ---------------------------------------------------

    (defun fluxion-show-error (message)
      "Show an error toast notification. Auto-dismisses after 8 seconds."
      (chain console (warn "Fluxion error:" message))
      (let ((existing (fluxion-qs "#fluxion-error-toast")))
        (when existing
          (chain existing (remove))))
      (let ((toast (chain document (create-element "div"))))
        (setf (@ toast id) "fluxion-error-toast")
        (setf (@ toast inner-h-t-m-l)
              (+ "<span>" message "</span>"
                 "<button onclick=\"fluxionDismissError()\">&times;</button>"))
        (setf (@ toast style css-text)
              (+ "position:fixed;bottom:1rem;right:1rem;max-width:28rem;"
                 "background:#d9534f;color:#fff;padding:0.75rem 1rem;"
                 "border-radius:6px;font-size:0.9rem;z-index:9999;"
                 "display:flex;align-items:center;gap:0.75rem;"
                 "box-shadow:0 4px 12px rgba(0,0,0,0.2);animation:fluxionFadeIn 0.2s"))
        (let ((btn (chain toast (query-selector "button"))))
          (setf (@ btn style css-text)
                "background:none;border:none;color:#fff;font-size:1.2rem;cursor:pointer;padding:0;line-height:1"))
        (chain document body (append-child toast))
        (set-timeout (lambda ()
                       (fluxion-dismiss-error))
                     8000)))

    (defun fluxion-dismiss-error ()
      "Dismiss the error toast if present."
      (let ((toast (fluxion-qs "#fluxion-error-toast")))
        (when toast
          (chain toast (remove)))))

    ;;; ---------------------------------------------------
    ;;; Connection status banner
    ;;; ---------------------------------------------------

    (defun fluxion-show-connection-status (state &optional detail)
      "Show or update the connection status banner.
STATE is one of: reconnecting, lost, connected."
      (let ((banner (fluxion-qs "#fluxion-connection-banner")))
        (when (string= state "connected")
          ;; Remove banner after brief 'reconnected' flash
          (when banner
            (setf (@ banner inner-h-t-m-l)
                  "<span>&#x2713; Reconnected</span>")
            (setf (@ banner style background) "#2d8a4e")
            (set-timeout (lambda ()
                           (let ((b (fluxion-qs "#fluxion-connection-banner")))
                             (when b (chain b (remove)))))
                         2000))
          (return-from fluxion-show-connection-status))
        ;; Create banner if not present
        (unless banner
          (setf banner (chain document (create-element "div")))
          (setf (@ banner id) "fluxion-connection-banner")
          (setf (@ banner style css-text)
                (+ "position:fixed;top:0;left:0;right:0;z-index:10000;"
                   "padding:6px 12px;font-size:0.8rem;font-family:sans-serif;"
                   "text-align:center;color:#fff;transition:background 0.3s"))
          (chain document body (append-child banner)))
        (cond
          ((string= state "reconnecting")
           (setf (@ banner style background) "#b87a1a")
           (setf (@ banner inner-h-t-m-l)
                 (+ "<span>Connection lost. Reconnecting"
                    (if detail (+ " in " detail "s") "")
                    "...</span>")))
          ((string= state "lost")
           (setf (@ banner style background) "#d9534f")
           (setf (@ banner inner-h-t-m-l)
                 (+ "<span>Connection lost. </span>"
                    "<button onclick=\"fluxionReconnect()\" style=\""
                    "background:#fff;color:#d9534f;border:none;border-radius:4px;"
                    "padding:2px 10px;margin-left:8px;cursor:pointer;font-size:0.8rem"
                    "\">Reconnect</button>"))))))

    ;;; ---------------------------------------------------
    ;;; Persistent SSE connection with exponential backoff
    ;;; ---------------------------------------------------

    (defun fluxion-compute-retry-delay ()
      "Compute the next retry delay with exponential backoff and jitter."
      (let* ((exp-delay (* *fluxion-sse-base-delay*
                           (chain -math (pow 2 *fluxion-sse-retry-count*))))
             (capped (chain -math (min exp-delay *fluxion-sse-max-delay*)))
             (jitter (* capped (+ 0.5 (* (chain -math (random)) 0.5)))))
        (chain -math (floor jitter))))

    (defun fluxion-schedule-reconnect ()
      "Schedule an SSE reconnection with exponential backoff."
      (when *fluxion-sse-reconnect-timer*
        (clear-timeout *fluxion-sse-reconnect-timer*)
        (setf *fluxion-sse-reconnect-timer* nil))
      (if (>= *fluxion-sse-retry-count* *fluxion-sse-max-retries*)
          (progn
            (chain console (error
              (+ "Fluxion: gave up reconnecting after "
                 *fluxion-sse-max-retries* " attempts")))
            (fluxion-show-connection-status "lost"))
          (let ((delay (fluxion-compute-retry-delay)))
            (incf *fluxion-sse-retry-count*)
            (let ((secs (chain -math (ceil (/ delay 1000)))))
              (chain console (warn
                (+ "Fluxion: reconnecting in " secs "s (attempt "
                   *fluxion-sse-retry-count* ")")))
              (fluxion-show-connection-status "reconnecting" secs))
            (setf *fluxion-sse-reconnect-timer*
                  (set-timeout fluxion-connect-sse delay)))))

    (defun fluxion-reconnect ()
      "Manual reconnect - resets retry state and connects immediately."
      (setf *fluxion-sse-retry-count* 0)
      (setf *fluxion-sse-retry-delay* *fluxion-sse-base-delay*)
      (fluxion-connect-sse))

    (defun fluxion-connect-sse ()
      "Open a persistent EventSource connection to /sse for server-push.
Uses exponential backoff with jitter on connection failure."
      (when *fluxion-event-source*
        (chain *fluxion-event-source* (close))
        (setf *fluxion-event-source* nil))
      (when *fluxion-sse-reconnect-timer*
        (clear-timeout *fluxion-sse-reconnect-timer*)
        (setf *fluxion-sse-reconnect-timer* nil))
      (let ((source (new (-event-source "/sse"))))
        (setf *fluxion-event-source* source)
        ;; Register handlers for each Fluxion event type
        (chain source (add-event-listener "fluxion-patch"
                        (lambda (e)
                          (let ((data (chain -j-s-o-n (parse (@ e data)))))
                            (chain console (log "Fluxion SSE: received patch for" (@ data selector)))
                            (fluxion-handle-patch data)))))
        (chain source (add-event-listener "fluxion-remove"
                        (lambda (e)
                          (fluxion-handle-remove (chain -j-s-o-n (parse (@ e data)))))))
        (chain source (add-event-listener "fluxion-append"
                        (lambda (e)
                          (fluxion-handle-append (chain -j-s-o-n (parse (@ e data)))))))
        (chain source (add-event-listener "fluxion-prepend"
                        (lambda (e)
                          (fluxion-handle-prepend (chain -j-s-o-n (parse (@ e data)))))))
        (chain source (add-event-listener "fluxion-signals"
                        (lambda (e)
                          (fluxion-handle-signals (chain -j-s-o-n (parse (@ e data)))))))
        (chain source (add-event-listener "fluxion-script"
                        (lambda (e)
                          (fluxion-handle-script (chain -j-s-o-n (parse (@ e data)))))))
        (chain source (add-event-listener "fluxion-redirect"
                        (lambda (e)
                          (fluxion-handle-redirect (chain -j-s-o-n (parse (@ e data)))))))
        ;; Connection opened successfully - reset backoff
        (setf (@ source onopen)
              (lambda ()
                (chain console (log "Fluxion: SSE connection opened"))
                (when *fluxion-sse-was-connected*
                  ;; Show reconnected flash only if we had a previous connection
                  (fluxion-show-connection-status "connected"))
                (setf *fluxion-sse-was-connected* t)
                (setf *fluxion-sse-retry-count* 0)
                (setf *fluxion-sse-retry-delay* *fluxion-sse-base-delay*)))
        ;; Connection lost - schedule reconnect with backoff
        (setf (@ source onerror)
              (lambda ()
                (chain source (close))
                (setf *fluxion-event-source* nil)
                (fluxion-schedule-reconnect)))))

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
      (fluxion-connect-sse)
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
