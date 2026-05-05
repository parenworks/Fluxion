# Fluxion Developer Guide

Practical patterns, deployment advice, and architecture notes for building applications with Fluxion.

For API reference, see [API.md](API.md). For a quick overview, see [README.md](README.md).

---

## Project Structure

A typical Fluxion application:

```text
my-app/
├── my-app.asd          ; ASDF system definition
├── src/
│   ├── package.lisp    ; package definitions
│   ├── components.lisp ; CLOS component classes + render methods
│   ├── actions.lisp    ; defaction handlers
│   ├── pages.lisp      ; page handlers (render-page calls)
│   └── app.lisp        ; make-fluxion-app, router, start/stop
├── static/
│   ├── style.css       ; your styles
│   └── fluxion.js      ; auto-generated client runtime
└── tests/
    └── ...
```

The `static/fluxion.js` file is compiled from Parenscript by calling `(fluxion.client:build-client)`. Commit it to your repo so deployment doesn't require a Parenscript toolchain.

---

## Component Patterns

### Basic Component

```lisp
(fluxion.components:defcomponent greeting
  :id "greeting"
  :slots ((name :initarg :name :accessor greeting-name))
  :render (spinneret:with-html-string
            (:div :id (component-id self)
              (:h1 (format nil "Hello, ~A!" (greeting-name self))))))
```

### Cell-Backed Component (Reactive)

Cell-backed slots automatically trigger patches when their values change. No manual dirty-tracking needed.

```lisp
(fluxion.components:defcomponent counter
  :id "counter"
  :slots ((count :cell t :initform 0 :accessor counter-count))
  :render (spinneret:with-html-string
            (:div :id (component-id self)
              (:p (format nil "Count: ~D" (counter-count self)))
              (:button :data-on-click "/action/counter/increment" "+1"))))

(fluxion.components:defaction counter :increment (c)
  (incf (counter-count c))
  '())  ; empty list = let the cell watcher handle the patch
```

### Multi-Cell Consistency

When multiple cells must update atomically, use `with-transaction`. Watchers see the final state, never intermediate values.

```lisp
(fluxion.cells:with-transaction
  (setf (cell-a-value comp) new-a)
  (setf (cell-b-value comp) new-b))
;; Watchers fire once, in topological order, after both are set.
```

### Computed Cells

Computed cells derive their value from other cells and recompute automatically.

```lisp
(let* ((first-name (fluxion.cells:make-cell "John" :name "first"))
       (last-name  (fluxion.cells:make-cell "Doe"  :name "last"))
       (full-name  (fluxion.cells:make-computed
                    (lambda ()
                      (format nil "~A ~A"
                              (fluxion.cells:cell-value first-name)
                              (fluxion.cells:cell-value last-name)))
                    :name "full")))
  ;; Changing first-name automatically recomputes full-name.
  (setf (fluxion.cells:cell-value first-name) "Jane"))
```

---

## Client Behaviour Attributes

### Debouncing Input Events

For live-as-you-type inputs (sliders, text fields), use `data-debounce` to throttle the frequency of POST requests. The value is in milliseconds:

```lisp
(:input :type "range"
        :data-on-input "/action/picker/set-red"
        :data-debounce "16")  ; ~60fps
```

Lower values feel more responsive but generate more server traffic. Good defaults:

- **5-16ms** for sliders (near-realtime feedback)
- **150-300ms** for text search/autocomplete
- **No debounce** for discrete events (click, submit, keydown with data-key)

### Disabling During Request

Prevent double-clicks by disabling the element while the POST is in flight:

```lisp
(:button :data-on-click "/action/order/submit"
         :data-disable-during-request t
         "Place Order")
```

The button is disabled immediately on click, then re-enabled when the server responds. Works with any `data-on-click` element.

---

## Component Lifecycle

Components can implement lifecycle callbacks to hook into session creation, SSE connection, and session destruction.

### Initialisation on mount

Use `component-mounted` to set initial state based on session context:

```lisp
(defmethod fluxion.components:component-mounted ((d dashboard) session)
  (let ((user (fluxion.server:session-user session)))
    (setf (dashboard-greeting d)
          (format nil "Welcome back, ~A" user))))
```

### Resource cleanup on unmount

Use `component-unmounted` to release resources when the session expires:

```lisp
(defmethod fluxion.components:component-unmounted ((w worker-view) session)
  (declare (ignore session))
  (when (worker-poll-thread w)
    (setf (worker-stop-flag w) t)))
```

Errors in `component-unmounted` are caught and do not prevent the session from being reaped. This guarantees cleanup of one component never blocks cleanup of others.

### Pushing state on SSE connect

Use `component-connected` to push the current state when the browser establishes the EventSource connection. This fires on initial connection and on every reconnect:

```lisp
(defmethod fluxion.components:component-connected ((f feed) session)
  (fluxion.server:push-component-patch session f))
```

This ensures the client always has current state after a reconnect, even if updates were missed while disconnected.

---

## Component Composition

### Parent-child nesting

Components can form trees. Use `add-child` to establish the relationship:

```lisp
(defmethod fluxion.components:component-mounted ((shell app-shell) session)
  (let ((dashboard (fluxion.server:session-component session "dashboard")))
    (setf (shell-content shell) dashboard)
    (fluxion.components:add-child shell dashboard)))
```

The child's `component-parent` and `component-session` are set automatically. If the child was previously parented elsewhere, `add-child` moves it.

### Dynamic page switching

Swap children at runtime in an action handler:

```lisp
(fluxion.components:defaction app-shell :navigate (c params)
  (let* ((page-name (cdr (assoc :page params)))
         (session (fluxion.components:component-session c))
         (new-page (fluxion.server:session-component session page-name)))
    (when (shell-content c)
      (fluxion.components:remove-child c (shell-content c)))
    (setf (shell-content c) new-page)
    (fluxion.components:add-child c new-page))
  nil)
```

### Session access from any component

Every component has a `component-session` back-pointer, eliminating the need to scan all sessions:

```lisp
(defun current-user (component)
  (fluxion.server:session-user
   (fluxion.components:component-session component)))
```

### Finding descendants

Search a component tree by ID:

```lisp
(fluxion.components:find-child shell "settings-panel")
```

### Child-only patching

When only a child changes, patch it independently without re-rendering the parent:

```lisp
(fluxion.server:push-component-patch session child-component)
```

This sends a patch targeting only the child's DOM selector, leaving the rest of the page untouched.

---

## Server Push Patterns

### Broadcasting to All Sessions

Push updates to every connected browser (e.g. a live dashboard):

```lisp
(defun broadcast-update (app html)
  "Push an HTML patch to all connected sessions."
  (let ((event (fluxion.events:make-patch-event "#live-data" html)))
    (maphash (lambda (sid session)
               (declare (ignore sid))
               (fluxion.server:push-event session event))
             (fluxion.server:app-sessions app))))
```

### Background Threads Pushing Updates

A monitor thread that pushes data periodically:

```lisp
(defun start-monitor (app interval-seconds)
  (bt:make-thread
   (lambda ()
     (loop
       (sleep interval-seconds)
       (let ((html (render-current-metrics)))
         (broadcast-update app html))))
   :name "monitor"))
```

### Redirects and Scripts

```lisp
;; Redirect the browser after an action
(fluxion.events:make-redirect-event "/dashboard")

;; Execute arbitrary JS on the client
(fluxion.events:make-script-event "alert('Done!')")
```

---

## Routing

Use the router for multi-page applications:

```lisp
(let ((r (fluxion.server:make-router)))
  ;; Public pages
  (fluxion.server:defroute r :get "/" (app session env &key params)
    (declare (ignore params))
    (render-home-page app session))

  ;; Protected pages
  (fluxion.server:add-route r :get "/dashboard"
    (lambda (app session env &key params)
      (declare (ignore params))
      (render-dashboard app session))
    :guard (lambda (session) (fluxion.server:require-auth session)))

  ;; Role-based access
  (fluxion.server:add-route r :get "/admin"
    (lambda (app session env &key params)
      (declare (ignore params))
      (render-admin app session))
    :guard (lambda (session)
             (fluxion.server:require-role session :admin)))

  ;; Path parameters
  (fluxion.server:defroute r :get "/users/:id" (app session env &key params)
    (let ((user-id (cdr (assoc :id params))))
      (render-user-page app session user-id)))

  ;; Start with router
  (fluxion.server:start app (fluxion.server:router-handler r)))
```

---

## Server Backend

Fluxion uses [Clack](https://github.com/fukamachi/clack) as its server abstraction. You choose the backend:

### Woo (Default)

```lisp
(fluxion.server:make-fluxion-app)  ; Woo is the default
```

- libev event loop (async I/O)
- Handles thousands of concurrent SSE connections with minimal thread overhead
- ~250x higher HTTP throughput than Hunchentoot in benchmarks
- Requires `libev-dev` system package
- The default for both development and production

### Hunchentoot (Alternative)

```lisp
(fluxion.server:make-fluxion-app :server :hunchentoot)
```

- Thread-per-connection model
- Excellent error messages and debug mode
- No native dependencies
- Useful if you want Hunchentoot's interactive debugger during development

**Install libev:**

```bash
# Debian/Ubuntu
sudo apt install libev-dev

# macOS
brew install libev

# Arch
sudo pacman -S libev
```

**Install Woo:**

```lisp
(ql:quickload "clack-handler-woo")
```

You can also override the backend at start time without recreating the app:

```lisp
;; Default (Woo)
(fluxion.server:start app handler)

;; Override to Hunchentoot for debugging
(fluxion.server:start app handler :server :hunchentoot)
```

### Choosing a Backend

|                       | Woo (default)                | Hunchentoot               |
| --------------------- | ---------------------------- | ------------------------- |
| 1,600 GET requests    | 0.036s                       | 8.9s                      |
| 1,600 POST requests   | 0.028s                       | 8.8s                      |
| SSE connections       | event-loop, minimal overhead | 1 thread each             |
| Debug experience      | Minimal                      | Excellent                 |
| Native deps           | libev                        | None                      |

Woo is the default because its event-loop architecture is a natural fit for Fluxion's SSE-heavy workload. Use Hunchentoot when you want its interactive debugger during development.

---

## Deployment

### Standalone

```lisp
;; production.lisp
(ql:quickload "my-app")
(my-app:start :port 8080 :server :woo)

;; Keep the process alive
(loop (sleep 3600))
```

```bash
sbcl --load production.lisp
```

### Behind Caddy (Recommended)

Caddy handles TLS, HTTP/2, and automatic certificates. Minimal config:

```text
myapp.example.com {
    reverse_proxy localhost:8080
}
```

Caddy does not buffer responses by default, so SSE works out of the box. No special configuration needed.

### Behind nginx

nginx buffers responses by default. Fluxion sends `X-Accel-Buffering: no` on SSE responses, which tells nginx to stream them through. If you're using a custom nginx config, ensure:

```nginx
server {
    listen 443 ssl;
    server_name myapp.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        # SSE support
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
    }
}
```

The `proxy_read_timeout` is important — SSE connections are long-lived. The default 60s timeout will kill them.

### Building a Binary

For containerised deployments, build a standalone SBCL image:

```lisp
(ql:quickload "my-app")
(sb-ext:save-lisp-and-die "my-app"
  :toplevel (lambda ()
              (my-app:start :port 8080 :server :woo)
              (loop (sleep 3600)))
  :executable t
  :compression t)
```

This produces a single binary with no runtime dependencies (except libev if using Woo).

---

## SSE Connection Lifecycle

Understanding the SSE connection flow:

1. Browser loads the page (GET request creates a session)
2. Client runtime opens `EventSource` to `/sse`
3. Server associates the SSE stream with the session
4. Server pushes events through the stream (patches, signals, scripts, redirects)
5. Client applies patches via DOM morphing
6. If the connection drops, the client reconnects with exponential backoff

**Backoff schedule:** 1s → 2s → 4s → 8s → 16s → 30s (cap). Jitter prevents multiple tabs from reconnecting simultaneously. After 50 failed attempts, a manual reconnect button appears.

**Server keepalive:** The server sends an SSE comment (`: keepalive`) every 15 seconds to detect dead connections.

**Session expiry:** Sessions expire after `:session-ttl` seconds of inactivity. "Activity" means HTTP requests (page loads, action POSTs), not SSE keepalives. An idle tab with only an SSE connection will eventually have its session reaped.

---

## Thread Safety

All cell operations are thread-safe. The reactive graph is protected by a global recursive lock.

- Multiple threads can read and write cells concurrently
- `with-transaction` holds the lock for the entire batch
- Watchers triggered during writes can safely read other cells (recursive lock)
- The session store has its own lock, independent of the cell lock

**Pattern for background threads updating cells:**

```lisp
(bt:make-thread
 (lambda ()
   (loop
     (sleep 5)
     (fluxion.cells:with-transaction
       (setf (fluxion.cells:cell-value temperature-cell) (read-sensor))
       (setf (fluxion.cells:cell-value humidity-cell) (read-humidity))))))
```

Both cells update atomically. Computed cells that depend on them recompute once, in the correct order.

---

## Form Validation

Fluxion includes a validation DSL for server-side form validation:

```lisp
(let ((result (fluxion.validation:validate params
                :username (fluxion.validation:required)
                           (fluxion.validation:min-length 3)
                           (fluxion.validation:max-length 32)
                :email    (fluxion.validation:required)
                           (fluxion.validation:email)
                :role     (fluxion.validation:one-of '("admin" "user")))))
  (if (fluxion.validation:valid-p result)
      (handle-valid-form params)
      ;; Send error events that populate .fluxion-error spans
      (fluxion.validation:validation-error-events result)))
```

In your HTML, add `<span class="fluxion-error" data-field="username"></span>` next to each field. The validation error events automatically patch those spans with the error messages.

---

## Comparison with Other Frameworks

| Feature             | Fluxion             | LiveView  | Datastar        | HTMX             |
| ------------------- | ------------------- | --------- | --------------- | ---------------- |
| Language            | Common Lisp         | Elixir    | Go/Any          | Any              |
| Transport           | SSE                 | WebSocket | SSE             | AJAX/SSE/WS      |
| State location      | Server              | Server    | Server          | Client or server |
| Reactive engine     | Cells + propagators | Assigns   | Signals         | None (manual)    |
| Client JS required  | None                | None      | Minimal         | Attributes only  |
| Component model     | CLOS classes        | Modules   | HTML attributes | HTML fragments   |
| Glitch-free updates | Yes (transactions)  | No        | No              | N/A              |

Fluxion's differentiators for CL developers:

- **CLOS-native** — components are classes, actions are methods, the whole OOP toolkit applies
- **Lattice reactive engine** — cells, computed cells, propagators, and glitch-free transactions go beyond what other frameworks offer for state management
- **Thread-safe by default** — the cell graph handles concurrent access without any developer effort
- **Single-language stack** — server logic in CL, client runtime in Parenscript, zero JavaScript for application developers

---

## Load Testing

Run the built-in load test to verify performance:

```bash
sbcl --load tests/load-test.lisp
```

This exercises:

- Cell engine throughput (80K writes across 8 threads)
- Session management at scale (5K sessions, concurrent access, reaping)
- SSE event push (50K events to 500 sessions)
- Full HTTP stack (1,600 concurrent GET and POST requests)
- Memory stability (10 churn cycles checking for leaks)

---

## Observability

### Request Logging

Every request is logged to `*standard-output*` by default with method, path, status code, and elapsed time:

```text
[2026-04-22 19:32:10] GET / 200 2.3ms
[2026-04-22 19:32:10] POST /action/counter/increment 200 0.8ms
[2026-04-22 19:32:10] GET /health 200 0.1ms
[2026-04-22 19:32:11] GET /static/style.css 200 0.4ms
```

SSE streaming connections are not logged (they return a callback, not a status code). Disable logging with `:request-log nil`:

```lisp
(fluxion.server:make-fluxion-app :request-log nil)
```

### Health Endpoint

Every Fluxion app exposes `GET /health` with no session required. Useful for load balancer health checks and container orchestration:

```bash
curl http://localhost:5000/health
```

```json
{
  "status": "ok",
  "uptimeSeconds": 3661,
  "uptimeHuman": "0d 1h 1m 1s",
  "sessions": 42,
  "sseConnections": 38,
  "server": "woo",
  "port": 5000
}
```

### Programmatic Metrics

```lisp
(fluxion.server:app-uptime-seconds app)       ;=> 3661
(fluxion.server:app-session-count app)         ;=> 42
(fluxion.server:app-sse-connection-count app)  ;=> 38
```

These can be exposed to Prometheus, Grafana, or any monitoring system by adding a `/metrics` route.

---

## Middleware Patterns

Middleware wraps the Clack handler in an onion-style chain. Each middleware is a function that takes a handler and returns a new handler. Middleware runs in registration order (first = outermost).

### Authentication gate

```lisp
(defun api-key-middleware (handler)
  "Block requests without a valid API key header."
  (lambda (env)
    (let* ((headers (getf env :headers))
           (key (and headers (gethash "x-api-key" headers))))
      (if (valid-api-key-p key)
          (funcall handler env)
          (list 401 '(:content-type "text/plain") '("Invalid API key"))))))

(add-middleware app #'api-key-middleware :name :api-key)
```

### Request timing / metrics

```lisp
(defun metrics-middleware (handler)
  "Track request count and timing for monitoring."
  (let ((counter 0))
    (lambda (env)
      (let ((start (get-internal-real-time)))
        (incf counter)
        (let ((response (funcall handler env)))
          (record-metric :request-time
            (* 1000.0 (/ (- (get-internal-real-time) start)
                         (float internal-time-units-per-second))))
          response)))))
```

### Conditional middleware

Short-circuit selectively. Here only POST routes pass through the rate limiter:

```lisp
(add-middleware app
  (lambda (handler)
    (let ((limited (funcall (make-rate-limiter :requests-per-second 5) handler)))
      (lambda (env)
        (if (eq (getf env :request-method) :post)
            (funcall limited env)
            (funcall handler env)))))
  :name :post-limiter)
```

### Middleware ordering

Middleware applies in registration order. Typical ordering:

1. **CORS** (outermost - adds headers to all responses including errors)
2. **Request logger** (sees the final status code)
3. **Rate limiter** (rejects before any work is done)
4. **Custom auth** (runs after rate limiting passes)

```lisp
(add-middleware app (make-cors-middleware) :name :cors)
(add-middleware app (make-request-logger) :name :logger)
(add-middleware app (make-rate-limiter :requests-per-second 20) :name :limiter)
(add-middleware app #'my-auth-middleware :name :auth)
```

---

## Troubleshooting

**SSE connections drop immediately:** Check your reverse proxy config. nginx needs `proxy_buffering off` and a long `proxy_read_timeout`. Caddy works without changes.

**Session expired unexpectedly:** Only HTTP requests (GET/POST) touch the session timestamp. Idle SSE connections don't count as activity. Increase `:session-ttl` or have your client poll a heartbeat endpoint.

**CSRF 403 on POST:** Make sure you pass `:csrf-token` to `render-page`. The client reads the token from a `<meta name="fluxion-csrf">` tag.

**Component not updating:** If the slot is cell-backed, return `'()` from the action (not `nil`). `nil` means "auto-patch the component", which duplicates the cell watcher's patch. `'()` means "I returned an empty event list, do nothing" — the cell handles it.

**Computed cell not recomputing:** Dependencies are tracked by which cells are read during the compute function. If you read a cell conditionally, it won't be tracked on runs where the branch isn't taken. Keep compute functions deterministic in their reads.

**Woo won't start:** Install libev: `sudo apt install libev-dev`. Then `(ql:quickload "clack-handler-woo")`.

**Slider/input values not updating on morph:** The DOM `value` property diverges from the HTML `value` attribute after user interaction. Fluxion's morph syncs both the attribute and the property on non-focused inputs. If you see stale values, ensure you are using the latest `fluxion.js` build.
