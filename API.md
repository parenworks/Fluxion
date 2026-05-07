# Fluxion API Reference

Auto-generated from source docstrings.

---

## Components - CLOS component model, rendering, patching

Package: `fluxion.components`

### Class: `component`

Base class for all Fluxion components.

Slots:

- **`id`** - Unique identifier, used as the DOM element ID and CSS selector target.
- **`signals`** - Optional signal-store for this component's reactive state.
- **`dirty-p`** - Whether this component needs re-rendering.
- **`last-html`** - Cached HTML from the last render, used for dirty comparison.
- **`parent`** - Parent component, or NIL for top-level components.
- **`children`** - List of child components nested inside this component.
- **`session-ref`** - Back-pointer to the owning session. Set during session creation.

### Generic Functions

**`add-child (parent child)`** - Add CHILD as a nested child of PARENT.
Sets the child's parent back-pointer and propagates the session reference.
If CHILD was previously parented elsewhere, it is removed from the old parent first.

**`component-children (component)`** - List of child components nested inside this component.

**`component-connected (component session)`** - Called when the SSE stream is established for SESSION.
This fires each time the browser opens (or re-opens) the EventSource
connection. Override to push initial state or start session-specific
background work.
Default method does nothing.

**`component-dirty-p (component)`** - Whether this component needs re-rendering. Set by mark-dirty, cleared by patch-component.

**`component-id (component)`** - Unique identifier string, used as the DOM element ID and CSS selector target.

**`component-last-html (component)`** - Cached HTML from the last render. Used for dirty comparison to avoid sending no-op patches.

**`component-mounted (component session)`** - Called when COMPONENT is first created for a SESSION.
This happens during session creation when component factories run.
Override to perform per-session initialisation (start timers, open
resources, set initial state based on session context).
Default method does nothing.

**`component-parent (component)`** - The parent component, or NIL if this is a top-level component.

**`component-root (component)`** - Walk up the parent chain to find the root (top-level) component.

**`component-session (component)`** - Back-pointer to the session that owns this component. Set automatically during session creation.

**`component-signals (component)`** - Optional signal-store for this component's client-side reactive state.

**`component-unmounted (component session)`** - Called when SESSION is being reaped and COMPONENT will be discarded.
Override to perform cleanup (cancel timers, close connections, release
resources). Called inside the session lock during reaping.
Default method does nothing.

**`find-child (component id)`** - Find a descendant component by ID. Searches breadth-first.

**`handle-action (component action params)`** - Handle an incoming ACTION for COMPONENT.
ACTION is a keyword symbol identifying the action.
PARAMS is an alist of request parameters / signals.
Methods should mutate component state and return a list of SSE
events to send to the client, or use (patch component) as a
convenience.

**`patch-component (component &key mode force)`** - Return a list containing a single patch event for COMPONENT.
Re-renders the component and targets its DOM selector.
If the rendered HTML is identical to the cached version and FORCE
is NIL, returns an empty list (no patch sent).

**`remove-child (parent child)`** - Remove CHILD from PARENT's children list.
Clears the child's parent back-pointer.

**`render (component)`** - Render COMPONENT to an HTML string.  This is the primary method
application code must specialise.  Should return a string of HTML
with an element whose id matches (component-id component).

### Macros

**`defaction (component-class action-name (component-var &optional
                             (params-var (gensym params))) &body body)`** *(macro)* - Define an action handler for COMPONENT-CLASS.
ACTION-NAME is a keyword symbol (e.g. :increment).
COMPONENT-VAR is bound to the component instance.
PARAMS-VAR is bound to the request params alist.
BODY should mutate state and return a list of SSE events.
If BODY returns NIL, a default patch of the component is sent.

**`defcomponent (name &key id slots render)`** *(macro)* - Define a Fluxion component in a single form.

NAME is the class name.
ID is the component DOM id (string). Defaults to the downcased name.
SLOTS is a list of slot specs. Each spec is (slot-name &key cell initform accessor test).
  When :cell is T, the slot is backed by a reactive cell and automatically
  connected to the component. The accessor reads/writes through cell-value.
RENDER is a body form that returns an HTML string. Inside the body, SELF
  is bound to the component instance.

Example:
  (defcomponent counter
    :id "counter"
    :slots ((count :cell t :initform 0 :accessor counter-count))
    :render (spinneret:with-html-string
              (:div :id (component-id self)
                (:p (format nil "Count: ~D" (counter-count self))))))

### Functions

**`clear-dirty (component)`** - Clear the dirty flag on COMPONENT.

**`component-selector (component)`** - Return the CSS selector string that targets COMPONENT's root element.

**`mark-dirty (component)`** - Mark COMPONENT as needing re-rendering.

**`propagate-session (component session)`** - Set the session reference on COMPONENT and all its descendants.

---

## Cells / Lattice - reactive cells, computed cells, propagators, transactions

Package: `fluxion.cells`

### Class: `cell`

A reactive value container that notifies watchers on change.

Slots:

- **`value`** - The current value held by this cell.
- **`name`** - Optional name for debugging.
- **`watchers`** - List of functions called with (new-value old-value) on change.
- **`equalfn`** - Comparison function to detect value changes.
- **`height`** - Topological height. 0 for base cells, max(dep)+1 for derived.

### Class: `cell-watcher`

A watcher entry pairing a callback with an optional target cell for transaction ordering.

Slots:

- **`fn`**
- **`target`**

### Class: `computed-cell`

A cell whose value is derived from other cells.
The thunk is re-run whenever a dependency changes, and watchers on
this cell are notified if the computed value changes.

Slots:

- **`thunk`** - Zero-argument function that computes the value.
- **`dependencies`** - List of cells this computed depends on.
- **`update-fn`** - The watcher function installed on dependencies.

### Class: `propagation-limit-exceeded`

Slots:

- **`rounds`**
- **`remaining`**

### Class: `propagator`

A propagator connects input cells to output cells.
When any input cell changes, the function is applied to all input values
and the result(s) written to the output cell(s).

Slots:

- **`name`** - Optional name for debugging.
- **`inputs`** - List of input cells.
- **`outputs`** - List of output cells.
- **`fn`** - Function: receives input values as arguments, returns output value(s).
- **`installed-watchers`** - Watcher functions installed on input cells.
- **`active-p`** - Re-entrance guard. Prevents direct cycles.

### Generic Functions

**`cell-height (cell)`** - Topological height of the cell. 0 for base cells, max(dependency heights) + 1 for computed cells. Used for transaction ordering.

**`cell-name (cell)`** - Optional name (string or symbol) for debugging and print representation.

**`cell-test (cell)`** - Equality function used to detect value changes (default #'equal). The cell only notifies watchers when the new value differs by this test.

**`cell-watchers (cell)`** - List of watcher entries called with (new-value old-value) on change.

**`computed-dependencies (computed-cell)`** - List of cells this computed cell depends on. Automatically tracked and updated on each recomputation.

**`propagation-limit-remaining (condition)`**

**`propagation-limit-rounds (condition)`**

**`propagator-inputs (propagator)`** - List of input cells that trigger this propagator when changed.

**`propagator-name (propagator)`** - Optional name (string or symbol) for debugging and print representation.

**`propagator-outputs (propagator)`** - List of output cells written by this propagator when it fires.

### Macros

**`with-cell-lock (&body body)`** *(macro)* - Execute BODY while holding the cell graph lock.

**`with-transaction (&body body)`** *(macro)* - Execute BODY within a transaction. All cell notifications are deferred
and flushed in topological (height) order at the end, preventing glitches.
Transactions nest: only the outermost transaction flushes.
Thread-safe: the outermost transaction holds the cell graph lock.

### Functions

**`cell-value (cell)`** - Read the current value of CELL.
When called inside a computed cell's thunk, records the read for dependency tracking.
Thread-safe: acquires the cell graph lock.

**`collect-event (event)`** - Append EVENT to *pending-events* if we are inside an action dispatch.

**`collect-events (events)`** - Append a list of EVENTS to *pending-events*.

**`connect (cell component &key (mode morph))`** - Connect CELL to COMPONENT so that changes auto-patch.
When CELL's value changes, COMPONENT is re-rendered and a patch event
is collected into *pending-events* (if bound).
Returns the watcher entry (useful for later disconnection).

**`disconnect (cell watcher)`** - Remove a previously connected watcher from CELL.

**`drain-pending-events ()`** - Return and clear all pending events collected during this action.
Returns them in the order they were collected.

**`fire-propagator (propagator)`** - Run the propagator: read inputs, apply function, write outputs.
Returns immediately if this propagator is already firing (re-entrance guard).
Wraps output writes in a transaction to prevent glitches.

**`make-cell (value &key name (test #'equal))`** - Create a new cell with initial VALUE.

**`make-cell-watcher (&key ((fn fn) nil) ((target target) nil))`**

**`make-computed (thunk &key name (test #'equal))`** - Create a computed cell. THUNK is a zero-argument function that reads
other cells to produce a value. Dependencies are tracked automatically.

**`make-propagator (&key inputs fn outputs name)`** - Create and activate a propagator.
FN receives the current values of INPUTS as arguments.
For a single output, FN returns one value.
For multiple outputs, FN returns a list of values.

**`rational-too-large-p (value &optional (limit (expt 2 128)))`** - Return T if VALUE is a rational whose numerator or denominator
exceeds LIMIT (default 2^128).  Useful for detecting runaway growth
in propagator cycles that converge to irrational fixed points.

**`recompute (computed)`** - Recalculate COMPUTED's value by running its thunk.
Discovers dependencies via *tracking-reads* and rewires watchers.
Updates height to max(dep heights) + 1 for topological ordering.

**`remove-propagator (propagator)`** - Remove the propagator's watchers from its input cells.

**`unwatch (cell entry)`** - Remove a watcher ENTRY from CELL's watchers.
ENTRY may be a cell-watcher struct or the original function.
Thread-safe: acquires the cell graph lock.

**`watch (cell fn &key target)`** - Register FN as a watcher on CELL.
FN is called with (new-value old-value) whenever the cell changes.
TARGET optionally references the downstream cell (for transaction scheduling).
Thread-safe: acquires the cell graph lock.
Returns the watcher entry.

### Variables

**`*cell-lock*`** *(variable)* - Global recursive lock protecting the cell graph.

**`*max-propagation-rounds*`** *(variable)* - Maximum number of flush iterations per transaction before signalling
PROPAGATION-LIMIT-EXCEEDED.  Set to NIL to disable the cap (not recommended).

**`*pending-events*`** *(variable)* - When bound to a list, cell-triggered watchers append SSE events here.
Bound by the action dispatch machinery so that cell changes during an
action automatically produce patch events in the response.

---

## Server - application, sessions, routing, auth, SSE push, conditions

Package: `fluxion.server`

### Class: `action-dispatch-error`

Signalled when an action handler fails.

Slots:

- **`path`**
- **`cause`**

### Class: `component-not-found`

Signalled when a component ID cannot be resolved.

Slots:

- **`component-id`**

### Class: `csrf-validation-error`

Signalled when a CSRF token is missing or invalid.

### Class: `fluxion-app`

Top-level Fluxion application.

Slots:

- **`components`** - Registry of global component instances, keyed by component-id.
- **`component-factories`** - Factory functions keyed by component-id. Called to create per-session instances.
- **`actions`** - Registry of action handlers, keyed by URL path string.
- **`sessions`** - Session store, keyed by session-id string.
- **`session-lock`**
- **`session-ttl`** - Session time-to-live in seconds. Default 1 hour.
- **`reaper-thread`** - Background thread that periodically removes expired sessions.
- **`reaper-stop-flag`** - When T, the reaper thread exits on its next cycle.
- **`reaper-interval`** - Seconds between session reaper runs. Default 60.
- **`static-dir`** - Directory path for serving static files (fluxion.js, etc).
- **`handler`** - The running Clack handler (used for stopping).
- **`port`**
- **`server`** - Clack server backend. :woo (default) or :hunchentoot.
- **`started-at`** - Universal time when the server was started.
- **`request-log`** - When non-nil, log every request to *standard-output*.
- **`middleware`** - List of middleware-entry structs applied at start time.
- **`session-store`** - Pluggable session store for persistence. Default is in-memory only.

### Class: `fluxion-error`

Base condition for all Fluxion framework errors.

Slots:

- **`message`**

### Class: `memory-session-store`

No-op session store. Sessions live only in memory.
This is the default and preserves existing behaviour.

### Class: `request-parse-error`

Signalled when a request body cannot be parsed.

Slots:

- **`body`**

### Class: `router`

Path-based request router.

Slots:

- **`routes`** - List of route objects in registration order.
- **`not-found-handler`** - Optional handler for 404. Signature: (app session env).

### Class: `session`

A per-browser session holding its own component instances.

Slots:

- **`id`**
- **`components`** - Component instances for this session, keyed by component-id.
- **`created-at`**
- **`last-accessed-at`** - Universal time of last request using this session.
- **`event-queue`** - Event queue for persistent SSE push. Created on first /sse connect.
- **`csrf-token`** - Random token for CSRF protection. Validated on every POST.
- **`user`** - Application-defined user data. NIL when not authenticated.
- **`user-roles`** - List of role keywords for the authenticated user, e.g. (:admin :editor).

### Class: `session-not-found`

Signalled when a session ID cannot be resolved.

Slots:

- **`session-id`**

### Generic Functions

**`action-dispatch-error-cause (condition)`** - The underlying error that caused the action dispatch failure.

**`action-dispatch-error-path (condition)`** - The URL path of the action that failed.

**`add-middleware (app middleware &key name)`** - Add MIDDLEWARE to APP's middleware chain.
MIDDLEWARE is a function of (handler) that returns a new handler.
NAME is an optional keyword for identification and removal.
Middleware is applied in registration order (first = outermost).

**`app-component-factories (object)`**

**`app-handler (app)`** - The running Clack handler reference (used for stopping the server).

**`app-middleware (object)`**

**`app-reaper-interval (app)`** - Seconds between session reaper runs.

**`app-request-log (app)`** - When non-nil, every request is logged to *standard-output*.

**`app-server (app)`** - Clack server backend keyword (:woo or :hunchentoot).

**`app-session-lock (app)`** - Lock protecting concurrent access to the session store.

**`app-session-store (object)`**

**`app-session-ttl (app)`** - Session time-to-live in seconds before idle expiry.

**`app-sessions (app)`** - Hash table of active sessions keyed by session-id string.

**`app-started-at (app)`** - Universal time when the server was started.

**`clear-middleware (app)`** - Remove all middleware from APP.

**`component-not-found-id (condition)`** - The component-id string that could not be resolved.

**`delete-session (store session-id)`** - Remove a session from the backing store.
Called when a session is reaped or explicitly invalidated.

**`eq-closed-p (queue)`** - Whether the event queue has been closed.

**`find-component (app id &key session)`** - Find a component by ID. Checks session first, then global registry.

**`fluxion-error-message (condition)`** - Human-readable error message for the condition.

**`gc-sessions (store ttl)`** - Remove sessions from the backing store that have not been accessed
within TTL seconds. Returns the number of sessions removed.

**`load-all-sessions (store)`** - Load all sessions from the backing store.
Used on server restart to restore active sessions.
Returns a list of SESSION instances.

**`load-session (store session-id)`** - Load a session by ID from the backing store.
Returns a SESSION instance or NIL if not found.
Components and event queues are not restored (they are runtime-only).

**`parse-request-body (env)`** - Parse the request body from a Clack ENV as a JSON alist.
Returns NIL if no body or parse failure.
Override or wrap with :around methods for custom content types.

**`push-component-patch (session component &key mode)`** - Re-render COMPONENT and push a patch event to SESSION's SSE stream.

**`register-action (app path handler-fn)`** - Register an action handler function for PATH.
HANDLER-FN is a function of (app env) that should return a list
of SSE events to send, or write directly to an event stream.

**`register-component (app component)`** - Register a global (shared) COMPONENT instance in APP.

**`register-component-factory (app id factory-fn)`** - Register a factory function for per-session component creation.
ID is the component-id string. FACTORY-FN is a function of zero arguments
that returns a fresh component instance.

**`remove-middleware (app name)`** - Remove middleware identified by NAME from APP.

**`session-component (session id)`** - Find a component by ID within a SESSION.

**`session-components (session)`** - Hash table of component instances for this session, keyed by component-id.

**`session-created-at (object)`**

**`session-csrf-token (session)`** - The session's CSRF token string. Validated on every POST request.

**`session-event-queue (session)`** - The SSE event queue for this session. Created on first /sse connection.

**`session-id (session)`** - Unique session identifier string (used as the cookie value).

**`session-last-accessed-at (object)`**

**`session-not-found-id (condition)`** - The session-id string that could not be resolved.

**`session-user (session)`** - Application-defined user data. NIL when not authenticated.

**`session-user-roles (session)`** - List of role keywords for the authenticated user, e.g. (:admin :editor).

**`start (app page-handler &key)`** - Start the Fluxion application server.

**`stop (app)`** - Stop the Fluxion application server.

**`store-session (store session)`** - Persist SESSION to the backing store. Called on session creation
and periodically on mutation (touch, auth changes).

**`store-setup (store)`** - One-time initialization for the store (create tables, etc.).
Idempotent: safe to call multiple times.

### Macros

**`defroute (router-var method pattern args &body body)`** *(macro)* - Define a route on ROUTER-VAR.
METHOD is :get, :post, or :any.
PATTERN is a URL path like "/users/:id".
ARGS is a lambda list (app session env &key params).

Example:
  (defroute *router* :get "/" (app session env &key params)
    (list 200 '(:content-type "text/html") (list "Hello")))

  (defroute *router* :get "/users/:id" (app session env &key params)
    (let ((user-id (cdr (assoc :id params))))
      ...))

### Functions

**`add-route (router method pattern handler &key guard name)`** - Add a route to the router. METHOD is :get, :post, or :any.
PATTERN is a URL path like "/users/:id".
HANDLER is (app session env &key params) -> response.
GUARD is an optional (session) -> response-or-nil.

**`app-session-count (app)`** - Return the current number of active sessions.

**`app-sse-connection-count (app)`** - Return the number of sessions with active (not closed) event queues.

**`app-uptime-seconds (app)`** - Return seconds since the app was started, or 0 if not started.

**`authenticate (session user &key roles)`** - Set the authenticated user on SESSION.
USER can be any application-defined value (string, plist, CLOS object, etc.).
ROLES is an optional list of role keywords.
Regenerates the CSRF token to prevent session fixation.

**`authenticated-p (session)`** - Return T if SESSION has an authenticated user.

**`close-event-queue (queue)`** - Mark QUEUE as closed and wake any waiting reader.

**`dispatch-route (router app session env)`** - Find and dispatch the first matching route. Returns a Clack response.
If no route matches, calls the not-found-handler or returns 404.

**`ensure-event-queue (session)`** - Return the session's event queue, creating it if needed.
Closes any existing queue first so that the previous SSE loop
terminates cleanly and does not steal events from the new connection.

**`format-log-timestamp ()`** - Return a timestamp string for log output.

**`has-role-p (session role)`** - Return T if SESSION's user has ROLE in their roles list.

**`health-response (app)`** - Return a JSON health check response.

**`log-request (method path status elapsed-ms)`** - Log a request in structured format.

**`logout (session)`** - Clear the authenticated user from SESSION.
Regenerates the CSRF token.

**`make-cors-middleware (&key (allowed-origins '(*)) (allowed-methods '(get post options)) (allowed-headers
                                                                   '(content-type
                                                                     x-csrf-token)) (max-age
                                                                                     86400))`** - Return a middleware that adds CORS headers to responses.
ALLOWED-ORIGINS: list of origin strings, or '("*") for any origin.
ALLOWED-METHODS: list of HTTP method strings.
ALLOWED-HEADERS: list of header name strings.
MAX-AGE: preflight cache duration in seconds (default 86400).

**`make-fluxion-app (&key (port 5000) static-dir (session-ttl 3600) (reaper-interval 60) (server woo) (request-log
                                                                                  t))`** - Create a new Fluxion application instance.
SERVER is the Clack backend: :woo (default) or :hunchentoot.
Woo uses libev for async I/O. Install libev-dev to use it.
REQUEST-LOG: when non-nil (default T), logs every request.
Middleware is added after creation via ADD-MIDDLEWARE.

**`make-rate-limiter (&key (requests-per-second 10) (burst 20) (key-fn nil))`** - Return a middleware that rate-limits requests using a token bucket.
REQUESTS-PER-SECOND: refill rate.
BURST: maximum tokens (allows short bursts above the steady rate).
KEY-FN: function of (env) returning a string key for per-client limiting.
         Default NIL means global (all clients share one bucket).

**`make-request-logger (&key (stream *standard-output*) (skip-health nil))`** - Return a middleware that logs each request.
STREAM: output stream (default *standard-output*).
SKIP-HEALTH: when T, omit GET /health from the log.

**`make-router (&key not-found-handler)`** - Create a new router instance.

**`patch (stream component &key (mode morph))`** - Convenience: render COMPONENT and write a patch event to STREAM.

**`push-event (session event)`** - Push an SSE event to a session's persistent SSE connection.
The event will be delivered to the browser via the EventSource stream.

**`push-events (session events)`** - Push multiple SSE events to a session's persistent connection.

**`reap-sessions (app)`** - Remove expired sessions from APP. Closes event queues so SSE
threads unblock and terminate cleanly. Returns the number reaped.

**`require-auth (session &key (login-url /login))`** - If SESSION is not authenticated, return a redirect response to LOGIN-URL.
Returns NIL if the user is authenticated (meaning: proceed normally).
Use in page handlers as a guard:
  (or (require-auth session) (render-protected-page ...))

**`require-role (session role &key (login-url /login) (forbidden-url nil))`** - If SESSION's user lacks ROLE, return a redirect or 403 response.
Returns NIL if the user has the role (meaning: proceed normally).
If the user is not authenticated at all, redirects to LOGIN-URL.
If authenticated but lacking the role, returns 403 (or redirects to FORBIDDEN-URL).

**`router-handler (router)`** - Return a page-handler function suitable for passing to start.
This bridges the router into the existing Fluxion server.

**`send-event (stream event)`** - Write a single SSE-EVENT to STREAM.

**`session-expired-p (session ttl)`** - Return T if SESSION has not been accessed within TTL seconds.

**`start-session-reaper (app)`** - Start the background session reaper thread for APP.

**`stop-session-reaper (app)`** - Stop the background session reaper thread gracefully.
Sets the stop flag, interrupts the sleeping thread, and waits briefly.

**`touch-session (session)`** - Update the last-accessed-at timestamp on SESSION.

**`wrap-handler (handler app)`** - Compose all registered middleware around HANDLER.
Middleware is applied in registration order: first registered = outermost.

### Variables

**`*current-session*`** *(variable)* - The session for the current request. Bound during request dispatch.

---

## Events - SSE event constructors

Package: `fluxion.events`

### Functions

**`make-append-event (selector fragment &key id)`** - Create an append-elements event.
Appends FRAGMENT as a child of the element matching SELECTOR.

**`make-patch-event (selector fragment &key (mode morph) id)`** - Create a patch-elements event.
SELECTOR is a CSS selector string.
FRAGMENT is the HTML string to patch into the DOM.
MODE is one of "morph", "replace", "inner" (default: "morph").

**`make-prepend-event (selector fragment &key id)`** - Create a prepend-elements event.
Prepends FRAGMENT as a child of the element matching SELECTOR.

**`make-redirect-event (url &key id)`** - Create a redirect event.
URL is the location to navigate to.

**`make-remove-event (selector &key id)`** - Create a remove-elements event.
SELECTOR is a CSS selector for the element(s) to remove.

**`make-script-event (script &key id)`** - Create an execute-script event.
SCRIPT is a JavaScript string to evaluate on the client.

**`make-signal-event (signals &key id)`** - Create a patch-signals event.
SIGNALS is an alist of signal-name / value pairs to update on the client.

---

## Protocol - low-level SSE formatting

Package: `fluxion.protocol`

### Class: `sse-event`

Slots:

- **`event-type`** - The SSE event type field.
- **`event-data`** - The event payload, will be JSON-encoded.
- **`event-id`** - Optional SSE event ID.
- **`event-retry`** - Optional SSE retry interval in milliseconds.

### Generic Functions

**`event-data (event)`** - The event payload (alist), JSON-encoded when formatted.

**`event-id (event)`** - Optional SSE event ID. The browser uses this for reconnection (Last-Event-ID).

**`event-retry (event)`** - Optional SSE retry interval in milliseconds. Tells the browser how long to wait before reconnecting.

**`event-type (event)`** - The SSE event type field (e.g. "fluxion-patch", "fluxion-script").

### Functions

**`format-sse-event (event)`** - Format an SSE-EVENT as a string suitable for text/event-stream output.

**`write-sse-event (event stream)`** - Write an SSE-EVENT to STREAM in text/event-stream format.

### Variables

**`+append-elements+`** *(variable)* - SSE event type string for appending child elements.

**`+execute-script+`** *(variable)* - SSE event type string for executing JavaScript on the client.

**`+patch-elements+`** *(variable)* - SSE event type string for DOM patch operations.

**`+patch-signals+`** *(variable)* - SSE event type string for updating client-side signals.

**`+prepend-elements+`** *(variable)* - SSE event type string for prepending child elements.

**`+redirect+`** *(variable)* - SSE event type string for browser navigation.

**`+remove-elements+`** *(variable)* - SSE event type string for DOM element removal.

---

## Render - HTML page rendering helpers

Package: `fluxion.render`

### Functions

**`csrf-meta-tag (token)`** - Return an HTML meta tag containing the CSRF token.
The client runtime reads this and includes it in every POST request.

**`fluxion-script-tag (&key (path /static/fluxion.js))`** - Return an HTML <script> tag that loads the Fluxion client runtime.

**`render-page (&key title body-html head-html csrf-token (script-path /static/fluxion.js))`** - Render a full HTML page shell with the Fluxion client runtime included.
TITLE is the page title.
BODY-HTML is a string of HTML to place in the <body>.
HEAD-HTML is optional extra HTML for the <head>.
CSRF-TOKEN is the session's CSRF token (included as a meta tag).
SCRIPT-PATH is the URL path to fluxion.js.

**`render-to-string (component)`** - Call the RENDER generic function on COMPONENT and return the HTML string.

---

## Validation - server-side form validation

Package: `fluxion.validation`

### Class: `validation-result`

Container for validation errors from a set of rules.

Slots:

- **`errors`** - Hash table mapping field name strings to error message strings.

### Functions

**`add-error (result field message)`** - Add an error MESSAGE for FIELD to RESULT. Only the first error per field is kept.

**`clear-error-events (fields &key (selector-fn nil))`** - Generate SSE patch events to clear error messages for FIELDS.
FIELDS is a list of field name strings.
SELECTOR-FN works the same as in VALIDATION-ERROR-EVENTS.

**`confirmed (params confirm-field &optional message)`** - Validator: value must match the value of CONFIRM-FIELD in PARAMS.
Useful for password confirmation.

**`email (&optional message)`** - Validator: value must look like an email address.

**`errors-alist (result)`** - Return the errors as an alist of (field . message) pairs.

**`errors-plist (result)`** - Return the errors as a plist (:field message ...).

**`field-error (result field)`** - Return the error message for FIELD, or NIL if the field is valid.

**`integer-string (&optional message)`** - Validator: value must be a string that parses as an integer.

**`make-validation-result ()`** - Create an empty validation result.

**`matches-pattern (regex &optional message)`** - Validator: string must match REGEX (a CL-PPCRE pattern).
Returns the error message if the value does not match.

**`max-length (n &optional message)`** - Validator: string must be at most N characters.

**`min-length (n &optional message)`** - Validator: string must be at least N characters.

**`number-string (&optional message)`** - Validator: value must be a string that parses as a number.

**`one-of (choices &optional message)`** - Validator: value must be one of CHOICES (list of strings).

**`predicate (fn &optional message)`** - Validator: custom predicate. FN takes a value and returns T if valid.

**`required (&optional message)`** - Validator: field must be present and non-empty.

**`valid-p (result)`** - Return T if RESULT has no validation errors.

**`validate (params rules)`** - Validate PARAMS (an alist) against RULES.
RULES is a list of (field-name validator1 validator2 ...) lists.
FIELD-NAME is a string matching a key in PARAMS.
Each validator is a function returned by required, min-length, etc.

Returns a VALIDATION-RESULT. Use VALID-P to check if validation passed.

Example:
  (validate params
    (list (list "username" (required) (min-length 3))
          (list "email"    (required) (email))))

**`validation-error-events (result &key (selector-fn nil) (class field-error))`** - Generate SSE patch events to display validation errors in the DOM.
For each field with an error, patches an element with the error message.

SELECTOR-FN is an optional function (field-name) -> CSS selector.
Defaults to "#error-{field-name}".

CLASS is the CSS class added to the error element (default: "field-error").

Returns a list of SSE events suitable for returning from an action handler.

---

## Client - Parenscript runtime compilation

Package: `fluxion.client`

### Functions

**`build-client (&key (output-path (system-relative-pathname fluxion static/fluxion.js)))`** - Compile the Fluxion Parenscript runtime and write it to OUTPUT-PATH.

**`client-js-string ()`** - Return the Fluxion browser runtime as a JavaScript string.

---

## Umbrella Package (fluxion / fx) - re-exports key symbols

Package: `fluxion`

This package re-exports symbols from other Fluxion packages for convenience. All symbols below are documented in full under their home package.

### From `fluxion.cells`

- `cell`
- `cell-name`
- `cell-value`
- `computed-cell`
- `connect`
- `disconnect`
- `fire-propagator`
- `make-cell`
- `make-computed`
- `make-propagator`
- `propagator`
- `recompute`
- `remove-propagator`
- `unwatch`
- `watch`
- `with-cell-lock`
- `with-transaction`

### From `fluxion.components`

- `add-child`
- `clear-dirty`
- `component`
- `component-children`
- `component-connected`
- `component-id`
- `component-mounted`
- `component-parent`
- `component-root`
- `component-selector`
- `component-session`
- `component-unmounted`
- `defaction`
- `defcomponent`
- `find-child`
- `handle-action`
- `mark-dirty`
- `patch-component`
- `remove-child`
- `render`

### From `fluxion.events`

- `make-append-event`
- `make-patch-event`
- `make-prepend-event`
- `make-redirect-event`
- `make-remove-event`
- `make-script-event`
- `make-signal-event`

### From `fluxion.protocol`

- `format-sse-event`
- `write-sse-event`

### From `fluxion.render`

- `csrf-meta-tag`
- `fluxion-script-tag`
- `render-page`
- `render-to-string`

### From `fluxion.server`

- `*current-session*`
- `add-middleware`
- `add-route`
- `app-handler`
- `app-session-lock`
- `app-sessions`
- `authenticate`
- `authenticated-p`
- `clear-middleware`
- `defroute`
- `dispatch-route`
- `find-component`
- `fluxion-app`
- `has-role-p`
- `logout`
- `make-cors-middleware`
- `make-fluxion-app`
- `make-rate-limiter`
- `make-request-logger`
- `make-router`
- `patch`
- `push-component-patch`
- `push-event`
- `push-events`
- `register-action`
- `register-component`
- `register-component-factory`
- `remove-middleware`
- `require-auth`
- `require-role`
- `router`
- `router-handler`
- `send-event`
- `session`
- `session-component`
- `session-csrf-token`
- `session-user`
- `session-user-roles`
- `start`
- `stop`

### From `fluxion.validation`

- `clear-error-events`
- `errors-alist`
- `field-error`
- `valid-p`
- `validate`
- `validation-error-events`

---

## Database - backend protocol, connection management, collection CRUD, query DSL

Package: `fluxion.db`

### Class: `backend`

Abstract base class for database backends.
Every backend (SQLite, PostgreSQL, etc.) subclasses this and implements
the required generic functions.

### Class: `collection-already-exists`

### Class: `collection-error`

Slots:

- **`name`**

### Class: `connection-already-open`

### Class: `connection-failed`

### Class: `database-error`

Slots:

- **`message`**

### Class: `invalid-collection`

### Class: `invalid-field`

Slots:

- **`name`**

### Generic Functions

**`%alter (backend name structure)`** - Alter collection NAME to match STRUCTURE.
Adds missing columns. Does not remove or rename existing columns.

**`%collection-exists-p (backend name)`** - Return T if collection NAME exists.

**`%collection-structure (backend name)`** - Return the structure of collection NAME as a list
of (field-name field-type) pairs.

**`%collections (backend)`** - Return a list of collection name strings.

**`%count (backend collection query)`** - Count records in COLLECTION matching QUERY.

**`%create (backend name structure &key if-exists)`** - Create a collection NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs.
IF-EXISTS is :error (default) or :ignore.

**`%drop (backend name)`** - Drop (delete) collection NAME.

**`%empty (backend name)`** - Remove all records from collection NAME.

**`%execute-transaction (backend thunk)`** - Execute THUNK within a database transaction.
Commits on normal return, rolls back on error.

**`%insert (backend collection data)`** - Insert DATA (an alist of field-value pairs) into COLLECTION.
Returns the new record's ID.

**`%iterate (backend collection query function &key fields skip amount sort unique)`** - Call FUNCTION once per record from COLLECTION matching QUERY.
FUNCTION receives an alist for each record.

**`%remove (backend collection query &key skip amount sort)`** - Remove records from COLLECTION matching QUERY.

**`%select (backend collection query &key fields skip amount sort unique)`** - Select records from COLLECTION matching QUERY.
Returns a list of alists. Each alist has string keys.
FIELDS: list of field names to return, or NIL for all.
SKIP: number of records to skip.
AMOUNT: max records to return.
SORT: list of (field . :asc/:desc) pairs.
UNIQUE: if T, return only distinct records.

**`%update (backend collection query data &key skip amount sort)`** - Update records in COLLECTION matching QUERY with DATA.
DATA is an alist of field-value pairs to set.

**`collection-error-name (condition)`**

**`connect (backend &key)`** - Open a database connection using BACKEND.
Sets *backend* to the connected backend instance. Returns the backend.
Keyword arguments are backend-specific (e.g. :database, :host, :port).

**`connected-p (backend)`** - Return T if BACKEND has an active connection.

**`database-error-message (condition)`**

**`disconnect (backend)`** - Close the database connection for BACKEND.
Clears *backend* if it points to this backend.

**`invalid-field-name (condition)`**

### Macros

**`query (expr)`** *(macro)* - Compile a query DSL expression into (sql-string . parameter-list).
Field names (second element in comparisons) are always treated as symbols.
Value positions are evaluated at runtime, so variables work.

Usage:
  (db:query :all)
  (db:query (:= name "Alice"))
  (db:query (:= _id some-variable))
  (db:query (:and (:= role "admin") (:> age 21)))

**`with-connection ((backend &rest connect-args) &body body)`** *(macro)* - Execute BODY with BACKEND connected. Disconnects on exit.

**`with-transaction (nil &body body)`** *(macro)* - Execute BODY within a database transaction.
Commits on normal return, rolls back on error.

### Functions

**`alter (name structure)`** - Alter collection NAME to match STRUCTURE.
Adds missing columns. Does not remove existing columns.

**`collection-exists-p (name)`** - Return T if collection NAME exists.

**`collection-structure (name)`** - Return the structure of collection NAME as a list of (field-name field-type) pairs.

**`collections ()`** - Return a list of collection name strings.

**`compile-query (expr)`** - Compile a query expression at runtime.
Same as the query macro but accepts a runtime value.

**`count (collection query)`** - Count records in COLLECTION matching QUERY.
Example: (db:count "users" (db:query :all))

**`create (name structure &key (if-exists error))`** - Create a collection NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs, e.g.:
  ((title :text) (count :integer) (active :boolean))
An _id :integer primary key is added automatically.
IF-EXISTS may be :error (default) or :ignore.

**`current-backend ()`** - Return the currently active database backend, signalling an error if none.

**`drop (name)`** - Drop (delete) collection NAME and all its data.

**`empty (name)`** - Remove all records from collection NAME.

**`ensure-id (value)`** - Coerce VALUE to a database ID (positive integer).
Accepts integers and strings containing integers.

**`insert (collection data)`** - Insert DATA (an alist) into COLLECTION. Returns the new record's ID.
Example: (db:insert "users" '(("name" . "Alice") ("role" . "admin")))

**`iterate (collection query function &key fields skip amount sort unique)`** - Call FUNCTION once per matching record (as alist) from COLLECTION.
Example: (db:iterate "users" (db:query :all) #'print)

**`remove (collection query &key skip amount sort)`** - Remove records from COLLECTION matching QUERY.
Example: (db:remove "users" (db:query (:= name "test")))

**`select (collection query &key fields skip amount sort unique)`** - Select records from COLLECTION matching QUERY.
Returns a list of alists.
Example: (db:select "users" (db:query (:= name "Alice")))

**`select-one (collection query &key fields)`** - Select a single record from COLLECTION matching QUERY, or NIL.

**`update (collection query data &key skip amount sort)`** - Update records in COLLECTION matching QUERY with DATA (alist).
Example: (db:update "users" (db:query (:= _id 1)) '(("role" . "admin")))

### Variables

**`*backend*`** *(variable)* - The currently active database backend instance.

### Other

**`backend-connected-p`**

**`backend-name`**

**`field-type`**

**`id`**

---

## Query DSL - s-expression query compiler, SQL generation helpers

Package: `fluxion.db.query`

### Macros

**`query (expr)`** *(macro)* - Compile a query DSL expression at macro-expansion time when possible.
Returns a (sql-string . parameter-list) cons at runtime.

Usage:
  (db:query :all)
  (db:query (:= 'name "Alice"))
  (db:query (:and (:= 'role "admin") (:> 'age 21)))

### Functions

**`compile-alter-table (name new-columns)`** - Generate ALTER TABLE statements to add NEW-COLUMNS to NAME.
Returns a list of SQL strings.

**`compile-create-table (name structure)`** - Generate a CREATE TABLE SQL string for NAME with STRUCTURE.
STRUCTURE is a list of (field-name field-type) pairs.
An _id INTEGER PRIMARY KEY AUTOINCREMENT column is prepended.
Returns the SQL string (no parameters needed).

**`compile-delete (table query-compiled)`** - Generate a DELETE statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
Returns (sql-string . parameter-list).

**`compile-fields (fields)`** - Compile a field list to a SQL column list string.
NIL means all columns (*).

**`compile-insert (table data)`** - Generate an INSERT statement for TABLE with DATA (alist).
Returns (sql-string . parameter-list).

**`compile-query (expr)`** - Compile a query expression into (sql-string . reversed-parameter-list).
Example:
  (compile-query '(:and (:= name "Alice") (:> age 21)))
  => ("(\"name\" = ? AND \"age\" > ?)" "Alice" 21)

**`compile-select (table query-compiled &key fields sort skip amount unique)`** - Generate a SELECT statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
Returns (sql-string . parameter-list).

**`compile-sort (sort)`** - Compile a sort specification to a SQL ORDER BY clause.
SORT is a list of (field . :asc/:desc) pairs.
Returns a string like: ORDER BY "name" ASC, "age" DESC
or NIL if sort is empty.

**`compile-update (table query-compiled data)`** - Generate an UPDATE statement for TABLE.
QUERY-COMPILED is (where-sql . params) from compile-query.
DATA is an alist of fields to set.
Returns (sql-string . parameter-list).

**`field-name-sql (field)`** - Convert a field name (symbol or string) to a SQL column name string.
Symbols are lowercased and hyphens become underscores.

**`field-type-sql (type)`** - Convert a portable field type keyword to SQL type string.

**`quote-identifier (name)`** - Quote a SQL identifier (table or column name) with double quotes.
Handles qualified names like users._id by quoting each part separately.

---

## Data Model - record objects with field access, model-level CRUD

Package: `fluxion.db.model`

### Class: `data-model`

A database record as a first-class object.
Provides field-level access without SQL.

Slots:

- **`collection`** - The collection (table) this model belongs to.
- **`id`** - The record's database ID, or NIL if not yet persisted.
- **`fields`** - Hash table of field-name -> value.

### Generic Functions

**`model-collection (object)`**

**`model-field-table (object)`**

**`model-id (object)`**

### Functions

**`alist-to-model (collection alist)`** - Create a data model for COLLECTION from ALIST.
If ALIST contains an "_id" key, it is set as the model ID.

**`delete-model (model)`** - Delete MODEL from the database.

**`get-all (collection query &key fields skip amount sort unique)`** - Select records from COLLECTION matching QUERY, returning data models.

**`get-one (collection query &key fields)`** - Select a single record from COLLECTION matching QUERY, returning a data model or NIL.

**`hull (collection)`** - Create an empty, unsaved data model for COLLECTION.
This is a blank record ready to have fields set on it.

**`hull-p (model)`** - Return T if MODEL is an empty hull (no ID and no fields set).

**`insert-model (model)`** - Insert MODEL into the database. Sets MODEL's ID from the returned value.
Returns MODEL.

**`model-field (model field)`** - Get the value of FIELD (string) from MODEL.

**`model-fields (model)`** - Return a list of field name strings for MODEL.

**`model-new-p (model)`** - Return T if MODEL has not yet been persisted (no ID).

**`model-to-alist (model)`** - Convert MODEL's fields to an alist of (field-name . value) pairs.
Includes _id if set.

**`save (model)`** - Save MODEL to the database.
If the model is new (no ID), inserts it.
If the model has an ID, updates the existing record.

---

## Relational Extension - joins between collections, raw SQL queries

Package: `fluxion.rdb`

### Generic Functions

**`%join (backend type left-collection right-collection &key on query fields sort skip amount)`** - Execute a JOIN between LEFT-COLLECTION and RIGHT-COLLECTION.
TYPE is one of :inner, :left, :right, or :cross.
ON is a join condition as a query DSL expression using qualified field names.
QUERY is an optional WHERE filter (compiled query cons).
FIELDS is an optional list of qualified field names to return.
SORT, SKIP, AMOUNT work as in db:select.
Returns a list of alists.

**`%sql-execute (backend sql params)`** - Execute raw SQL that does not return rows (INSERT, UPDATE, DELETE, DDL).
PARAMS is a list of parameter values for ? placeholders.
Returns the backend-specific result (typically row count or NIL).

**`%sql-query (backend sql params)`** - Execute raw SQL that returns rows. PARAMS is a list of parameter values
for ? placeholders. Returns a list of alists with string keys.

### Macros

**`join (type left-collection right-collection &key on query fields sort skip amount)`** *(macro)* - Execute a JOIN between two collections and return matching records.
TYPE is :inner, :left, :right, or :cross.
ON is the join condition as a query DSL expression with qualified field names.
QUERY is an optional WHERE filter (from db:query).
FIELDS is an optional list of qualified field symbols to select.
SORT, SKIP, AMOUNT control ordering and pagination.

Example:
  (rdb:join :inner "users" "orders"
    :on (:= users._id orders.user_id)
    :query (db:query (:> orders.total 100))
    :fields '(users.name orders.total)
    :sort '((orders.total . :desc)))

### Functions

**`sql (sql &rest params)`** - Execute raw SQL that returns rows. Use ? placeholders for parameters.
Returns a list of alists with string keys.

This is an escape hatch for queries that the DSL cannot express.
Prefer the structured API (db:select, rdb:join) when possible.

Example:
  (rdb:sql "SELECT u.name, COUNT(o._id) AS order_count
             FROM users u JOIN orders o ON u._id = o.user_id
             GROUP BY u.name HAVING COUNT(o._id) > ?" 5)

**`sql-execute (sql &rest params)`** - Execute raw SQL that does not return rows (DDL, INSERT, UPDATE, DELETE).
Use ? placeholders for parameters.

Example:
  (rdb:sql-execute "CREATE INDEX idx_users_name ON users (name)")

---

## Session Persistence - database-backed session store

Package: `fluxion.session.db`

### Class: `db-session-store`

Session store backed by a fluxion.db database.
Persists session metadata to a database table. Components and event
queues are not persisted (they are recreated at runtime).

Slots:

- **`backend`** - The fluxion.db backend used for session storage.
- **`collection`** - Name of the DB collection (table) for sessions.

### Generic Functions

**`session-store-backend (object)`**

**`session-store-collection (object)`**

### Functions

**`make-db-session-store (backend &key (collection fluxion_sessions))`** - Create a database-backed session store.
BACKEND is a connected fluxion.db backend instance.

---

## User System - accounts, extensible fields, hierarchical permissions

Package: `fluxion.user`

### Class: `permission-denied`

Slots:

- **`username`**
- **`permission`**

### Class: `user-already-exists`

Slots:

- **`username`**

### Class: `user-error`

Slots:

- **`message`**

### Class: `user-not-found`

Slots:

- **`username`**

### Functions

**`add-default-permissions (&rest permissions)`** - Add PERMISSIONS to the default set granted to new users.

**`check (username permission)`** - Check if USERNAME has PERMISSION (or a parent of it).
Hierarchical: "admin.users.edit" implies "admin.users" and "admin".
Returns T if granted, NIL otherwise.

**`create (username &key password fields)`** - Create a new user with USERNAME and optional PASSWORD and FIELDS.
PASSWORD is hashed before storage. FIELDS is an alist of string key-value pairs.
Returns the user's database ID.
Signals USER-ALREADY-EXISTS if the username is taken.

**`field (username field-name)`** - Return the value of FIELD-NAME for USERNAME, or NIL if not set.

**`fields (username)`** - Return all extensible fields for USERNAME as an alist.
Signals USER-NOT-FOUND if the user does not exist.

**`get (username)`** - Get a user record as an alist by USERNAME.
Returns an alist with "_id", "username", "password_hash" keys, or NIL.

**`grant (username permission)`** - Grant PERMISSION to USERNAME. Idempotent.

**`hash-password (password)`** - Hash PASSWORD using PBKDF2-SHA256. Returns a string encoding
the salt and derived key in hex, separated by a colon.

**`list-users ()`** - Return a list of all user records (alists).

**`permissions (username)`** - Return a list of all permission strings granted to USERNAME.

**`remove (username)`** - Remove a user and all associated fields and permissions.
Signals USER-NOT-FOUND if the user does not exist.

**`remove-field (username field-name)`** - Remove FIELD-NAME from USERNAME's extensible fields.

**`revoke (username permission)`** - Revoke PERMISSION from USERNAME. Idempotent.

**`set-field (username field-name value)`** - Set FIELD-NAME to VALUE for USERNAME.
Creates the field if it does not exist, updates if it does.

**`setup ()`** - Create the user, fields, and permissions tables if they do not exist.
Idempotent: safe to call multiple times.

**`user-id (user-or-username)`** - Return the database ID of a user. Accepts a user alist or username string.

**`user-password-hash (user-alist)`** - Return the password hash from a user alist.

**`user-username (user-alist)`** - Return the username from a user alist.

**`user= (a b)`** - Return T if two user references identify the same user.
Accepts user alists or username strings.

**`verify-password (password hash-string)`** - Verify PASSWORD against a stored HASH-STRING (salt:key in hex).
Returns T if the password matches.

### Variables

**`*default-permissions*`** *(variable)* - List of permission strings automatically granted to new users.
Set before calling user:create to apply defaults.

---

## Authentication - login/logout, session-to-user binding, hooks

Package: `fluxion.auth`

### Class: `authentication-failed`

Slots:

- **`username`**

### Class: `not-authenticated`

### Functions

**`current ()`** - Return the user alist for the current session, or NIL if not authenticated.

**`current-user-id ()`** - Return the database ID of the current user, or NIL.

**`login (username password)`** - Authenticate USERNAME with PASSWORD and bind to the current session.
Returns the user alist on success.
Signals AUTHENTICATION-FAILED if credentials are invalid.
Requires *current-session* to be bound (i.e. called within a request).

**`logout ()`** - Unbind the current user from the session.
Clears user data, roles, and regenerates CSRF token.
Returns T if a user was logged out, NIL if no user was bound.

**`require-authenticated ()`** - Signal NOT-AUTHENTICATED if no user is bound to the current session.
Use at the start of handlers that require login.

### Variables

**`*login-timeout*`** *(variable)* - Optional override for session TTL after login (in seconds).
When set, the session expiry is adjusted after successful login.
NIL means use the default session TTL.

**`*on-login*`** *(variable)* - Function called after successful login with (user-alist session).
Use for audit logging, analytics, etc.

**`*on-logout*`** *(variable)* - Function called after logout with (username session).
Use for cleanup, audit logging, etc.

---

## Ban System - IP-based access control with database persistence

Package: `fluxion.ban`

### Functions

**`banned-p (ip)`** - Return T if IP is currently banned, NIL otherwise.
Expired bans are treated as not banned (and cleaned up).

**`clear-expired ()`** - Remove all expired bans from the database.
Returns the number of bans removed.

**`jail (ip &key (duration nil) (reason ))`** - Ban an IP address.
DURATION is optional seconds until expiry (NIL = permanent).
REASON is an optional description.
If the IP is already banned, the ban is updated.

**`jail-time (ip)`** - Return seconds remaining on the ban for IP, or NIL if not banned.
Returns :permanent for permanent bans.

**`list-bans ()`** - Return a list of all active ban records (alists).
Expired bans are excluded.

**`make-ban-middleware (&key (response-code 403) (response-body forbidden))`** - Return a Clack middleware that rejects requests from banned IPs.
RESPONSE-CODE: HTTP status for banned requests (default 403).
RESPONSE-BODY: response body string.

**`release (ip)`** - Remove the ban on IP. Idempotent (no error if not banned).

**`setup ()`** - Create the bans table if it does not exist. Idempotent.

---

## Rate Limiting - named per-resource limits with per-client tracking

Package: `fluxion.rate`

### Class: `rate-limit-exceeded`

Slots:

- **`limit-name`**
- **`retry-after`**

### Macros

**`with-limitation ((name env) &body body)`** *(macro)* - Execute BODY if the named rate limit allows the request.
If the limit is exceeded:
  - Calls the on-exceeded handler if defined (uses its return value if non-nil)
  - Otherwise returns a 429 Too Many Requests response
ENV is the Clack request environment.

### Functions

**`check-limit (name env)`** - Check if the named rate limit allows this request.
Returns (values allowed-p remaining retry-after).
ALLOWED-P is T if the request is within limits.
REMAINING is the number of requests left in the current window.
RETRY-AFTER is seconds until the window resets (only meaningful when denied).

**`client-ip (env)`** - Extract client IP from a Clack environment.

**`client-session (env)`** - Extract session ID from a Clack environment (via cookie).

**`client-user (env)`** - Extract authenticated user identifier from the current session.
Falls back to IP if no user is bound.

**`define-limit (name &key (window 60) (max-requests 10) (key-fn nil) (on-exceeded nil))`** - Define or redefine a named rate limit.
NAME: keyword identifier.
WINDOW: time window in seconds (default 60).
MAX-REQUESTS: maximum requests per window (default 10).
KEY-FN: function (env) returning a string key for per-client tracking.
         NIL means use client IP.
ON-EXCEEDED: optional function (env) called when limit is hit.
             If it returns a response list, that response is used.

**`find-limit (name)`** - Look up a rate limit by name. Returns the rate-limit struct or NIL.

**`left (name env)`** - Return the number of requests remaining for the named limit.
Does not consume a request.

**`remove-limit (name)`** - Remove a named rate limit.

**`reset-limit (name)`** - Clear all tracking data for a named limit. Useful for testing.

### Variables

**`*limits*`** *(variable)* - Registry of named rate limits, keyed by keyword.

---

