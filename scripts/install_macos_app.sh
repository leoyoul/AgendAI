#!/usr/bin/env sh
set -eu

APP_NAME="AgendAI 会小纪"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/AgendAI-v0.1.3-macOS-universal.dmg"
TARGET_APP="/Applications/$APP_NAME.app"
TMP_DIR="$(mktemp -d "/tmp/agendai-install.XXXXXX")"
MOUNT_ROOT="$TMP_DIR/mount"
MOUNT_POINT="$MOUNT_ROOT/AgendAI 会小纪 0.1.3"
MOUNTED_APP="$MOUNT_POINT/$APP_NAME.app"
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

sh "$ROOT_DIR/scripts/package_macos_app.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "缺少正式 DMG：$DMG_PATH" >&2
    exit 1
fi
mkdir -p "$MOUNT_ROOT"
attach_output="$(hdiutil attach -nobrowse -mountroot "$MOUNT_ROOT" "$DMG_PATH")"
DEVICE="$(printf '%s\n' "$attach_output" | awk '$1 ~ /^\/dev\// && /Apple_HFS/ { print $1; exit }')"
if [ -z "$DEVICE" ] || [ ! -d "$MOUNTED_APP" ]; then
    echo "正式 DMG 挂载失败或缺少 $APP_NAME.app" >&2
    exit 1
fi
if [ ! -L "$MOUNT_POINT/Applications" ] || [ "$(readlink "$MOUNT_POINT/Applications")" != "/Applications" ]; then
    echo "正式 DMG 缺少 /Applications 快捷入口" >&2
    exit 1
fi
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$MOUNTED_APP/Contents/Info.plist")"
if [ "$bundle_id" != "com.local.aitingji" ]; then
    echo "安装包 Bundle ID 不正确：$bundle_id" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP" >/dev/null

pkill -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "$TARGET_APP"
ditto "$MOUNTED_APP" "$TARGET_APP"
codesign --verify --deep --strict --verbose=2 "$TARGET_APP" >/dev/null

echo "已安装：$TARGET_APP"
