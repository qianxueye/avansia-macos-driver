#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="$repository/build/icon-tests"
mkdir -p "$output/cache"
xcrun swiftc -O -module-cache-path "$output/cache" "$repository/Tools/BuildIcons.swift" -o "$output/BuildIcons"
xcrun swiftc -O -module-cache-path "$output/cache" "$repository/Tests/IconTests.swift" -o "$output/IconTests"
"$output/IconTests" "$output/BuildIcons" > "$output/results.log"
cat "$output/results.log"
