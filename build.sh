#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/iPhoneBatteryWidget.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$BIN" "$RES"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/AppIcon.icns" ]]; then
  cp "$ROOT/AppIcon.icns" "$RES/AppIcon.icns"
fi

OPT_FLAG="-Onone"
if [[ "${1:-}" == "--release" || "${1:-}" == "-r" || "${1:-}" == "-O" ]]; then
  OPT_FLAG="-O"
  echo "⚙️  Compiling iPhoneBatteryWidget.swift (Release / Optimized)…"
else
  echo "⚙️  Compiling iPhoneBatteryWidget.swift (Fast Build)…"
fi

SDK_FLAGS=()
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
  SDK_FLAGS+=("-sdk" "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" ]]; then
  SDK_FLAGS+=("-sdk" "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
fi

swiftc $OPT_FLAG -j 8 -parse-as-library \
  "${SDK_FLAGS[@]}" \
  -o "$BIN/iPhoneBatteryWidget" \
  "$ROOT/iPhoneBatteryWidget.swift" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Metal \
  -framework MetalKit \
  -framework QuartzCore \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework UserNotifications \
  -framework IOKit \
  -target arm64-apple-macos14

chmod +x "$BIN/iPhoneBatteryWidget"
rm -rf "$APP/Contents/_CodeSignature"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

if [[ -w /Applications ]]; then
  STAGE_DIR="/Applications/.iPhoneBatteryWidget.staging"
  STAGE_APP="$STAGE_DIR/iPhoneBatteryWidget.app"
  BACKUP="/Applications/.iPhoneBatteryWidget.old.app"
  rm -rf "$STAGE_DIR" "$BACKUP"
  mkdir -p "$STAGE_DIR"
  cp -R "$APP" "$STAGE_APP"
  rm -rf "$STAGE_APP/Contents/_CodeSignature"
  xattr -cr "$STAGE_APP" 2>/dev/null || true
  codesign --force --deep --sign - "$STAGE_APP"
  codesign --verify --deep --strict "$STAGE_APP"
  if [[ -e /Applications/iPhoneBatteryWidget.app ]]; then
    mv /Applications/iPhoneBatteryWidget.app "$BACKUP"
  fi
  mv "$STAGE_APP" /Applications/iPhoneBatteryWidget.app
  rm -rf "$STAGE_DIR"
  echo "✅  Installed → /Applications/iPhoneBatteryWidget.app"
  # Stop the old process only after the new signed bundle is in place so LaunchAgent KeepAlive never respawns mid-copy.
  pkill -x iPhoneBatteryWidget 2>/dev/null || true
  pkill -f "ClientVersionString': 'bw_1.0'" 2>/dev/null || true
  sleep 0.8
  rm -rf "$BACKUP"
  if ! pgrep -x iPhoneBatteryWidget >/dev/null; then
    open -a /Applications/iPhoneBatteryWidget.app
  fi
else
  echo "✅  Built → $APP  (copy to /Applications manually or run with sudo)"
fi
echo "Done."
