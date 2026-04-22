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
   #:defaction
   #:defcomponent
   #:patch-component
   #:component-selector
   #:component-dirty-p
   #:component-last-html
   #:mark-dirty
   #:clear-dirty))

(defpackage #:fluxion.cells
  (:use #:cl)
  (:nicknames #:fluxion.lattice)
  (:export
   #:cell
   #:make-cell
   #:cell-value
   #:cell-name
   #:cell-watchers
   #:cell-test
   #:watch
   #:unwatch
   #:connect
   #:disconnect
   #:*pending-events*
   #:collect-event
   #:collect-events
   #:drain-pending-events
   #:computed-cell
   #:make-computed
   #:recompute
   #:computed-dependencies
   #:propagator
   #:make-propagator
   #:fire-propagator
   #:remove-propagator
   #:propagator-name
   #:propagator-inputs
   #:propagator-outputs
   #:with-transaction
   #:cell-height
   #:cell-watcher
   #:make-cell-watcher))

(defpackage #:fluxion.render
  (:use #:cl #:fluxion.components)
  (:export
   #:render-to-string
   #:render-page
   #:fluxion-script-tag
   #:csrf-meta-tag))

(defpackage #:fluxion.validation
  (:use #:cl)
  (:export
   #:validation-result
   #:make-validation-result
   #:add-error
   #:field-error
   #:valid-p
   #:errors-alist
   #:errors-plist
   #:validate
   #:validation-error-events
   #:clear-error-events
   ;; Built-in validators
   #:required
   #:min-length
   #:max-length
   #:matches-pattern
   #:email
   #:integer-string
   #:number-string
   #:one-of
   #:predicate
   #:confirmed))

(defpackage #:fluxion.server
  (:use #:cl
        #:fluxion.protocol
        #:fluxion.events
        #:fluxion.signals
        #:fluxion.components
        #:fluxion.cells
        #:fluxion.render)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export
   #:fluxion-app
   #:make-fluxion-app
   #:register-component
   #:register-component-factory
   #:find-component
   #:register-action
   #:start
   #:stop
   #:with-event-stream
   #:patch
   #:send-event
   #:session
   #:session-id
   #:session-component
   #:session-components
   #:session-csrf-token
   #:session-user
   #:session-user-roles
   #:authenticated-p
   #:authenticate
   #:logout
   #:has-role-p
   #:require-auth
   #:require-role
   #:router
   #:make-router
   #:add-route
   #:defroute
   #:dispatch-route
   #:router-handler
   #:app-handler
   #:app-session-lock
   #:app-sessions
   #:push-event
   #:push-events
   #:push-component-patch
   #:parse-request-body))

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
   #:defaction
   #:patch-component
   #:mark-dirty
   #:clear-dirty
   ;; Server
   #:fluxion-app
   #:make-fluxion-app
   #:register-component
   #:register-component-factory
   #:register-action
   #:start
   #:stop
   #:patch
   #:send-event
   #:with-event-stream
   #:session
   #:session-component
   #:session-csrf-token
   #:session-user
   #:session-user-roles
   #:authenticated-p
   #:authenticate
   #:logout
   #:has-role-p
   #:require-auth
   #:require-role
   #:router
   #:make-router
   #:add-route
   #:defroute
   #:dispatch-route
   #:router-handler
   #:push-event
   #:push-events
   #:push-component-patch
   ;; Components
   #:defcomponent
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
   ;; Cells
   #:cell
   #:make-cell
   #:cell-value
   #:cell-name
   #:watch
   #:unwatch
   #:connect
   #:disconnect
   #:computed-cell
   #:make-computed
   #:recompute
   #:propagator
   #:make-propagator
   #:fire-propagator
   #:remove-propagator
   ;; Render
   #:render-to-string
   #:render-page
   #:fluxion-script-tag
   #:csrf-meta-tag
   ;; Protocol
   #:format-sse-event
   #:write-sse-event
   ;; Validation
   #:validate
   #:valid-p
   #:field-error
   #:errors-alist
   #:validation-error-events
   #:clear-error-events))
