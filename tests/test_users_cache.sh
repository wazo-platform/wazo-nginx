#!/bin/bash
# Checks the confd users cache on the internal entry (127.0.0.1:80) with the
# real sites-available/wazo and http-available/wazo-confd files, in a throwaway
# container without network. The stub confd (9486) and the stub auth (9497) are
# extra nginx servers in the same container.
# Needs docker.
# Usage: tests/test_users_cache.sh [nginx-image]
set -u

IMAGE=${1:-nginx:latest}
HERE=$(cd "$(dirname "$0")/.." && pwd)
SITE="$HERE/etc/nginx/sites-available/wazo"
CONFD_LOCATION="$HERE/etc/nginx/locations/http-available/wazo-confd"
NAME=wazo-confd-cache-test
failures=0

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
    log_format stub '$request_method $request_uri $http_wazo_tenant';
    include /etc/nginx/sites-enabled/*;

    # stub confd: each request gets a new id, and is logged
    server {
        listen 127.0.0.1:9486;
        access_log /tmp/confd.log stub;
        default_type application/json;
        return 200 '{"id": "$request_id", "script": "$http_x_script_name"}';
    }
    # stub auth, behind the same kind of location as wazo-auth
    server {
        listen 127.0.0.1:9497;
        default_type application/json;
        return 200 '{"auth": "ok"}';
    }
}
CONF

cat > "$WORK/wazo-auth" <<'CONF'
location ^~ /api/auth/ {
    proxy_pass http://127.0.0.1:9497/;
}
CONF

mkdir "$WORK/https-enabled" "$WORK/http-enabled"
cp "$WORK/wazo-auth" "$WORK/http-enabled/wazo-auth"
# a missing file must fail the checks, not make docker create a directory
[ -f "$CONFD_LOCATION" ] && cp "$CONFD_LOCATION" "$WORK/http-enabled/wazo-confd"

docker run -d --name "$NAME" --network none \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$SITE:/etc/nginx/sites-enabled/wazo:ro" \
    -v "$WORK/http-enabled:/etc/nginx/locations/http-enabled:ro" \
    -v "$WORK/https-enabled:/etc/nginx/locations/https-enabled:ro" \
    --entrypoint sh "$IMAGE" -c '
        mkdir -p /usr/share/wazo-certs /var/www/html
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test \
            -keyout /usr/share/wazo-certs/server.key \
            -out /usr/share/wazo-certs/server.crt 2>/dev/null
        exec nginx -g "daemon off;"' >/dev/null
sleep 3

in_container() { docker exec "$NAME" "$@"; }
stub_hits() { in_container sh -c 'wc -l < /tmp/confd.log' | tr -d ' '; }

check "nginx config is valid" "$(in_container nginx -t >/dev/null 2>&1; echo $?)" 0

BASE=http://127.0.0.1/api/confd
# prints "<X-Cache-Status> <response id>"
get() {  # tenant token url
    local out
    out=$(in_container curl -s -D - -H "Wazo-Tenant: $1" -H "X-Auth-Token: $2" "$3" | tr -d '\r')
    echo "$(echo "$out" | sed -n 's/^x-cache-status: //Ip' | head -1) $(echo "$out" | sed -n 's/.*"id": "\([0-9a-f]*\)".*/\1/p')"
}
status() { echo "${1%% *}"; }
id() { echo "${1##* }"; }

LISTING='/1.1/users?view=directory&recurse=True&order=firstname&offset=0'

r1=$(get t1 tokA "$BASE$LISTING")
check "first listing is a MISS" "$(status "$r1")" MISS
r2=$(get t1 tokA "$BASE$LISTING")
check "second listing is a HIT" "$(status "$r2")" HIT
check "a HIT returns the cached body" "$(id "$r2")" "$(id "$r1")"
check "confd was asked once" "$(stub_hits)" 1
check "confd got the path without the prefix and the query" \
    "$(in_container head -1 /tmp/confd.log)" "GET $LISTING t1"

check "another token shares the entry" "$(status "$(get t1 tokB "$BASE$LISTING")")" HIT
check "another tenant does not share it" "$(status "$(get t2 tokA "$BASE$LISTING")")" MISS

check "a search is a MISS" "$(status "$(get t1 tokA "$BASE/1.1/users?search=1001")")" MISS
check "the same search is a HIT" "$(status "$(get t1 tokA "$BASE/1.1/users?search=1001")")" HIT
check "another search is a MISS" "$(status "$(get t1 tokA "$BASE/1.1/users?search=1002")")" MISS

before=$(stub_hits)
check "uuid filter bypasses the cache" "$(status "$(get t1 tokA "$BASE/1.1/users?uuid=a,b")")" BYPASS
check "uuid filter is not stored" "$(status "$(get t1 tokA "$BASE/1.1/users?uuid=a,b")")" BYPASS
check "uuid filter reaches confd each time" "$(( $(stub_hits) - before ))" 2

before=$(stub_hits)
get t1 tokA "$BASE/1.1/users/42" >/dev/null
get t1 tokA "$BASE/1.1/users/42" >/dev/null
check "other confd paths reach confd each time" "$(( $(stub_hits) - before ))" 2
check "other confd paths have no cache header" "$(get t1 tokA "$BASE/1.1/infos" | cut -d' ' -f1)" ""
check "other confd paths keep the script name header" \
    "$(in_container curl -s "$BASE/1.1/infos" | sed -n 's/.*"script": "\([^"]*\)".*/\1/p')" /api/confd

before=$(stub_hits)
in_container curl -s -X POST -H 'Wazo-Tenant: t1' "$BASE$LISTING" >/dev/null
check "POST reaches confd" "$(( $(stub_hits) - before ))" 1

check "localhost resolves and is served" \
    "$(status "$(get t1 tokA "http://localhost/api/confd$LISTING")")" HIT
check "the ::1 entry is served" "$(status "$(get t1 tokA "http://[::1]/api/confd$LISTING")")" HIT

check "wazo-auth internal location still works" \
    "$(in_container curl -s http://127.0.0.1/api/auth/0.1/status)" '{"auth": "ok"}'

# the public vhosts never reach the http locations
check "wildcard :80 redirects and has no confd location" \
    "$(in_container curl -s -o /dev/null -w '%{http_code}' -H 'Host: wazo.example' http://127.0.0.2/api/confd/1.1/infos)" 301
check "https vhost has no confd location here" \
    "$(in_container curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.2/api/confd/1.1/infos)" 404

[ "$failures" -eq 0 ] && echo "all checks passed" || echo "$failures check(s) failed"
exit "$failures"
