# Fluxion API Reference

Complete reference for all exported symbols. Organised by package.

## Components (`fluxion.components`)

### Classes

**`component`** - Base class for all Fluxion components.

Slots:

- `id` (string) - unique identifier, used as the DOM element ID. Set via `:id` initarg or auto-generated from the class name.
- `signals` - optional signal store for client-side reactive state.
- `dirty-p` (boolean) - whether the component needs re-rendering.
- `last-html` - cached HTML from the last render, used for diff comparison.

### Generic Functions

**`render (component)`** - return an HTML string for the component. The outermost element must have an `id` attribute matching `(component-id component)`.

**`handle-action (component action params)`** - handle an incoming action. `action` is a keyword (e.g. `:increment`). `params` is an alist of request parameters with keyword keys. Return a list of SSE events, or `nil` to auto-patch.

### Macros

**`defcomponent name &key id slots render`** - define a component in a single form.

Generates the CLOS class, cell setup, accessor functions, and render method. Inside the `:render` body, `self` is bound to the component instance.

Arguments:

- `name` - class name (symbol).
- `:id` - DOM element ID (string). Defaults to the downcased class name.
- `:slots` - list of slot specs. Each spec is `(slot-name &key cell initform accessor test)`.
  - `:cell t` - back the slot with a reactive cell connected to the component.
  - `:initform value` - initial value.
  - `:accessor name` - generate reader and `(setf reader)` functions.
  - `:test fn` - equality test for the cell (default `eql`).
- `:render` - body form that returns an HTML string.

Example:

```lisp
(fluxion.components:defcomponent counter
  :id "counter"
  :slots ((count :cell t :initform 0 :accessor counter-count))
  :render (spinneret:with-html-string
            (:div :id (fluxion.components:component-id self)
              (:p (format nil "Count: ~D" (counter-count self))))))
```

**`defaction component-class action-name (component-var &optional params-var) &body body`** - define an action handler.

Generates a `handle-action` method specialised on `component-class` and `action-name` (a keyword). The component is automatically marked dirty before the body runs. If the body returns `nil`, a default patch is sent. Return `'()` to suppress the patch (useful when cell watchers handle it).

Example:

```lisp
(fluxion.components:defaction counter :increment (c)
  (incf (counter-count c))
  '())
```

### Functions

**`patch-component (component &key mode force)`** - re-render the component and return a list containing a patch event. Compares against the cached HTML and returns an empty list if nothing changed, unless `:force t` is given. `:mode` defaults to `"morph"`.

**`mark-dirty (component)`** - set the dirty flag on a component.

**`clear-dirty (component)`** - clear the dirty flag.

**`component-selector (component)`** - return the CSS selector string (e.g. `"#my-widget"`).

---

## Cells / Lattice (`fluxion.cells` / `fluxion.lattice`)

The reactive engine. `fluxion.lattice` is a package nickname for `fluxion.cells`.

### Cells

**`make-cell (value &key name test)`** - create a new cell holding `value`.

- `:name` - optional name string for debugging.
- `:test` - equality function (default `eql`). The cell only notifies watchers when the new value is different according to this test.

**`cell-value (cell)`** - read the cell's current value. Also `(setf cell-value)` to write. Writing notifies all watchers if the value changed.

**`cell-name (cell)`** - the cell's name string.

**`watch (cell fn)`** - add a watcher function. `fn` is called as `(funcall fn new-value old-value)` whenever the cell's value changes. Returns `fn`.

**`unwatch (cell fn)`** - remove a previously added watcher.

### Computed Cells

**`make-computed (thunk &key name)`** - create a cell whose value is computed by calling `thunk`. Dependencies are tracked automatically: any cell read during execution of the thunk becomes a dependency. When a dependency changes, the computed cell recomputes.

The thunk is a function of zero arguments. It should read cells via `cell-value` and return the derived value.

```lisp
(let* ((a (make-cell 2))
       (b (make-cell 3))
       (sum (make-computed (lambda ()
                             (+ (cell-value a) (cell-value b))))))
  (cell-value sum))  ;; => 5
```

### Propagators

**`make-propagator (&key inputs fn outputs name)`** - create a propagator that fires `fn` whenever any input cell changes.

- `:inputs` - list of input cells.
- `:fn` - function called with the current values of the input cells (one argument per input). Returns the value to write to the output(s).
- `:outputs` - list of output cells to write the result to.
- `:name` - optional name string.

Propagators include a re-entrance guard to prevent infinite cycles in bidirectional networks.

```lisp
;; Bidirectional celsius/fahrenheit
(make-propagator
 :inputs (list celsius)
 :fn (lambda (c) (+ (* c 9/5) 32))
 :outputs (list fahrenheit))
(make-propagator
 :inputs (list fahrenheit)
 :fn (lambda (f) (* (- f 32) 5/9))
 :outputs (list celsius))
```

### Component Connection

**`connect (cell component)`** - wire a cell to a component. When the cell's value changes, the component is automatically re-rendered and a patch event is collected. With `defcomponent`, cell-backed slots are connected automatically.

**`disconnect (cell component)`** - remove the connection.

---

## Server (`fluxion.server`)

### Application

**`make-fluxion-app (&key port static-dir session-ttl reaper-interval)`** - create a new Fluxion application.

- `:port` - server port (default 5000).
- `:static-dir` - directory for serving static files under `/static/`.
- `:session-ttl` - seconds before idle sessions expire (default 3600).
- `:reaper-interval` - seconds between reaper runs (default 60).

**`start (app page-handler &key port)`** - start the server. `page-handler` is a function `(app session env)` that returns a Clack response list `(status headers body)`.

**`stop (app)`** - stop the server and the session reaper.

### Component Registry

**`register-component (app component)`** - register a global (shared) component instance.

**`register-component-factory (app id factory-fn)`** - register a factory function for per-session component creation. `id` is the component-id string. `factory-fn` is `(lambda () ...)` returning a fresh component.

**`find-component (app id &key session)`** - look up a component. Checks the session first, then global registrations.

### Sessions

**`session`** - class representing a browser session.

**`session-id (session)`** - the session ID string.

**`session-component (session id)`** - look up a component by ID within a session.

**`session-components (session)`** - the hash table of all components in the session.

### Server Push

These functions push events to a session's persistent SSE connection (the `/sse` endpoint).

**`push-event (session event)`** - push a single SSE event. The event is delivered to the browser via the EventSource stream. Does nothing if the session has no active SSE connection.

**`push-events (session events)`** - push a list of SSE events.

**`push-component-patch (session component &key mode)`** - re-render the component and push a patch event to the session. Marks the component dirty and forces the patch.

### SSE Helpers

**`send-event (stream event)`** - write a single SSE event to a stream (used in action response bodies).

**`send-events (stream events)`** - write multiple SSE events to a stream.

**`patch (stream component &key mode)`** - render a component and write a patch event to a stream.

---

## Events (`fluxion.events`)

All event constructors return an `sse-event` struct suitable for `send-event`, `push-event`, or inclusion in an action response.

**`make-patch-event (selector html &key mode)`** - patch (morph or replace) the element matching `selector` with `html`. `:mode` is `"morph"` (default) or `"replace"`.

**`make-remove-event (selector)`** - remove the element matching `selector`.

**`make-append-event (selector html)`** - append `html` as the last child of the element matching `selector`.

**`make-prepend-event (selector html)`** - prepend `html` as the first child.

**`make-signal-event (signals)`** - update client-side signals. `signals` is an alist of `(name . value)` pairs.

**`make-script-event (script)`** - execute `script` (a JavaScript string) in the browser.

**`make-redirect-event (url)`** - redirect the browser to `url`.

---

## Protocol (`fluxion.protocol`)

Low-level SSE formatting. Most users won't need these directly.

**`sse-event`** - struct with slots: `type`, `data`, `id`, `retry`.

**`make-sse-event (&key type data id retry)`** - create an SSE event struct.

**`format-sse-event (event)`** - format an event as a string in `text/event-stream` format.

**`write-sse-event (event stream)`** - write an event to a stream.

---

## Render (`fluxion.render`)

**`render-page (&key title body-html head-html)`** - render a full HTML page with the Fluxion client runtime script tag included.

**`fluxion-script-tag ()`** - return the `<script>` tag that loads `/static/fluxion.js`.

---

## Client (`fluxion.client`)

**`build-client (&key output-path)`** - compile the Parenscript runtime to JavaScript and write it to `output-path` (defaults to `static/fluxion.js`).

---

## Umbrella Package (`fluxion` / `fx`)

The `fluxion` package (nicknamed `fx`) re-exports the most commonly used symbols from all sub-packages. You can use `fluxion:defcomponent`, `fluxion:push-event`, etc. without importing individual packages.
