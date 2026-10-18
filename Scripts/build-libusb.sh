#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive="$repository/Vendor/libusb-1.0.29.tar.bz2"
source_dir="$repository/build/libusb-source"
output="$repository/build/libusb-runtime"
digest=5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
mkdir -p "$repository/Vendor" "$source_dir" "$output"
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2 \
        -o "$archive.download"
    mv "$archive.download" "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
test "$actual" = "$digest" || { echo 'libusb source download failed its integrity pin.' >&2; exit 1; }
tar -xjf "$archive" -C "$source_dir" --strip-components=1
cd "$source_dir"
export MACOSX_DEPLOYMENT_TARGET=14.0
./configure CC='xcrun --sdk macosx clang' CFLAGS='-arch arm64 -mmacosx-version-min=14.0' \
    LDFLAGS='-arch arm64 -mmacosx-version-min=14.0' --disable-static --enable-shared \
    --disable-tests-build --disable-examples-build --prefix="$output" > "$output/configure.log" 2>&1
make -j4 > "$output/build.log" 2>&1
cp libusb/.libs/libusb-1.0.0.dylib "$output/libusb-1.0.dylib"
install_name_tool -id @rpath/libusb-1.0.dylib "$output/libusb-1.0.dylib"
codesign --force --sign - "$output/libusb-1.0.dylib"
cp COPYING "$output/COPYING-libusb.txt"
codesign --verify --strict "$output/libusb-1.0.dylib"
otool -L "$output/libusb-1.0.dylib"
