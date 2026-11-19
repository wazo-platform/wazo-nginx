#!/bin/bash
# Checks the confd users cache listener against a stub confd, all inside one
# throwaway nginx container (the stub is a second nginx server on 9486).
# Needs docker.
# Usage: tests/test_users_cache.sh [nginx-image]
set -u

IMAGE=${1:-nginx:latest}
HERE=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="$HERE/etc/nginx/sites-available/wazo-confd-cache"
NAME=wazo-confd-cache-test
LISTENER=127.0.0.1:9487
failures=0

# docker would create a directory for a missing mount source
[ -f "$CONFIG" ] || { echo "FAIL - missing $CONFIG"; exit 1; }

WORK=$(mktemp -d)
cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (expected '$3', got '$2')"
        failures=$((failures + 1))
    fi
}

cat > "$WORK/nginx.conf" <<'CONF'
user nginx;
events {}
http {
    # defined in sites-available/wazo on a real stack
    log_format main '$remote_addr $status';
    log_format stub '$request_method $request_uri';
    include /etc/nginx/sites-enabled/*;

    # stub confd: each request gets a new id, and is logged
    server {
        listen 127.0.0.1:9486;
        access_log /tmp/stub.log stub;
        default_type application/json;
        return 200 '{"id": "$request_id"}';
    }
}
CONF

docker run -d --name "$NAME" --network host \
    -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$CONFIG:/etc/nginx/sites-enabled/wazo-confd-cache:ro" \
    "$IMAGE" >/dev/null
sleep 3

in_container() { docker exec "$NAME" "$@"; }
stub_hits() { in_container sh -c 'wc -l < /tmp/stub.log' | tr -d ' '; }

check "nginx config is valid" "$(in_container nginx -t >/dev/null 2>&1; echo $?)" 0

# prints "<X-Cache-Status> <response id>"
get() {  # tenant token path
    local out
    out=$(in_container curl -s -D - -H "Wazo-Tenant: $1" -H "X-Auth-Token: $2" "http://$LISTENER$3" | tr -d '\r')
    echo "$(echo "$out" | sed -n 's/^x-cache-status: //Ip' | head -1) $(echo "$out" | sed -n 's/.*"id": "\([0-9a-f]*\)".*/\1/p')"
}
status() { echo "${1%% *}"; }
id() { echo "${1##* }"; }

LISTING='/1.1/users?view=directory&recurse=True&order=firstname&offset=0'

r1=$(get t1 tokA "$LISTING")
check "first listing is a MISS" "$(status "$r1")" MISS
r2=$(get t1 tokA "$LISTING")
check "second listing is a HIT" "$(status "$r2")" HIT
check "a HIT returns the cached body" "$(id "$r2")" "$(id "$r1")"
check "confd was asked once" "$(stub_hits)" 1

r3=$(get t1 tokB "$LISTING")
check "another token shares the entry" "$(status "$r3")" HIT
r4=$(get t2 tokA "$LISTING")
check "another tenant does not share it" "$(status "$r4")" MISS

check "a search is a MISS" "$(status "$(get t1 tokA '/1.1/users?search=1001')")" MISS
check "the same search is a HIT" "$(status "$(get t1 tokA '/1.1/users?search=1001')")" HIT
check "another search is a MISS" "$(status "$(get t1 tokA '/1.1/users?search=1002')")" MISS

before=$(stub_hits)
check "uuid filter bypasses the cache" "$(status "$(get t1 tokA '/1.1/users?uuid=a,b')")" BYPASS
check "uuid filter is not stored" "$(status "$(get t1 tokA '/1.1/users?uuid=a,b')")" BYPASS
check "uuid filter reaches confd each time" "$(( $(stub_hits) - before ))" 2

before=$(stub_hits)
get t1 tokA '/1.1/users/42' >/dev/null
get t1 tokA '/1.1/users/42' >/dev/null
check "other paths reach confd each time" "$(( $(stub_hits) - before ))" 2
check "other paths have no cache header" "$(get t1 tokA '/1.1/infos' | cut -d' ' -f1)" ""

before=$(stub_hits)
in_container curl -s -X POST -H 'Wazo-Tenant: t1' "http://$LISTENER$LISTING" >/dev/null
check "POST reaches confd" "$(( $(stub_hits) - before ))" 1

# LISTEN sockets (state 0A); 0x250F is port 9487, 0100007F is 127.0.0.1
check "listener on loopback" "$(in_container grep -c '0100007F:250F 00000000:0000 0A' /proc/net/tcp)" 1
check "no listener on all addresses" "$(in_container grep -c '00000000:250F 00000000:0000 0A' /proc/net/tcp)" 0

[ "$failures" -eq 0 ] && echo "all checks passed" || echo "$failures check(s) failed"
exit "$failures"
