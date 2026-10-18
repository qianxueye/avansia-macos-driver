#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
engine="$repository/build/ipp/cups-2.4.14/tools/ippeveprinter-static"
port=${IPP_TEST_PORT:-18639}
temporary=$(mktemp -d "${TMPDIR:-/private/tmp}/avansia-ipp-test.XXXXXX")
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary"
}
trap cleanup EXIT INT TERM
mkdir -m 700 "$temporary/spool" "$temporary/keys"
printf 'AVANSIA_STATUS_V1 ready 90 80\n' > "$temporary/value"
cat > "$temporary/status" <<'HELPER'
#!/bin/sh
[ "$#" = 1 ] && [ "$1" = ipp-status ] || exit 2
folder=$(dirname "$0")
printf x >> "$folder/calls"
cat "$folder/value"
HELPER
chmod 700 "$temporary/status"
cat > "$temporary/query.test" <<'IPP'
{
  NAME "Synthetic live-status response"
  OPERATION Get-Printer-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR language attributes-natural-language en
  ATTR uri printer-uri $uri
  ATTR keyword requested-attributes marker-levels,avansia-connection-state,printer-state,printer-supply
  STATUS successful-ok
}
IPP
"$engine" -n localhost -p "$port" -r off --no-web-forms \
    --status-command "$temporary/status" -a "$repository/Sources/cups/avansia.conf" \
    -f application/pdf -c /usr/bin/true -d "$temporary/spool" -K "$temporary/keys" \
    'Synthetic Avansia Status Test' > "$temporary/server.log" 2>&1 &
server_pid=$!
wait_for_levels() {
    desired=$1
    attempts=0
    while [ "$attempts" -lt 22 ]; do
        kill -0 "$server_pid"
        if /usr/bin/ipptool -tv "ipp://localhost:$port/ipp/print" "$temporary/query.test" > "$temporary/response" 2>&1; then
            if grep -F "marker-levels (1setOf integer) = $desired" "$temporary/response" >/dev/null; then
                return
            fi
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    cat "$temporary/server.log" "$temporary/response" >&2
    echo "Live status did not reach $desired without restarting the engine." >&2
    exit 1
}
wait_for_levels '90,80'
printf 'AVANSIA_STATUS_V1 ready 0 -1\n' > "$temporary/value"
wait_for_levels '0,-1'
grep -F 'avansia-connection-state (keyword) = ready' "$temporary/response" >/dev/null
grep -F 'level=0;' "$temporary/response" >/dev/null
grep -F 'level=-1;' "$temporary/response" >/dev/null
calls=$(wc -c < "$temporary/calls" | tr -d ' ')
[ "$calls" -eq 2 ]
printf 'PASS: live IPP levels changed 90,80 -> 0,-1 over two periodic probes without restart or hardware.\n'
