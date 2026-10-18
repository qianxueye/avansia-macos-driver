#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
test -z "$(git status --porcelain)" || { echo 'Commit the verified source candidate before packaging.' >&2; exit 1; }
version=$(cat VERSION)
app="$repository/build/application/Avansia Utility.app"
info="$app/Contents/Resources/build-info.json"
test "$(/usr/bin/plutil -extract commit raw -o - "$info")" = "$(git rev-parse HEAD)" || {
    echo 'The application was not built from the current source commit.' >&2; exit 1;
}
/usr/bin/codesign --verify --deep --strict "$app"
if find "$app" -name libevolis.dylib -o -name '*.whl' -o -name Avansia-original.png | /usr/bin/grep -q .; then
    echo 'A private vendor dependency entered the public application.' >&2; exit 1;
fi
output="$repository/build/release"
sources="$output/third-party-sources"
mkdir -p "$output" "$sources/Vendor" "$sources/Tests"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Avansia-macOS-$version-arm64.zip"
cp "${CUPS_SOURCE_ARCHIVE:-$repository/Vendor/cups-2.4.14-source.tar.gz}" "$sources/Vendor/cups-2.4.14-source.tar.gz"
cp "$repository/Vendor/libusb-1.0.29.tar.bz2" "$sources/Vendor/"
cp "$repository/Tests/LibusbInitialization.c" "$sources/Tests/"
cp "$repository/Docs/ThirdPartyNotices.md" "$sources/"
mkdir -p "$sources/Scripts"
cp "$repository/Scripts/build-ipp.sh" "$repository/Scripts/build-libusb.sh" "$sources/Scripts/"
cp -R "$repository/Patches" "$sources/"
COPYFILE_DISABLE=1 tar -czf "$output/Avansia-$version-third-party-sources.tar.gz" -C "$output" third-party-sources
printf 'Application: %s\nThird-party sources: %s\n' \
    "$output/Avansia-macOS-$version-arm64.zip" "$output/Avansia-$version-third-party-sources.tar.gz"
