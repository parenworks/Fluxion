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

### Generic Functions

**`component-dirty-p (component)`** - Whether this component needs re-rendering. Set by mark-dirty, cleared by patch-component.

**`component-id (component)`** - Unique identifier string, used as the DOM element ID and CSS selector target.

**`component-last-html (component)`** - Cached HTML from the last render. Used for dirty comparison to avoid sending no-op patches.

**`component-signals (component)`** - Optional signal-store for this component's client-side reactive state.

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

### Class: `fluxion-error`

Base condition for all Fluxion framework errors.

Slots:

- **`message`**

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

**`app-handler (app)`** - The running Clack handler reference (used for stopping the server).

**`app-reaper-interval (app)`** - Seconds between session reaper runs.

**`app-request-log (app)`** - When non-nil, every request is logged to *standard-output*.

**`app-server (app)`** - Clack server backend keyword (:woo or :hunchentoot).

**`app-session-lock (app)`** - Lock protecting concurrent access to the session store.

**`app-session-ttl (app)`** - Session time-to-live in seconds before idle expiry.

**`app-sessions (app)`** - Hash table of active sessions keyed by session-id string.

**`app-started-at (app)`** - Universal time when the server was started.

**`component-not-found-id (condition)`** - The component-id string that could not be resolved.

**`eq-closed-p (queue)`** - Whether the event queue has been closed.

**`find-component (app id &key session)`** - Find a component by ID. Checks session first, then global registry.

**`fluxion-error-message (condition)`** - Human-readable error message for the condition.

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

**`session-component (session id)`** - Find a component by ID within a SESSION.

**`session-components (session)`** - Hash table of component instances for this session, keyed by component-id.

**`session-csrf-token (session)`** - The session's CSRF token string. Validated on every POST request.

**`session-event-queue (session)`** - The SSE event queue for this session. Created on first /sse connection.

**`session-id (session)`** - Unique session identifier string (used as the cookie value).

**`session-not-found-id (condition)`** - The session-id string that could not be resolved.

**`session-user (session)`** - Application-defined user data. NIL when not authenticated.

**`session-user-roles (session)`** - List of role keywords for the authenticated user, e.g. (:admin :editor).

**`start (app page-handler &key)`** - Start the Fluxion application server.

**`stop (app)`** - Stop the Fluxion application server.

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

**`make-fluxion-app (&key (port 5000) static-dir (session-ttl 3600) (reaper-interval 60) (server woo) (request-log
                                                                                  t))`** - Create a new Fluxion application instance.
SERVER is the Clack backend: :woo (default) or :hunchentoot.
Woo uses libev for async I/O. Install libev-dev to use it.
REQUEST-LOG: when non-nil (default T), logs every request.

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

