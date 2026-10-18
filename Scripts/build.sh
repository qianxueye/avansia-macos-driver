#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
version=$(cat VERSION)
case "$version" in *[!0-9.]*|'') echo 'Invalid application version.' >&2; exit 1;; esac
if [ "${RELEASE_BUILD:-0}" = 1 ] && [ -n "$(git status --porcelain)" ]; then
    echo 'Release builds require a committed, clean source candidate.' >&2
    exit 1
fi
Scripts/build-libusb.sh
Scripts/build-ipp.sh
build="$repository/build/application"
app="$build/Avansia Utility.app"
package="$app/Contents/Resources/Driver"
runtime="$package/runtime"
mkdir -p "$app/Contents/MacOS" "$package" "$runtime/native/lib" "$build/module-cache" "$runtime/Assets"
export CLANG_MODULE_CACHE_PATH="$build/module-cache"
xcrun clang -O2 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=14.0 \
    -c Sources/native-driver/NativeBridge.c -o "$build/NativeBridge.o"
xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
    -target arm64-apple-macosx14.0 -parse-as-library \
    -import-objc-header Sources/native-core/Bridge.h Sources/native-core/*.swift \
    "$build/NativeBridge.o" -lcups -o "$runtime/AvansiaCore"
for program in AvansiaJob AvansiaService; do
    if [ "$program" = AvansiaService ]; then
        xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
            -target arm64-apple-macosx14.0 -parse-as-library -D DRIVER_SERVICE \
            -import-objc-header Sources/native-driver/NativeBridge.h \
            Sources/native-driver/DriverJob.swift Sources/native-driver/DriverService.swift \
            Sources/native-core/ColorCorrection.swift "$build/NativeBridge.o" -lcups -o "$runtime/$program"
    else
        xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
            -target arm64-apple-macosx14.0 -parse-as-library \
            -import-objc-header Sources/native-driver/NativeBridge.h \
            Sources/native-driver/DriverJob.swift Sources/native-core/ColorCorrection.swift \
            "$build/NativeBridge.o" -lcups -o "$runtime/$program"
    fi
done
xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
    -target arm64-apple-macosx14.0 Sources/cups/CardRaster.swift -o "$runtime/CardRaster"
xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
    -target arm64-apple-macosx14.0 -parse-as-library \
    -import-objc-header Sources/native-driver/NativeBridge.h Sources/native-driver/Setup.swift \
    Sources/native-driver/RuntimeAssets.swift "$build/NativeBridge.o" -lcups -o "$package/AvansiaSetup"
xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
    -target arm64-apple-macosx14.0 Tools/BuildIcons.swift -o "$package/BuildIcons"
xcrun swiftc -disable-sandbox -module-cache-path "$build/module-cache" -O \
    -target arm64-apple-macosx14.0 -parse-as-library Sources/App/*.swift -o "$app/Contents/MacOS/AvansiaUtility"
cp Sources/cups/avansia.conf "$runtime/avansia.conf"
cp build/libusb-runtime/libusb-1.0.dylib build/libusb-runtime/COPYING-libusb.txt "$runtime/native/lib/"
cp -R build/ipp-runtime/bin build/ipp-runtime/share "$runtime/"
cat > "$runtime/cancel-stopped.test" <<'EOF'
{
  NAME "Cancel the explicitly selected stopped native job"
  OPERATION Cancel-Job
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR language attributes-natural-language en
  ATTR uri job-uri $uri
  STATUS successful-ok
}
EOF
"$package/BuildIcons" --fallback "$build/fallback-icons"
cp "$build"/fallback-icons/Avansia*.png "$build/fallback-icons/Avansia.icns" "$runtime/Assets/"
cp "$build/fallback-icons/Avansia.icns" "$app/Contents/Resources/Avansia.icns"
cp -R Resources/zh-Hans.lproj "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AvansiaUtility</string>
<key>CFBundleIdentifier</key><string>io.github.qianxueye.AvansiaUtility</string>
<key>CFBundleName</key><string>Avansia Utility</string>
<key>CFBundleDisplayName</key><string>Avansia Utility</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>Avansia.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
commit=$(git rev-parse HEAD)
printf '{"version":"%s","commit":"%s","architecture":"arm64","minimum_macos":"14.0","signing":"ad-hoc","notarized":false}\n' \
    "$version" "$commit" > "$app/Contents/Resources/build-info.json"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Docs/ThirdPartyNotices.md "$app/Contents/Resources/ThirdPartyNotices.md"
for executable in "$runtime/AvansiaCore" "$runtime/AvansiaJob" "$runtime/AvansiaService" "$runtime/CardRaster" "$package/AvansiaSetup" "$package/BuildIcons"; do
    codesign --force --sign - "$executable"
    codesign --verify --strict "$executable"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if find "$app" -name libevolis.dylib -o -name '*.whl' | /usr/bin/grep -q .; then
    echo 'A proprietary SDK artifact entered the public bundle.' >&2
    exit 1
fi
printf 'Built %s\n' "$app"
