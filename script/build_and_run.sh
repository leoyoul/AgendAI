#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AItingjiApp"
BUNDLE_ID="io.github.leoyoul.agendai"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
DEV_INFO_PLIST="$ROOT_DIR/Packaging/AItingjiDevelopment-Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
BUILD_BIN_PATH="$(dirname "$BUILD_BINARY")"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# SwiftPM leaves dynamic package frameworks beside the debug executable. Keep
# the runnable app bundle self-contained so `open` and `--verify` exercise the
# same launch path as a packaged macOS app.
if [ -d "$BUILD_BIN_PATH/Sparkle.framework" ]; then
  ditto --norsrc --noextattr "$BUILD_BIN_PATH/Sparkle.framework" "$APP_FRAMEWORKS/Sparkle.framework"
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BINARY"
fi

if [ ! -f "$DEV_INFO_PLIST" ]; then
  echo "缺少开发包元数据模板：$DEV_INFO_PLIST" >&2
  exit 1
fi
cp "$DEV_INFO_PLIST" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "0.1.9" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "19" "$APP_CONTENTS/Info.plist"

# The rpath edit above invalidates any inherited build signature. Re-sign the
# local bundle so LaunchServices can open it during development verification.
# SwiftPM's copied Sparkle framework can carry macOS provenance/Finder metadata
# that codesign rejects as a resource fork. This bundle is disposable, so clear
# all extended attributes before signing it.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
if ! codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null; then
  # File Provider may restore Finder metadata between the cleanup pass and
  # codesign. Clear the disposable bundle once more before retrying.
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
  find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
