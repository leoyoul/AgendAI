#!/usr/bin/env sh
set -eu

APP_NAME="AgendAI 会小纪"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_ZIP="$ROOT_DIR/dist/$APP_NAME.app.zip"
TARGET_APP="/Applications/$APP_NAME.app"
TMP_DIR="$(mktemp -d "/tmp/agendai-install.XXXXXX")"
TMP_APP="$TMP_DIR/$APP_NAME.app"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

sh "$ROOT_DIR/scripts/package_macos_app.sh"

pkill -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "$ROOT_DIR/dist/$APP_NAME.app" "$ROOT_DIR/dist-debug-package/$APP_NAME.app"
rm -rf "$TARGET_APP"
ditto -x -k "$SOURCE_ZIP" "$TMP_DIR"
if [ ! -d "$TMP_APP" ]; then
    echo "安装包中缺少 $APP_NAME.app"
    exit 1
fi
ditto "$TMP_APP" "$TARGET_APP"
xattr -cr "$TARGET_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$TARGET_APP" >/dev/null

echo "已安装：$TARGET_APP"
