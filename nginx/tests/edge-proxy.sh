#!/bin/sh
# Verify the web tier: the real frontend image (read-only, as Compose and
# Kubernetes run it) behind the real edge image, with a stub backend.
#
# The frontend is checked directly on its published port (SPA fallback, asset
# caching, 404 for missing assets, headers, no API) and through the edge (SPA
# proxying, API and Socket.IO routing, header pass-through, one HSTS header).
#
#   sh nginx/tests/edge-proxy.sh <frontend-image> <edge-image>
set -eu

frontend_image="${1:?usage: edge-proxy.sh <frontend-image> <edge-image>}"
edge_image="${2:?usage: edge-proxy.sh <frontend-image> <edge-image>}"
suffix="$$-$(date +%s)"
network="mtm-web-test-$suffix"
front="mtm-web-front-$suffix"
back="mtm-web-back-$suffix"
edge="mtm-web-edge-$suffix"
tmp="$(mktemp -d)"

cleanup() {
    docker rm -f "$edge" "$front" "$back" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

stub_image="nginx:alpine@sha256:713fc2ebfd92e8217db451477182ee91944b123d2b1ee9fd5a8c6e91ca6c3a11"
mkdir -p "$tmp/backend/api" "$tmp/certs"
printf '{"status":"ok"}\n' > "$tmp/backend/api/health"
printf 'server { listen 3001; root /www; }\n' > "$tmp/back.conf"

docker network create "$network" >/dev/null

# The real frontend, with the Compose/Kubernetes hardening: non-root image,
# read-only root filesystem, /tmp on a temporary mount.
docker run -d --rm --name "$front" --network "$network" --network-alias frontend \
    --read-only --tmpfs /tmp -p "127.0.0.1::8080" "$frontend_image" >/dev/null
frontport="$(docker port "$front" 8080/tcp | head -1 | sed 's/.*://')"
if [ -z "$frontport" ]; then
    echo "could not find the published frontend port" >&2
    exit 1
fi
frontbase="http://127.0.0.1:$frontport"

docker run -d --rm --name "$back" --network "$network" --network-alias backend \
    -v "$tmp/backend:/www:ro" -v "$tmp/back.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$stub_image" >/dev/null

wait_for_url() {
    url=$1
    i=0
    while [ "$i" -lt 30 ]; do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "timed out waiting for $url" >&2
    return 1
}
wait_for_exec() {
    container=$1 url=$2
    i=0
    while [ "$i" -lt 30 ]; do
        if docker exec "$container" wget -qO- "$url" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "stub $container did not become ready" >&2
    docker logs "$container" >&2 2>&1 || true
    return 1
}
wait_for_url "$frontbase/health"
wait_for_exec "$back" http://127.0.0.1:3001/api/health

# TLS_MODE=proxy serves the app over HTTP on port 80, which is what the edge
# does when another proxy terminates TLS.
docker run -d --rm --name "$edge" --network "$network" \
    -e TLS_MODE=proxy -v "$tmp/certs:/certs" -p "127.0.0.1::80" \
    "$edge_image" >/dev/null
edgeport="$(docker port "$edge" 80/tcp | head -1 | sed 's/.*://')"
if [ -z "$edgeport" ]; then
    echo "could not find the published edge port" >&2
    exit 1
fi
base="http://127.0.0.1:$edgeport"
if ! wait_for_url "$base/"; then
    docker logs "$edge" >&2 2>&1 || true
    exit 1
fi

fail=0
ok() { echo "ok - $1"; }
no() { echo "not ok - $1" >&2; fail=1; }
status_of() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
header_of() {
    curl -sS -D - -o /dev/null "$1" | tr -d '\r' |
        awk -F': ' -v h="$2" 'tolower($1)==tolower(h){print substr($0, index($0,": ")+2); exit}'
}
expect_status() {
    desc=$1 want=$2 url=$3
    got="$(status_of "$url")"
    if [ "$got" = "$want" ]; then ok "$desc"; else no "$desc (got $got, want $want)"; fi
}
expect_header() {
    desc=$1 url=$2 header=$3 pattern=$4
    got="$(header_of "$url" "$header")"
    if printf '%s' "$got" | grep -qi -- "$pattern"; then
        ok "$desc"
    else
        no "$desc (got '$got')"
    fi
}

# ── The frontend image itself ────────────────────────────────────────────────
expect_status "frontend root is 200" 200 "$frontbase/"
if curl -fsS "$frontbase/" | grep -q '<div id="root">'; then
    ok "frontend mounts the SPA"
else
    no "frontend mounts the SPA"
fi
expect_status "frontend SPA deep link" 200 "$frontbase/devices/42"
expect_status "frontend health endpoint" 200 "$frontbase/health"

asset="$(curl -fsS "$frontbase/" | sed -n 's/.*src="\(\/assets\/[^"]*\.js\)".*/\1/p' | head -1)"
if [ -n "$asset" ]; then
    ok "frontend has a hashed JS asset"
    expect_status "frontend asset is 200" 200 "$frontbase$asset"
    expect_header "frontend asset is JavaScript" "$frontbase$asset" content-type 'javascript'
    expect_header "frontend asset is immutable" "$frontbase$asset" cache-control 'immutable'
    gzip_header="$(curl -sS -D - -o /dev/null -H 'Accept-Encoding: gzip' "$frontbase$asset" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-encoding"{print $2; exit}')"
    if printf '%s' "$gzip_header" | grep -qi gzip; then
        ok "frontend asset is compressed"
    else
        no "frontend asset is compressed (got '$gzip_header')"
    fi
else
    no "frontend has a hashed JS asset"
fi
expect_status "frontend missing asset is 404" 404 "$frontbase/assets/does-not-exist.js"
if curl -sS "$frontbase/assets/does-not-exist.js" | grep -q '<div id="root">'; then
    no "frontend missing asset is not index.html"
else
    ok "frontend missing asset is not index.html"
fi
if header_of "$frontbase/assets/does-not-exist.js" cache-control | grep -qi immutable; then
    no "frontend missing asset is not immutable"
else
    ok "frontend missing asset is not immutable"
fi
expect_status "frontend refuses the API" 404 "$frontbase/api/health"
expect_header "frontend CSP is set" "$frontbase/" content-security-policy "frame-ancestors 'none'"
expect_header "frontend X-Frame-Options is DENY" "$frontbase/" x-frame-options 'DENY'
expect_header "frontend X-Content-Type-Options is nosniff" "$frontbase/" x-content-type-options 'nosniff'
expect_header "frontend HSTS is set" "$frontbase/" strict-transport-security 'max-age=31536000'

# ── The edge in front of it ──────────────────────────────────────────────────
if curl -fsS "$base/" | grep -q '<div id="root">'; then
    ok "edge proxies the SPA"
else
    no "edge proxies the SPA"
fi
expect_status "edge SPA deep link" 200 "$base/devices/42"
if curl -fsS "$base/api/health" | grep -q '"status":"ok"'; then
    ok "edge sends /api to the backend"
else
    no "edge sends /api to the backend"
fi
if curl -sS "$base/socket.io/" | grep -q '<div id="root">'; then
    no "edge does not send /socket.io to the SPA"
else
    ok "edge does not send /socket.io to the SPA"
fi
expect_status "edge missing asset stays 404" 404 "$base/assets/does-not-exist.js"
expect_header "edge passes the frontend CSP through" "$base/" content-security-policy "frame-ancestors 'none'"

# The frontend and API each set HSTS; the edge must not add a second one.
hsts_count="$(curl -sS -D - -o /dev/null "$base/" | tr -d '\r' | grep -ci '^strict-transport-security:')"
if [ "$hsts_count" = 1 ]; then
    ok "exactly one HSTS header through the edge"
else
    no "exactly one HSTS header through the edge (got $hsts_count)"
fi
api_csp="$(header_of "$base/api/health" content-security-policy)"
if [ -z "$api_csp" ]; then
    ok "edge adds no CSP to API responses"
else
    no "edge adds no CSP to API responses (got '$api_csp')"
fi

if [ "$fail" -ne 0 ]; then
    echo "web-tier checks failed" >&2
    exit 1
fi
echo "web-tier checks passed"
