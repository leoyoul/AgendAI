#!/usr/bin/env sh
set -eu

APP_NAME="AgendAI 会小纪"
BUNDLE_ID="com.local.aitingji"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/$APP_NAME.app.zip"
TMP_DIR="$(mktemp -d "/tmp/agendai-package.XXXXXX")"
TMP_APP_DIR="$TMP_DIR/$APP_NAME.app"
CONTENTS_DIR="$TMP_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_SOURCE="$ROOT_DIR/Packaging/Assets/AgendAIIcon-1024.png"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

if [ ! -f "$ICON_SOURCE" ]; then
    echo "缺少图标源文件：$ICON_SOURCE"
    exit 1
fi

swift build -c release --arch arm64 --product AItingjiApp
swift build -c release --arch x86_64 --product AItingjiApp

rm -rf "$DIST_DIR/$APP_NAME.app" "$ZIP_PATH" "$ROOT_DIR/dist-debug-package/$APP_NAME.app" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
lipo -create \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/AItingjiApp" \
    "$ROOT_DIR/.build/x86_64-apple-macosx/release/AItingjiApp" \
    -output "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Packaging/AItingjiApp-Info.plist" "$CONTENTS_DIR/Info.plist"

find "$TMP_APP_DIR" -name .DS_Store -delete
xattr -cr "$TMP_APP_DIR" 2>/dev/null || true
sh "$ROOT_DIR/scripts/codesign_macos_app.sh" "$TMP_APP_DIR"

ditto -c -k --keepParent "$TMP_APP_DIR" "$ZIP_PATH"

echo "已生成：$ZIP_PATH"
echo "Bundle ID：$BUNDLE_ID"
