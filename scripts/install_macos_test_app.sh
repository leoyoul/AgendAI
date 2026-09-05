#!/usr/bin/env sh
set -eu

APP_NAME="AgendAI 会小纪 测试版"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_ZIP="$ROOT_DIR/dist-test/$APP_NAME.app.zip"
TARGET_APP="/Applications/$APP_NAME.app"
TARGET_EXECUTABLE="$TARGET_APP/Contents/MacOS/$APP_NAME"
TMP_DIR="$(mktemp -d "/tmp/agendai-test-install.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

sh "$ROOT_DIR/scripts/package_macos_test_app.sh"
if pgrep -f "$TARGET_EXECUTABLE" >/dev/null 2>&1; then
    echo "请先退出 $APP_NAME，再安装测试版。"
    exit 1
fi
ditto -x -k "$SOURCE_ZIP" "$TMP_DIR"
if [ ! -d "$TMP_DIR/$APP_NAME.app" ]; then
    echo "测试安装包中缺少 $APP_NAME.app"
    exit 1
fi
if [ -d "$TARGET_APP" ]; then
    rm -rf "$TARGET_APP"
fi
ditto "$TMP_DIR/$APP_NAME.app" "$TARGET_APP"
xattr -cr "$TARGET_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$TARGET_APP" >/dev/null
echo "已安装测试版：$TARGET_APP"
