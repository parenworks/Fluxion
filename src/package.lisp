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
   #:clear-dirty
   ;; Lifecycle callbacks
   #:component-mounted
   #:component-unmounted
   #:component-connected
   ;; Composition
   #:component-parent
   #:component-children
   #:component-session
   #:add-child
   #:remove-child
   #:propagate-session
   #:component-root
   #:find-child))

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
   #:make-cell-watcher
   #:*cell-lock*
   #:with-cell-lock
   ;; Convergence safety
   #:propagation-limit-exceeded
   #:propagation-limit-rounds
   #:propagation-limit-remaining
   #:*max-propagation-rounds*
   #:rational-too-large-p))

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
   #:patch
   #:send-event
   #:*current-session*
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
   #:app-server
   #:app-session-lock
   #:app-sessions
   #:push-event
   #:push-events
   #:push-component-patch
   #:parse-request-body
   #:app-session-ttl
   #:app-reaper-interval
   #:reap-sessions
   #:touch-session
   #:session-expired-p
   #:close-event-queue
   #:ensure-event-queue
   #:session-event-queue
   #:eq-closed-p
   #:start-session-reaper
   #:stop-session-reaper
   #:app-request-log
   #:app-started-at
   #:app-uptime-seconds
   #:app-session-count
   #:app-sse-connection-count
   #:health-response
   #:log-request
   #:format-log-timestamp
   ;; Conditions
   #:fluxion-error
   #:fluxion-error-message
   #:session-not-found
   #:session-not-found-id
   #:csrf-validation-error
   #:action-dispatch-error
   #:action-dispatch-error-path
   #:action-dispatch-error-cause
   #:component-not-found
   #:component-not-found-id
   #:request-parse-error
   ;; Middleware
   #:add-middleware
   #:remove-middleware
   #:clear-middleware
   #:app-middleware
   #:wrap-handler
   #:make-request-logger
   #:make-rate-limiter
   #:make-cors-middleware))

(defpackage #:fluxion
  (:use #:cl)
  (:nicknames #:fx)
  (:import-from #:fluxion.components
   #:component #:component-id #:render #:handle-action #:defaction
   #:defcomponent #:patch-component #:mark-dirty #:clear-dirty
   #:component-selector
   #:component-mounted #:component-unmounted #:component-connected
   #:component-parent #:component-children #:component-session
   #:add-child #:remove-child #:component-root #:find-child)
  (:import-from #:fluxion.server
   #:fluxion-app #:make-fluxion-app
   #:register-component #:register-component-factory #:register-action
   #:start #:stop #:patch #:send-event
   #:session #:session-component #:session-csrf-token
   #:session-user #:session-user-roles
   #:authenticated-p #:authenticate #:logout #:has-role-p
   #:require-auth #:require-role
   #:router #:make-router #:add-route #:defroute #:dispatch-route
   #:router-handler
   #:push-event #:push-events #:push-component-patch
   #:find-component #:*current-session*
   #:app-handler #:app-sessions #:app-session-lock
   #:add-middleware #:remove-middleware #:clear-middleware
   #:make-request-logger #:make-rate-limiter #:make-cors-middleware)
  (:import-from #:fluxion.events
   #:make-patch-event #:make-remove-event #:make-append-event
   #:make-prepend-event #:make-signal-event #:make-script-event
   #:make-redirect-event)
  (:import-from #:fluxion.cells
   #:cell #:make-cell #:cell-value #:cell-name
   #:watch #:unwatch #:connect #:disconnect
   #:computed-cell #:make-computed #:recompute
   #:propagator #:make-propagator #:fire-propagator #:remove-propagator
   #:with-cell-lock #:with-transaction)
  (:import-from #:fluxion.render
   #:render-to-string #:render-page #:fluxion-script-tag #:csrf-meta-tag)
  (:import-from #:fluxion.protocol
   #:format-sse-event #:write-sse-event)
  (:import-from #:fluxion.validation
   #:validate #:valid-p #:field-error #:errors-alist
   #:validation-error-events #:clear-error-events)
  (:export
   ;; Components
   #:component #:component-id #:component-selector
   #:render #:handle-action #:defaction #:defcomponent
   #:patch-component #:mark-dirty #:clear-dirty
   #:component-mounted #:component-unmounted #:component-connected
   ;; Composition
   #:component-parent #:component-children #:component-session
   #:add-child #:remove-child #:component-root #:find-child
   ;; Server
   #:fluxion-app #:make-fluxion-app
   #:register-component #:register-component-factory #:register-action
   #:start #:stop #:patch #:send-event
   #:session #:session-component #:session-csrf-token
   #:session-user #:session-user-roles
   #:authenticated-p #:authenticate #:logout #:has-role-p
   #:require-auth #:require-role
   #:router #:make-router #:add-route #:defroute #:dispatch-route
   #:router-handler
   #:push-event #:push-events #:push-component-patch
   #:find-component #:*current-session*
   #:app-handler #:app-sessions #:app-session-lock
   ;; Middleware
   #:add-middleware #:remove-middleware #:clear-middleware
   #:make-request-logger #:make-rate-limiter #:make-cors-middleware
   ;; Events
   #:make-patch-event #:make-remove-event #:make-append-event
   #:make-prepend-event #:make-signal-event #:make-script-event
   #:make-redirect-event
   ;; Cells
   #:cell #:make-cell #:cell-value #:cell-name
   #:watch #:unwatch #:connect #:disconnect
   #:computed-cell #:make-computed #:recompute
   #:propagator #:make-propagator #:fire-propagator #:remove-propagator
   #:with-cell-lock #:with-transaction
   ;; Render
   #:render-to-string #:render-page #:fluxion-script-tag #:csrf-meta-tag
   ;; Protocol
   #:format-sse-event #:write-sse-event
   ;; Validation
   #:validate #:valid-p #:field-error #:errors-alist
   #:validation-error-events #:clear-error-events))
