#!/bin/zsh
# Builds Release and installs on a paired iPhone (first one devicectl lists, or $DEVICE).
#   ./scripts/install-device.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone [0-9]/ && (/available/ || /connected/) {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')}
[[ -n "$DEVICE" ]] || { echo "✋ No available iPhone. Unlock it and check it's paired."; exit 1; }

xcodegen generate > /dev/null
echo "▶ Building…"
xcodebuild build -project Eidetic.xcodeproj -scheme Eidetic -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/device -allowProvisioningUpdates -quiet
echo "▶ Installing on $DEVICE…"
APP=build/device/Build/Products/Release-iphoneos/Eidetic.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" > /dev/null 2>&1 \
  && echo "✓ Installed and launched" || echo "✓ Installed (unlock the phone to launch)"
