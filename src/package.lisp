;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Package definitions

(defpackage #:fluxion.protocol
  (:use #:cl)
  (:export
   ;; SSE event types
   #:sse-event
   #:event-type
   #:event-data
   #:event-id
   #:event-retry
   #:format-sse-event
   #:write-sse-event
   ;; Event type constants
   #:+patch-elements+
   #:+remove-elements+
   #:+append-elements+
   #:+prepend-elements+
   #:+patch-signals+
   #:+execute-script+
   #:+redirect+))

(defpackage #:fluxion.events
  (:use #:cl #:fluxion.protocol)
  (:export
   #:make-patch-event
   #:make-remove-event
   #:make-append-event
   #:make-prepend-event
   #:make-signal-event
   #:make-script-event
   #:make-redirect-event))

(defpackage #:fluxion.signals
  (:use #:cl)
  (:export
   #:signal-store
   #:make-signal-store
   #:get-signal
   #:set-signal
   #:signals-to-alist
   #:alist-to-signals
   #:merge-signals))

(defpackage #:fluxion.components
  (:use #:cl)
  (:export
   #:component
   #:component-id
   #:component-signals
   #:render
   #:handle-action
   #:component-selector))

(defpackage #:fluxion.render
  (:use #:cl #:fluxion.components)
  (:export
   #:render-to-string
   #:render-page
   #:fluxion-script-tag))

(defpackage #:fluxion.server
  (:use #:cl
        #:fluxion.protocol
        #:fluxion.events
        #:fluxion.signals
        #:fluxion.components
        #:fluxion.render)
  (:export
   #:fluxion-app
   #:make-fluxion-app
   #:register-component
   #:find-component
   #:register-action
   #:start
   #:stop
   #:with-event-stream
   #:patch
   #:send-event))

(defpackage #:fluxion
  (:use #:cl)
  (:nicknames #:fx)
  (:export
   ;; Re-export key symbols from sub-packages
   ;; Components
   #:component
   #:component-id
   #:render
   #:handle-action
   ;; Server
   #:fluxion-app
   #:make-fluxion-app
   #:register-component
   #:register-action
   #:start
   #:stop
   #:patch
   #:send-event
   #:with-event-stream
   ;; Events
   #:make-patch-event
   #:make-remove-event
   #:make-append-event
   #:make-prepend-event
   #:make-signal-event
   #:make-script-event
   #:make-redirect-event
   ;; Signals
   #:signal-store
   #:make-signal-store
   #:get-signal
   #:set-signal
   ;; Render
   #:render-to-string
   #:render-page
   #:fluxion-script-tag
   ;; Protocol
   #:format-sse-event
   #:write-sse-event))
