#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build="$repository/build/ipp"
source="$build/cups-2.4.14"
runtime="$repository/build/ipp-runtime"
archive=${CUPS_SOURCE_ARCHIVE:-"$repository/Vendor/cups-2.4.14-source.tar.gz"}
expected=660288020dd6f79caf799811c4c1a3207a48689899ac2093959d70a3bdcb7699
url=https://github.com/OpenPrinting/cups/releases/download/v2.4.14/cups-2.4.14-source.tar.gz

test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
mkdir -p "$build" "$source"
if [ ! -f "$archive" ]; then
    mkdir -p "$(dirname "$archive")"
    curl --fail --location --proto '=https' --tlsv1.2 "$url" -o "$archive.download"
    mv "$archive.download" "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != "$expected" ]; then
    echo 'CUPS source archive failed its pinned download-integrity check.' >&2
    exit 1
fi

tar -xzf "$archive" -C "$source" --strip-components=1
for patch_file in ippeve-pdf-format.patch ippeve-persistent-stop.patch tls-darwin-context.patch ippeve-live-status.patch; do
    patch --batch --forward -d "$source" -p1 < "$repository/Patches/$patch_file"
done

cd "$source"
export MACOSX_DEPLOYMENT_TARGET=14.0
./configure CC='xcrun --sdk macosx clang' CXX='xcrun --sdk macosx clang++' \
    CFLAGS='-mmacosx-version-min=14.0' LDFLAGS='-mmacosx-version-min=14.0' \
    --with-components=libcups --enable-static --disable-shared \
    --disable-pam --disable-gssapi --disable-dbus --disable-acl \
    --disable-libusb --disable-libpaper --with-tls=cdsa \
    --with-dnssd=mdnsresponder --with-archflags='-arch arm64' \
    --with-ldarchflags='-arch arm64' --prefix=/usr/local \
    > "$build/configure.log" 2>&1
make -C cups clean > "$build/clean.log" 2>&1
make -C tools clean >> "$build/clean.log" 2>&1
make -C cups -j4 libcups.a > "$build/library.log" 2>&1
make -C tools ippeveprinter-static > "$build/engine.log" 2>&1

mkdir -p "$runtime/bin" "$runtime/share/licenses/cups"
cp tools/ippeveprinter-static "$runtime/bin/ippeveprinter"
chmod 755 "$runtime/bin/ippeveprinter"
cp LICENSE NOTICE "$repository"/Patches/*.patch "$runtime/share/licenses/cups/"
cat > "$runtime/share/licenses/cups/SOURCE.txt" <<EOF
CUPS 2.4.14, OpenPrinting
Source: $url
SHA-256 download integrity: $expected
License: Apache License 2.0 with the exceptions in LICENSE.
All local source changes are supplied in the accompanying patches.
The matching libcups is statically linked; only Apple system dependencies remain.
This build does not install or replace host CUPS components.
EOF
codesign --force --sign - "$runtime/bin/ippeveprinter"
codesign --verify --verbose=2 "$runtime/bin/ippeveprinter"
file "$runtime/bin/ippeveprinter"
otool -L "$runtime/bin/ippeveprinter"
"$runtime/bin/ippeveprinter" --version
