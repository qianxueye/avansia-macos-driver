#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT="$ROOT/build/app-tests"
mkdir -p "$OUTPUT/module-cache"
xcrun swiftc -disable-sandbox -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT/module-cache" -parse-as-library "$ROOT"/Sources/App/*.swift -o "$OUTPUT/AvansiaUtility"
xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT/module-cache" "$ROOT/Tests/AppFixtureCommand.swift" -o "$OUTPUT/AppFixtureCommand"
TEST_BUNDLE="$OUTPUT/ModelTests.app"
mkdir -p "$TEST_BUNDLE/Contents/MacOS" "$TEST_BUNDLE/Contents/Resources"
cp -R "$ROOT/Resources/zh-Hans.lproj" "$TEST_BUNDLE/Contents/Resources/"
cat > "$TEST_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.avansia.model-tests</string>
<key>CFBundleExecutable</key><string>AppModelTests</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
</dict></plist>
PLIST
plutil -lint "$ROOT/Resources/zh-Hans.lproj/Localizable.strings" "$ROOT/Resources/zh-Hans.lproj/InfoPlist.strings"
xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT/module-cache" -parse-as-library "$ROOT/Sources/App/AppLocalization.swift" "$ROOT/Sources/App/AppModel.swift" "$ROOT/Tests/AppModelTests.swift" -o "$TEST_BUNDLE/Contents/MacOS/AppModelTests"
"$TEST_BUNDLE/Contents/MacOS/AppModelTests" "$OUTPUT/AppFixtureCommand"
