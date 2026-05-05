# Fluxion TODO

## Completed

- [x] **Split server.lisp** - broke monolithic file into 8 focused modules:
      csrf.lisp, event-queue.lisp, session.lisp, auth.lisp, app.lisp,
      router.lisp, reaper.lisp, handler.lisp
- [x] **Harden session ID and CSRF generation** - replaced CL random with
      ironclad CSPRNG (32 hex chars). Added tests for format and uniqueness.
- [x] **Fix read-from-string in validation.lisp** - bind *read-eval* to NIL,
      verify result is numberp
- [x] **O(1) event queue enqueue** - replaced nconc with tail-pointer append.
      Reset tail on dequeue-all.
- [x] **Bounded event queue** - added max-size (default 1024), drops oldest
      when full. Tests for drop-oldest, count tracking, and unbounded mode.
- [x] **Condition hierarchy** - defined fluxion-error, session-not-found,
      csrf-validation-error, action-dispatch-error, component-not-found,
      request-parse-error in conditions.lisp. Exported from fluxion.server.
- [x] **Bind *current-session* during dispatch** - added dynamic variable,
      bound in handler.lisp during session-scoped request dispatch.
- [x] **print-object methods** - added for session, event-queue, fluxion-app,
      router, route, validation-result, signal-store.
- [x] **Expand static file MIME types** - added png, jpg, gif, svg, ico, webp,
      woff, woff2, ttf, otf, map, xml, txt, mjs.

- [x] **Resolve signals vs Lattice duality** - deprecated signals.lisp with
      clear header comments. signal-store retained for backwards compatibility.
      make-signal-event and client-side signals unaffected.
- [x] **Promote key functions to defgeneric** - patch-component,
      parse-request-body, push-component-patch are now generic functions
      with typed methods for extensibility.

## Low Priority

- [x] **Fix defcomponent SELF hygiene** - uses gensym for method parameter,
      symbol-macrolet binds SELF in caller's package. No variable capture.
- [x] **Fix destroy-thread in examples** - counter.lisp now uses cooperative
      stop-flag + join-thread pattern. stop-counter calls stop-clock-ticker.
- [x] **Input debouncing** - added data-debounce="ms" attribute support in
      client runtime. Uses setTimeout/clearTimeout pattern.
- [x] **Request deduplication** - added data-disable-during-request attribute.
      Disables element on click, re-enables after POST completes.

- [x] **End-to-end HTTP integration tests** - 10 tests using Dexador: health
      endpoint, page serving, static files, CSRF rejection, action dispatch,
      session persistence, multi-increment, session isolation, *current-session*
      binding. Added to tests/test-integration.lisp.
- [x] **Update examples to new Fluxion structure** - all 4 examples (counter,
      todo, converter, colour-picker) now use: fx umbrella package ((:use #:fluxion)),
      router-based page serving (defroute + router-handler), data-debounce on
      inputs, data-disable-during-request on buttons.
- [x] **Fix umbrella package** - fluxion/fx package now uses import-from to
      share symbols with sub-packages. (:use #:fluxion) works in user code.

## Future / Architectural

- [ ] **Per-session cell locks** - replace global cell lock with per-session
      locks for better concurrency.
- [x] **Component composition/nesting** - parent/children/session back-pointers,
      add-child/remove-child, component-root, find-child, propagate-session.
      30 tests covering nesting, reparenting, session propagation, rendering.
- [x] **Middleware/hook system** - onion-style middleware chain with add/remove/clear.
      Built-in: request-logger, rate-limiter (token bucket), CORS. 12 tests.
- [x] **Component lifecycle callbacks** - component-mounted, component-unmounted,
      component-connected. Fires on factory creation, session reap, SSE connect.
      6 tests (including end-to-end HTTP SSE verification).
- [x] **Multi-implementation support** - CCL fully supported (365 tests pass).
      ECL blocked by serapeum compilation failure (upstream issue).
- [x] **Documentation generation** - tools/generate-docs.lisp introspects all
      exported symbols, extracts docstrings, slots, lambda lists, and generates
      API.md automatically. Run: (load "tools/generate-docs.lisp") (fluxion.docs:generate)
