#!/usr/bin/env sh
set -eu

APP_PATH="${1:?请提供待打包的 .app 路径}"
DMG_PATH="${2:?请提供输出的 .dmg 路径}"
VOLUME_NAME="${3:?请提供 DMG 卷名}"

if [ ! -d "$APP_PATH" ] || [ "${APP_PATH##*.}" != "app" ]; then
    echo "待打包路径不是 .app：$APP_PATH" >&2
    exit 1
fi

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "/tmp/agendai-dmg.XXXXXX")"
STAGING_DIR="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/rw.dmg"
MOUNT_ROOT="$TMP_DIR/mount"
MOUNT_POINT="$MOUNT_ROOT/$VOLUME_NAME"
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$STAGING_DIR" "$MOUNT_ROOT"
ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
mkdir -p "$(dirname -- "$DMG_PATH")"

# A writable intermediate image lets Finder persist icon view and positions.
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach -nobrowse -mountroot "$MOUNT_ROOT" "$RW_DMG")"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '$1 ~ /^\/dev\// && /Apple_HFS/ { print $1; exit }')"
if [ -z "$DEVICE" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "无法挂载 DMG 中间镜像" >&2
    exit 1
fi

# Finder may be unavailable in a headless build host; the image remains valid
# and the explicit layout is best effort in that environment.
if command -v osascript >/dev/null 2>&1; then
    osascript - "$VOLUME_NAME" "$(basename "$APP_PATH")" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    set volumeName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set position of item appName to {180, 180}
            set position of item "Applications" to {480, 180}
            close
            open
            update without registering applications
        end tell
    end tell
end run
APPLESCRIPT
fi

hdiutil detach "$DEVICE" >/dev/null
DEVICE=""
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null

echo "已生成：$DMG_PATH"
echo "卷名：$VOLUME_NAME"
