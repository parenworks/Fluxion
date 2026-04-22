# Deploying Fluxion

This guide covers deploying a Fluxion application behind a reverse proxy. Fluxion uses Server-Sent Events (SSE) for persistent push connections, which requires specific proxy configuration to work correctly.

## Architecture

```text
Browser <---> Reverse Proxy (nginx/Caddy) <---> Fluxion (Hunchentoot on port 5000)
                  |
             TLS termination
             Static caching
             SSE passthrough
```

The reverse proxy handles TLS, serves cached static files, and forwards requests to Hunchentoot. The critical thing is that SSE connections on `/sse` must be passed through without buffering.

## Building for Production

```lisp
;; Load and start your app
(ql:quickload :my-fluxion-app)
(my-app:start :port 5000)
```

For a standalone binary, use SBCL's `save-lisp-and-die`:

```lisp
(sb-ext:save-lisp-and-die "my-app"
  :toplevel (lambda ()
              (my-app:start :port 5000)
              (loop (sleep 3600)))
  :executable t)
```

Run it as a systemd service (see below).

## Caddy

Caddy is the simplest option. It handles TLS automatically via Let's Encrypt and has sane defaults for proxying.

### Caddyfile

```caddy
myapp.example.com {
    reverse_proxy localhost:5000

    # Static files - let Caddy cache them
    @static path /static/*
    handle @static {
        reverse_proxy localhost:5000
        header Cache-Control "public, max-age=31536000, immutable"
    }
}
```

Caddy proxies SSE correctly out of the box with no extra configuration. It does not buffer streaming responses by default, so `/sse` connections work immediately.

### With explicit flush control

If you want to be explicit about SSE handling:

```caddy
myapp.example.com {
    reverse_proxy localhost:5000 {
        flush_interval -1
    }

    @static path /static/*
    handle @static {
        reverse_proxy localhost:5000
        header Cache-Control "public, max-age=31536000, immutable"
    }
}
```

`flush_interval -1` tells Caddy to flush response bytes immediately (streaming mode). This is already the default for responses with `Content-Type: text/event-stream`, but setting it explicitly covers all cases.

### Caddy as a systemd service

Caddy installs its own systemd unit if you use the package manager. Otherwise:

```ini
[Unit]
Description=Caddy
After=network.target

[Service]
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## nginx

nginx requires explicit SSE configuration because it buffers proxy responses by default.

### Site config

```nginx
upstream fluxion {
    server 127.0.0.1:5000;
    keepalive 64;
}

server {
    listen 443 ssl http2;
    server_name myapp.example.com;

    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;

    # Static files
    location /static/ {
        proxy_pass http://fluxion;
        expires max;
        add_header Cache-Control "public, immutable";
    }

    # SSE endpoint - must disable buffering
    location /sse {
        proxy_pass http://fluxion;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Critical for SSE
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        # Do not gzip SSE
        gzip off;
    }

    # Everything else
    location / {
        proxy_pass http://fluxion;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name myapp.example.com;
    return 301 https://$host$request_uri;
}
```

### Key SSE settings explained

- **`proxy_buffering off`** - nginx buffers proxy responses by default. SSE events will be held until the buffer fills, which means the browser sees nothing for long periods. This must be off for `/sse`.
- **`proxy_cache off`** - SSE responses must not be cached.
- **`proxy_read_timeout 86400s`** - the SSE connection is long-lived. Without this, nginx closes it after 60 seconds. Set to 24 hours.
- **`proxy_http_version 1.1` + `Connection ""`** - use HTTP/1.1 with persistent upstream connections. Required for keepalive to the Hunchentoot backend.
- **`gzip off`** - gzip buffering breaks SSE streaming. The events are small so compression gains are negligible.

## systemd Service

Run your Fluxion app as a managed service:

```ini
[Unit]
Description=Fluxion App
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/myapp
ExecStart=/opt/myapp/my-app
Restart=always
RestartSec=5
Environment=HOME=/opt/myapp

[Install]
WantedBy=multi-user.target
```

```bash
sudo cp myapp.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable myapp
sudo systemctl start myapp
```

## Session Configuration

For production, tune session settings:

```lisp
(fluxion.server:make-fluxion-app
 :port 5000
 :session-ttl 3600        ; 1 hour idle timeout
 :reaper-interval 60      ; check every minute
 :static-dir "/opt/myapp/static/")
```

The session reaper runs in a background thread and removes expired sessions automatically.

## Checklist

- [ ] Build the client runtime: `(fluxion.client:build-client)`
- [ ] Set appropriate `:session-ttl` for your use case
- [ ] Pass `:csrf-token` to `render-page` in all page handlers
- [ ] Reverse proxy disables buffering for `/sse`
- [ ] Reverse proxy sets a long read timeout for `/sse`
- [ ] Static files served with cache headers
- [ ] TLS configured (Let's Encrypt or your own certs)
- [ ] Application runs as a systemd service with `Restart=always`
- [ ] Test SSE by opening the browser console and checking for `EventSource` connection

## Troubleshooting

### SSE events not arriving

1. Check that `proxy_buffering off` is set for `/sse` in nginx. Caddy does not have this problem.
2. Check that `proxy_read_timeout` is long enough. A 60s timeout will kill the SSE connection silently.
3. Look at the browser's Network tab. The `/sse` request should show as "pending" with `Content-Type: text/event-stream`.

### Session cookie not set

The session cookie is `HttpOnly` and `SameSite=Lax`. If your proxy rewrites the origin, make sure the `Host` header is forwarded correctly.

### CSRF token mismatch after deploy

If you restart the server, all in-memory sessions are lost. Clients with stale session cookies will get new sessions with new CSRF tokens, but their page still has the old token in the meta tag. The next POST will fail with 403. The client should detect this and reload the page. For a smoother experience, consider a full page reload on 403 in your error handler.

### High memory with many SSE connections

Each SSE connection holds an event queue. If you have many concurrent users, tune `:session-ttl` lower and make sure the reaper interval is reasonable. Idle SSE connections are cleaned up when their session expires.
