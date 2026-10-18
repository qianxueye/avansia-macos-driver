#!/bin/sh
set -eu
export CUPS_SERVER=/private/var/run/cupsd
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
RUN=$(mktemp -d "${TMPDIR:-/private/tmp/}avansia-raster-tests.XXXXXX")
RUN=$(CDPATH= cd -- "$RUN" && pwd -P)
cleanup() {
    if [ -f "$RUN/test-queue-name" ]; then
        queue=$(cat "$RUN/test-queue-name")
        case "$queue" in Avansia_Raster_Test_[0-9]*) /usr/sbin/lpadmin -h /private/var/run/cupsd -x "$queue" >/dev/null 2>&1 || : ;; esac
    fi
    if [ -f "$RUN/test-server-pid" ]; then
        server_pid=$(cat "$RUN/test-server-pid")
        command=$(ps -p "$server_pid" -o command= 2>/dev/null || :)
        case "$command" in *"$RUN/cases/test-printer.conf"*) kill -TERM "$server_pid" 2>/dev/null || : ;; esac
    fi
    rm -rf "$RUN"
}
trap cleanup EXIT HUP INT TERM
swiftc -O -module-cache-path "$RUN/module-cache" "$ROOT/Sources/cups/CardRaster.swift" -o "$RUN/CardRaster"
swiftc -O -module-cache-path "$RUN/module-cache" "$ROOT/Tests/RasterTests.swift" -o "$RUN/RasterTests"
swiftc -O -module-cache-path "$RUN/module-cache" "$ROOT/Tests/RasterCapture.swift" -o "$RUN/RasterCapture"
"$RUN/RasterTests" "$RUN/CardRaster" "$RUN/cases" "$RUN/RasterCapture" "$ROOT/build/ipp-runtime/bin/ippeveprinter" "$ROOT/Sources/cups/avansia.conf"
