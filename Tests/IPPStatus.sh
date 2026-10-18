#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source="$repository/build/ipp/cups-2.4.14"
mkdir -p "$repository/build/tests"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=14.0 -D_CUPS_SOURCE \
    -I"$source" -Wno-deprecated-declarations "$repository/Tests/IPPLiveStatus.c" \
    "$source/cups/libcups.a" -lpthread -lresolv -framework SystemConfiguration \
    -framework CoreFoundation -framework Security -liconv -lz \
    -o "$repository/build/tests/IPPLiveStatus"
"$repository/build/tests/IPPLiveStatus"
