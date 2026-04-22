# Fluxion

**Live server-rendered interfaces for Common Lisp.**

Fluxion lets you build reactive web interfaces using CLOS. You define components as ordinary classes, render them server-side with Spinneret, and stream HTML updates to the browser over Server-Sent Events. The browser runtime is written in Parenscript and compiles down to a single small JS file. Application developers write no JavaScript at all - behaviour is expressed with `data-*` attributes in the HTML.

The server owns the state. The browser just follows instructions.

The reactive layer is built on Lattice, a propagator-inspired engine where cells hold values, computed cells derive from them automatically, and propagators wire up bidirectional constraints. If you know the Radul/Sussman propagator work, that is the lineage. If you don't, it just means your components react to state changes without you having to wire every update by hand.

## Core Ideas

- **CLOS components** - UI components are ordinary CLOS classes with `render` and `handle-action` generic functions.
- **Server-side state** - application logic and state live on the server, not in the browser.
- **HTML over the wire** - the server sends rendered HTML fragments, not JSON. The browser swaps them into the page.
- **SSE patches** - Server-Sent Events carry patch instructions (replace, append, remove, morph) as JSON payloads.
- **Parenscript client** - the browser runtime is authored in Parenscript and compiled to a single small JS file.
- **Minimal JavaScript** - application developers write no JavaScript. Behaviour is expressed with `data-*` attributes.

## Quick Start

```lisp
;; Load the system
(ql:quickload :fluxion/examples)

;; Start the counter demo
(fluxion.examples.counter:start-counter)
;; Open http://localhost:5000

;; Or the todo list
(fluxion.examples.todo:start-todo)
;; Open http://localhost:5000

;; Or the temperature converter (propagators)
(fluxion.examples.converter:start-converter)
;; Open http://localhost:5000
```

## Architecture

```text
fluxion/
├── fluxion.asd              ; ASDF system definitions
├── src/
│   ├── package.lisp         ; Package definitions
│   ├── protocol.lisp        ; SSE/JSON event protocol
│   ├── events.lisp          ; Event type constructors
│   ├── signals.lisp         ; Server-side signal store
│   ├── components.lisp      ; CLOS component model, defaction, dirty tracking
│   ├── render.lisp          ; Spinneret rendering helpers
│   └── server.lisp          ; Clack/Hunchentoot, sessions, action dispatch
├── client/
│   ├── package.lisp         ; Client package
│   └── runtime.lisp         ; Parenscript browser runtime
├── static/
│   └── fluxion.js           ; Compiled client runtime (generated)
├── examples/
│   ├── counter.lisp         ; Counter demo (cells + computed)
│   ├── todo.lisp            ; Todo list demo (sessions, data-* attrs)
│   └── converter.lisp       ; Temperature converter (bidirectional propagators)
└── README.md
```

## Defining a Component

```lisp
(defclass my-widget (fluxion.components:component)
  ((value :initform "" :accessor widget-value))
  (:default-initargs :id "my-widget"))

(defmethod fluxion.components:render ((w my-widget))
  (spinneret:with-html-string
    (:div :id (fluxion.components:component-id w)
      (:p (widget-value w))
      (:button :data-on-click "/action/my-widget/update" "Update"))))
```

## Defining Actions

The `defaction` macro defines CLOS methods for handling component actions. The URL pattern is `/action/{component-id}/{action-name}`. Actions automatically mark the component as dirty and send a patch event after the body runs.

```lisp
(fluxion.components:defaction my-widget :update (w params)
  (setf (widget-value w) "Updated!")
  nil)  ; return nil to auto-patch, or return a list of custom SSE events
```

## Sessions

Each browser session gets its own component instances. Register a factory function instead of a global instance, and the framework handles the rest.

```lisp
(let ((app (fluxion.server:make-fluxion-app
            :port 5000
            :session-ttl 3600       ; seconds before idle sessions expire (default 1h)
            :reaper-interval 60)))  ; how often to check for expired sessions (default 60s)
  ;; Each session gets a fresh my-widget
  (fluxion.server:register-component-factory app "my-widget"
    (lambda () (make-instance 'my-widget)))

  ;; Page handler receives (app session env)
  (fluxion.server:start app
    (lambda (app session env)
      (declare (ignore app env))
      (let ((widget (fluxion.server:session-component session "my-widget")))
        (list 200
              '(:content-type "text/html")
              (list (render-my-page widget)))))))
```

Expired sessions are automatically cleaned up by a background reaper thread.

## SSE Protocol

Events are sent as standard SSE with JSON payloads:

```text
event: fluxion-patch
data: {"selector":"#my-widget","mode":"morph","fragment":"<div id=\"my-widget\">...</div>"}

event: fluxion-remove
data: {"selector":"#old-element"}

event: fluxion-append
data: {"selector":"#log-list","fragment":"<li>New entry</li>"}

event: fluxion-signals
data: {"signals":{"count":42,"status":"ready"}}

event: fluxion-script
data: {"script":"fluxionShowError('Something went wrong')"}
```

## Supported `data-*` Attributes

| Attribute | Description |
| --- | --- |
| `data-on-click="/path"` | POST to path on click |
| `data-on-submit="/path"` | POST form data to path on submit |
| `data-on-change="/path"` | POST on checkbox/select/radio change (sends `checked` or `value`) |
| `data-on-keydown="/path"` | POST on keydown (sends `value`). Combine with `data-key="Enter"` to filter |
| `data-on-input="/path"` | POST on each input keystroke (sends `value`) |
| `data-key="Enter"` | Filter `data-on-keydown` to a specific key |
| `data-param-foo="bar"` | Include `foo: "bar"` in the POST body. Works with any `data-on-*` |
| `data-confirm="Are you sure?"` | Show a confirmation dialog before executing a click action |
| `data-bind="signal-name"` | Two-way bind input value to a client-side signal |
| `data-text="$signal-name"` | Display signal value as text content |

## Lattice - Reactive Engine

Fluxion's reactive layer is called Lattice. It has three building blocks.

**Cells** hold a value and notify watchers when it changes.

```lisp
(let ((count (fluxion.cells:make-cell 0 :name "count")))
  (fluxion.cells:watch count
    (lambda (new old)
      (format t "count changed: ~A -> ~A~%" old new)))
  (setf (fluxion.cells:cell-value count) 1))
;; => count changed: 0 -> 1
```

**Computed cells** derive their value from other cells. Dependencies are tracked automatically - you just read cells inside the thunk and Lattice figures out the graph.

```lisp
(let* ((count (fluxion.cells:make-cell 5))
       (label (fluxion.cells:make-computed
               (lambda ()
                 (format nil "Count is ~D" (fluxion.cells:cell-value count))))))
  (fluxion.cells:cell-value label))
;; => "Count is 5"
;; Changing count automatically recomputes label.
```

**Propagators** connect input cells to output cells through a function. They support bidirectional networks - CL's exact rational arithmetic means values converge perfectly with no floating-point oscillation.

```lisp
(let ((celsius    (fluxion.cells:make-cell 0))
      (fahrenheit (fluxion.cells:make-cell 32)))
  ;; Two propagators form a bidirectional constraint
  (fluxion.cells:make-propagator
   :inputs (list celsius)
   :fn (lambda (c) (+ (* c 9/5) 32))
   :outputs (list fahrenheit))
  (fluxion.cells:make-propagator
   :inputs (list fahrenheit)
   :fn (lambda (f) (* (- f 32) 5/9))
   :outputs (list celsius))
  ;; Set either side and the other updates
  (setf (fluxion.cells:cell-value celsius) 100)
  (fluxion.cells:cell-value fahrenheit))
;; => 212
```

To connect a cell to a component so that changes trigger automatic DOM patches:

```lisp
(fluxion.cells:connect my-cell my-component)
```

The counter example uses cells and a computed cell. The temperature converter example uses bidirectional propagators. Both are in the `examples/` directory.

## Error Handling

Server-side action errors are sent back as SSE script events that trigger an error toast in the browser. The toast auto-dismisses after 8 seconds or can be closed manually. You can also call `fluxionShowError("message")` from JavaScript or from a `fluxion-script` event.

## Dirty Tracking

Components have a `dirty-p` flag and a `last-html` cache. The `defaction` macro marks a component dirty before the body runs. `patch-component` compares the new render against the cache and skips sending if nothing changed. You can force a patch with `:force t`.

```lisp
(fluxion.components:patch-component my-component)           ; skips if clean
(fluxion.components:patch-component my-component :force t)   ; always sends
(fluxion.components:mark-dirty my-component)                 ; manual dirty
```

## Dependencies

- [Spinneret](https://github.com/ruricolist/spinneret) - HTML generation
- [Alexandria](https://gitlab.common-lisp.net/alexandria/alexandria) - utilities
- [Clack](https://github.com/fukamachi/clack) / [Hunchentoot](https://edicl.github.io/hunchentoot/) - web server
- [cl-json](https://cl-json.common-lisp.dev/) - JSON encoding/decoding
- [Parenscript](https://common-lisp.net/project/parenscript/) - Lisp-to-JavaScript compiler
- [Babel](https://github.com/cl-babel/babel) - charset encoding/decoding
- [Bordeaux Threads](https://sionescu.github.io/bordeaux-threads/) - threading

## Roadmap

- **v0.1** - manual actions and HTML patches
- **v0.2** - dirty tracking, sessions, defaction, data-* attributes
- **v0.3** - reactive cells with watchers
- **v0.4** - computed cells with automatic dependency tracking
- **v0.5** - Lattice: propagator-inspired reactive dependency graph (current)

## Licence

BSD-3-Clause
