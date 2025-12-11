# Build with Go 1.25+ to satisfy Cloudflare module
FROM golang:1.25 AS builder

# Install xcaddy
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

# Build Caddy pinned to v2.7.6, with Cloudflare DNS module pinned to v0.2.1
RUN xcaddy build \
    --with github.com/caddyserver/caddy/v2@v2.7.6 \
    --with github.com/caddy-dns/cloudflare@v0.2.1

# Final minimal runtime image
FROM caddy:2.7

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
