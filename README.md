# Fluxion

**Live server-rendered interfaces for Common Lisp.**

Fluxion lets you build reactive web interfaces using CLOS. You define components as ordinary classes, render them server-side with Spinneret, and stream HTML updates to the browser over Server-Sent Events. The browser runtime is written in Parenscript and compiles down to a single small JS file. Application developers write no JavaScript at all - behaviour is expressed with `data-*` attributes in the HTML.

The server owns the state. The browser just follows instructions.

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
│   ├── components.lisp      ; CLOS component model
│   ├── render.lisp          ; Spinneret rendering helpers
│   └── server.lisp          ; Clack/Hunchentoot integration
├── client/
│   ├── package.lisp         ; Client package
│   └── runtime.lisp         ; Parenscript browser runtime
├── static/
│   └── fluxion.js           ; Compiled client runtime (generated)
├── examples/
│   └── counter.lisp         ; Counter demo
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
      (:button :data-on-click "/widget/update" "Update"))))
```

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
```

## Supported `data-*` Attributes

| Attribute                    | Description                                   |
| ---------------------------- | --------------------------------------------- |
| `data-on-click="/path"`      | POST to path on click                         |
| `data-on-submit="/path"`     | POST form data to path on submit              |
| `data-bind="signal-name"`    | Two-way bind input value to a client signal   |
| `data-text="$signal-name"`   | Display signal value as text content          |

## Dependencies

- [Spinneret](https://github.com/ruricolist/spinneret) - HTML generation
- [Alexandria](https://gitlab.common-lisp.net/alexandria/alexandria) - utilities
- [Clack](https://github.com/fukamachi/clack) / [Hunchentoot](https://edicl.github.io/hunchentoot/) - web server
- [cl-json](https://cl-json.common-lisp.dev/) - JSON encoding/decoding
- [Parenscript](https://common-lisp.net/project/parenscript/) - Lisp-to-JavaScript compiler
- [Babel](https://github.com/cl-babel/babel) - charset encoding/decoding
- [Bordeaux Threads](https://sionescu.github.io/bordeaux-threads/) - threading

## Roadmap

- **v0.1** - manual actions and HTML patches (current)
- **v0.2** - component state and dirty tracking
- **v0.3** - server-side cells/signals
- **v0.4** - computed cells
- **v0.5** - Lattice: propagator-inspired reactive dependency graph

## Licence

BSD-3-Clause
