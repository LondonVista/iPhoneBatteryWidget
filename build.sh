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
fi

swiftc $OPT_FLAG -j 8 -parse-as-library \
  "${SDK_FLAGS[@]}" \
  -o "$BIN/iPhoneBatteryWidget" \
  "$ROOT/iPhoneBatteryWidget.swift" \
  -framework Cocoa -framework SwiftUI \
  -target arm64-apple-macos13

chmod +x "$BIN/iPhoneBatteryWidget"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

if [[ -w /Applications ]]; then
  pkill -x iPhoneBatteryWidget 2>/dev/null || true
  pkill -f "ClientVersionString': 'bw_1.0'" 2>/dev/null || true
  sleep 0.2
  rm -rf /Applications/iPhoneBatteryWidget.app
  cp -R "$APP" /Applications/iPhoneBatteryWidget.app
  codesign --force --deep --sign - /Applications/iPhoneBatteryWidget.app 2>/dev/null || true
  echo "✅  Installed → /Applications/iPhoneBatteryWidget.app"
  # One instance only: let LaunchAgent respawn, never `open` on top of it.
  sleep 0.6
  if ! pgrep -x iPhoneBatteryWidget >/dev/null; then
    open -a /Applications/iPhoneBatteryWidget.app
  fi
else
  echo "✅  Built → $APP  (copy to /Applications manually or run with sudo)"
fi
echo "Done."
