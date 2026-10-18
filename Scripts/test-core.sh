#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/avansia-core-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun clang -O2 -Wall -Wextra -Werror -c Sources/native-driver/NativeBridge.c -o "$test_dir/NativeBridge.o"
xcrun swiftc -O -parse-as-library -D CORE_TESTS -module-cache-path "$test_dir/cache" -import-objc-header Sources/native-core/Bridge.h Sources/native-core/*.swift Tests/CoreTests.swift "$test_dir/NativeBridge.o" -lcups -o "$test_dir/CoreTests"
"$test_dir/CoreTests"
xcrun swiftc -O -parse-as-library -module-cache-path "$test_dir/cache" -import-objc-header Sources/native-core/Bridge.h Sources/native-core/*.swift "$test_dir/NativeBridge.o" -lcups -o "$test_dir/AvansiaCore"
"$test_dir/AvansiaCore" self-test

status_line=$("$test_dir/AvansiaCore" ipp-status --invalid-test-option)
[ "$status_line" = 'AVANSIA_STATUS_V1 unknown -1 -1' ]
