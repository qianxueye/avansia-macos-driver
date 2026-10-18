#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT="$ROOT/build/print-safety-tests"
mkdir -p "$OUTPUT/module-cache"
xcrun clang -target arm64-apple-macosx14.0 -O2 -Wall -Wextra -Werror -c "$ROOT/Sources/native-driver/NativeBridge.c" -o "$OUTPUT/NativeBridge.o"
xcrun swiftc -O -disable-sandbox -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT/module-cache" -parse-as-library -D CORE_TESTS -import-objc-header "$ROOT/Sources/native-core/Bridge.h" "$ROOT"/Sources/native-core/*.swift "$ROOT/Tests/PrintSafetyTests.swift" "$OUTPUT/NativeBridge.o" -lcups -o "$OUTPUT/PrintSafetyTests"
LOG="$OUTPUT/test-results.log"
if "$OUTPUT/PrintSafetyTests" > "$LOG" 2>&1; then
    cat "$LOG"
else
    cat "$LOG"
    exit 1
fi
