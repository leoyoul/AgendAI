#!/usr/bin/env sh
set -eu

APP_NAME="AgendAI 会小纪"
BUNDLE_ID="com.local.aitingji"
APP_VERSION="${AGEND_AI_APP_VERSION:-0.1.3}"
APP_BUILD="${AGEND_AI_APP_BUILD:-4}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/AgendAI-v${APP_VERSION}-macOS-universal.dmg"
TMP_DIR="$(mktemp -d "/tmp/agendai-package.XXXXXX")"
TMP_APP_DIR="$TMP_DIR/$APP_NAME.app"
CONTENTS_DIR="$TMP_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
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

rm -rf "$DMG_PATH" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$ICONSET_DIR"

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
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD" "$CONTENTS_DIR/Info.plist"
SPARKLE_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$CONTENTS_DIR/Info.plist" 2>/dev/null || true)"
case "$SPARKLE_PUBLIC_KEY" in
    ""|__SPARKLE_PUBLIC_KEY__|*" "*|*"	"*)
        echo "SUPublicEDKey 缺失或仍是占位符，拒绝打包" >&2
        exit 1
        ;;
esac
if [ "${#SPARKLE_PUBLIC_KEY}" -lt 32 ]; then
    echo "SUPublicEDKey 长度无效，拒绝打包" >&2
    exit 1
fi

ARM_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/release/AItingjiApp"
if otool -L "$ARM_BINARY" | grep -q 'Sparkle.framework'; then
    SPARKLE_SOURCE="${SPARKLE_FRAMEWORK_PATH:-}"
    if [ -z "$SPARKLE_SOURCE" ]; then
        for candidate in \
            "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
            "$ROOT_DIR/.build/arm64-apple-macosx/release/Sparkle.framework" \
            "$ROOT_DIR/.build/arm64-apple-macosx/debug/Sparkle.framework"; do
            if [ -d "$candidate" ]; then
                SPARKLE_SOURCE="$candidate"
                break
            fi
        done
    fi
    if [ -z "$SPARKLE_SOURCE" ] || [ ! -d "$SPARKLE_SOURCE" ]; then
        echo "可执行文件已链接 Sparkle，但找不到 Sparkle.framework 构建产物" >&2
        exit 1
    fi
    ditto "$SPARKLE_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
    if command -v install_name_tool >/dev/null 2>&1 && ! otool -l "$MACOS_DIR/$APP_NAME" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS_DIR/$APP_NAME"
    fi
elif [ -n "${SPARKLE_FRAMEWORK_PATH:-}" ]; then
    ditto "$SPARKLE_FRAMEWORK_PATH" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

find "$TMP_APP_DIR" -name .DS_Store -delete
xattr -cr "$TMP_APP_DIR" 2>/dev/null || true
sh "$ROOT_DIR/scripts/codesign_macos_app.sh" "$TMP_APP_DIR"

VOLUME_NAME="AgendAI 会小纪 $APP_VERSION"
sh "$ROOT_DIR/scripts/create_macos_dmg.sh" "$TMP_APP_DIR" "$DMG_PATH" "$VOLUME_NAME"

if [ "${PACKAGE_INTERNAL_ZIP:-0}" = "1" ]; then
    ditto -c -k --keepParent "$TMP_APP_DIR" "$TMP_DIR/$APP_NAME.app.zip"
    echo "已生成内部测试 ZIP：$TMP_DIR/$APP_NAME.app.zip"
fi

echo "已生成：$DMG_PATH"
echo "Bundle ID：$BUNDLE_ID"
