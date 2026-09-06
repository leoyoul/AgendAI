#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${AGEND_AI_APP_VERSION:-0.1.3}"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.local.aitingji}"
DMG_NAME="AgendAI-v${VERSION}-macOS-universal.dmg"
DMG_PATH="$ROOT_DIR/dist/$DMG_NAME"
NOTES_PATH="${1:-$ROOT_DIR/output/release-v${VERSION}.md}"
APPCAST_PATH="$ROOT_DIR/docs/appcast.xml"
TOOLS_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
TMP_DIR="$(mktemp -d "/tmp/agendai-appcast.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if [ ! -f "$DMG_PATH" ] || [ ! -f "$NOTES_PATH" ]; then
    echo "缺少 DMG 或发布说明：$DMG_PATH / $NOTES_PATH" >&2
    exit 1
fi
if [ ! -x "$TOOLS_DIR/generate_keys" ] || [ ! -x "$TOOLS_DIR/generate_appcast" ]; then
    echo "缺少 Sparkle 2.9.6 发布工具，请先执行 swift package resolve" >&2
    exit 1
fi

KEYCHAIN_PUBLIC_KEY="$($TOOLS_DIR/generate_keys --account "$ACCOUNT" -p)"
PLIST_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$ROOT_DIR/Packaging/AItingjiApp-Info.plist")"
if [ "$KEYCHAIN_PUBLIC_KEY" != "$PLIST_PUBLIC_KEY" ]; then
    echo "钥匙串公钥与应用 SUPublicEDKey 不一致，拒绝签名" >&2
    exit 1
fi

ditto "$DMG_PATH" "$TMP_DIR/$DMG_NAME"
ditto "$NOTES_PATH" "$TMP_DIR/${DMG_NAME%.dmg}.md"
if [ -f "$APPCAST_PATH" ]; then
    ditto "$APPCAST_PATH" "$TMP_DIR/appcast.xml"
fi
"$TOOLS_DIR/generate_appcast" \
    --account "$ACCOUNT" \
    --download-url-prefix "https://github.com/leoyoul/AgendAI/releases/download/v${VERSION}/" \
    --link "https://github.com/leoyoul/AgendAI/releases/tag/v${VERSION}" \
    --embed-release-notes \
    --maximum-versions 3 \
    "$TMP_DIR"

if [ ! -f "$TMP_DIR/appcast.xml" ]; then
    echo "Sparkle 未生成 appcast.xml" >&2
    exit 1
fi
ditto "$TMP_DIR/appcast.xml" "$APPCAST_PATH"
"$TOOLS_DIR/sign_update" --account "$ACCOUNT" --verify "$APPCAST_PATH"

echo "已生成并验证：$APPCAST_PATH"
