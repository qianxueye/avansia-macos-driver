#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
mkdir -p build/asset-tests/cache
xcrun swiftc -disable-sandbox -module-cache-path build/asset-tests/cache -O \
    -target arm64-apple-macosx14.0 -parse-as-library -D ASSET_TESTS \
    Sources/native-driver/RuntimeAssets.swift Tests/AssetTests.swift -o build/asset-tests/AssetTests
build/asset-tests/AssetTests "$@" > build/asset-tests/results.log
cat build/asset-tests/results.log
