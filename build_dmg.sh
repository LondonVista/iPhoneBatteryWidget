#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iPhoneBatteryWidget"
DMG_NAME="iPhoneBatteryWidget-Installer.dmg"
STAGING="$ROOT/dmg_staging"

echo "🔨 Building $APP_NAME for DMG release…"
"$ROOT/build.sh" --release

echo "📦 Preparing DMG staging directory…"
rm -rf "$STAGING" "$ROOT/$DMG_NAME"
mkdir -p "$STAGING"

# Copy the compiled .app bundle
cp -R "$ROOT/$APP_NAME.app" "$STAGING/$APP_NAME.app"

# Create symlink to /Applications for standard drag-and-drop installation
ln -s /Applications "$STAGING/Applications"

echo "💿 Creating DMG image ($DMG_NAME)…"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$ROOT/$DMG_NAME"

# Clean staging directory
rm -rf "$STAGING"

echo "✅ DMG successfully generated at: $ROOT/$DMG_NAME"
ls -lh "$ROOT/$DMG_NAME"
