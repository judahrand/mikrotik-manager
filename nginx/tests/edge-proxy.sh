#!/bin/sh
# Verify the edge image routes the SPA, the API and Socket.IO to the right
# places, without building the real frontend or backend. Two busybox stubs stand
# in on a throwaway Docker network.
#
#   sh nginx/tests/edge-proxy.sh <edge-image>
set -eu

edge_image="${1:?usage: edge-proxy.sh <edge-image>}"
suffix="$$-$(date +%s)"
network="mtm-edge-test-$suffix"
front="mtm-edge-front-$suffix"
back="mtm-edge-back-$suffix"
edge="mtm-edge-$suffix"
tmp="$(mktemp -d)"

cleanup() {
    docker rm -f "$edge" "$front" "$back" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# A plain static server is enough for the stubs: the real frontend image test
# covers SPA fallback; this one only proves the edge sends / where it should.
stub_image="nginx:alpine@sha256:713fc2ebfd92e8217db451477182ee91944b123d2b1ee9fd5a8c6e91ca6c3a11"
mkdir -p "$tmp/frontend" "$tmp/backend/api" "$tmp/certs"
printf '<div id="root">stub-frontend</div>\n' > "$tmp/frontend/index.html"
printf '{"status":"ok"}\n' > "$tmp/backend/api/health"
printf 'server { listen 8080; root /www; }\n' > "$tmp/front.conf"
printf 'server { listen 3001; root /www; }\n' > "$tmp/back.conf"

docker network create "$network" >/dev/null

docker run -d --rm --name "$front" --network "$network" --network-alias frontend \
    -v "$tmp/frontend:/www:ro" -v "$tmp/front.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$stub_image" >/dev/null
docker run -d --rm --name "$back" --network "$network" --network-alias backend \
    -v "$tmp/backend:/www:ro" -v "$tmp/back.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$stub_image" >/dev/null

# nginx resolves both upstreams when it starts, so wait for the stubs first.
wait_for_stub() {
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
wait_for_stub "$front" http://127.0.0.1:8080/
wait_for_stub "$back" http://127.0.0.1:3001/api/health

# TLS_MODE=proxy serves the app over HTTP on port 80, which is what the edge
# does when a Gateway or another proxy terminates TLS. ACME stays off because
# no domain is configured.
docker run -d --rm --name "$edge" --network "$network" \
    -e TLS_MODE=proxy -v "$tmp/certs:/certs" -p "127.0.0.1::80" \
    "$edge_image" >/dev/null
hostport="$(docker port "$edge" 80/tcp | head -1 | sed 's/.*://')"
if [ -z "$hostport" ]; then
    echo "could not find the published edge port" >&2
    exit 1
fi
base="http://127.0.0.1:$hostport"

ready=0
i=0
while [ "$i" -lt 30 ]; do
    if curl -fsS "$base/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "edge did not become ready:" >&2
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

if curl -fsS "$base/" | grep -q stub-frontend; then
    ok "/ is proxied to the frontend"
else
    no "/ is proxied to the frontend"
fi

if curl -fsS "$base/api/health" | grep -q '"status":"ok"'; then
    ok "/api is proxied to the backend"
else
    no "/api is proxied to the backend"
fi

hsts="$(header_of "$base/" strict-transport-security)"
if printf '%s' "$hsts" | grep -qi 'max-age=31536000'; then
    ok "HSTS is set at the edge"
else
    no "HSTS is set at the edge"
fi

# The frontend stub does not know /dashboard, so a 404 proves the edge did not
# rewrite it to index.html (the frontend image owns that fallback).
code="$(status_of "$base/dashboard")"
if [ "$code" = 404 ]; then
    ok "SPA routes are passed through unchanged"
else
    no "SPA routes are passed through unchanged (got $code)"
fi

code="$(status_of "$base/assets/does-not-exist.js")"
if [ "$code" = 404 ]; then
    ok "missing assets keep their 404"
else
    no "missing assets keep their 404 (got $code)"
fi

if curl -sS "$base/socket.io/" | grep -q stub-frontend; then
    no "/socket.io is not the SPA"
else
    ok "/socket.io is not the SPA"
fi

if [ "$fail" -ne 0 ]; then
    echo "edge image checks failed" >&2
    exit 1
fi
echo "edge image checks passed"
