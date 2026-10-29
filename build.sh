#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="$PWD/dist/AmyUsage-1.3.0/Amy流量.app"
mkdir -p "$APP/Contents/MacOS"
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx13.0" -O -framework AppKit -framework WebKit -framework Security -framework LocalAuthentication Sources/main.swift Sources/Website.swift -o "$APP/Contents/MacOS/AmyUsage"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AmyUsage</string>
<key>CFBundleIdentifier</key><string>local.AmyUsage</string>
<key>CFBundleName</key><string>Amy流量</string>
<key>CFBundleDisplayName</key><string>Amy流量</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/AmyUsage" --self-test
printf 'Built: %s\n' "$APP"
