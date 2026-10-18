#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT="$ROOT/build/job-lock-tests"
mkdir -p "$OUTPUT/module-cache"
xcrun clang -target arm64-apple-macosx14.0 -O2 -Wall -Wextra -Werror "$ROOT/Tests/JobLockBridgeTests.c" -lcups -o "$OUTPUT/JobLockBridgeTests"
"$OUTPUT/JobLockBridgeTests"
xcrun clang -target arm64-apple-macosx14.0 -O2 -Wall -Wextra -Werror -c "$ROOT/Tests/JobLockTestBridge.c" -o "$OUTPUT/JobLockTestBridge.o"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT/module-cache" -parse-as-library -D DRIVER_TESTS -import-objc-header "$ROOT/Tests/JobLockTestBridge.h" "$ROOT/Sources/native-driver/DriverJob.swift" "$ROOT/Sources/native-core/ColorCorrection.swift" "$ROOT/Tests/JobLockTests.swift" "$OUTPUT/JobLockTestBridge.o" -o "$OUTPUT/JobLockTests"
"$OUTPUT/JobLockTests" synthetic-never-read.pdf
