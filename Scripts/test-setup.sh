#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT="$ROOT/build/setup-tests"
mkdir -p "$OUTPUT/module-cache"
xcrun swiftc -disable-sandbox -module-cache-path "$OUTPUT/module-cache" -target arm64-apple-macosx14.0 -D SETUP_TESTS -parse-as-library -import-objc-header "$ROOT/Sources/native-driver/NativeBridge.h" "$ROOT/Sources/native-driver/Setup.swift" "$ROOT/Sources/native-driver/RuntimeAssets.swift" "$ROOT/Tests/SetupTests.swift" -o "$OUTPUT/SetupTests"
"$OUTPUT/SetupTests"
