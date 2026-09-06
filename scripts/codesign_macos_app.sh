#!/usr/bin/env sh
set -eu

APP_PATH="${1:?请提供待签名的 .app 路径}"
BUNDLE_ID="${TINGLAN_BUNDLE_ID:-com.local.aitingji}"
DESIGNATED_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""

if [ ! -d "$APP_PATH/Contents" ]; then
    echo "不是有效的 macOS app bundle：$APP_PATH" >&2
    exit 1
fi

sign_sparkle_component() {
    component_path="$1"
    if [ ! -e "$component_path" ]; then
        echo "Sparkle 嵌套组件缺失：$component_path" >&2
        exit 1
    fi
    codesign \
        --force \
        --timestamp=none \
        --options runtime \
        --preserve-metadata=entitlements \
        --sign - \
        "$component_path" \
        >/dev/null
}

verify_sparkle_runtime() {
    component_path="$1"
    if ! codesign -d -vv "$component_path" 2>&1 | grep -q 'flags=.*runtime'; then
        echo "Sparkle 组件缺少 Hardened Runtime 签名：$component_path" >&2
        exit 1
    fi
}

SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    # Sparkle's pre-signed universal artifact must be re-sealed after copying,
    # in this documented order, while retaining Autoupdate's entitlement.
    SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
    sign_sparkle_component "$SPARKLE_VERSION/XPCServices/Installer.xpc"
    sign_sparkle_component "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
    sign_sparkle_component "$SPARKLE_VERSION/Autoupdate"
    sign_sparkle_component "$SPARKLE_VERSION/Updater.app"
    sign_sparkle_component "$SPARKLE_FRAMEWORK"
    verify_sparkle_runtime "$SPARKLE_VERSION/XPCServices/Installer.xpc"
    verify_sparkle_runtime "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
    verify_sparkle_runtime "$SPARKLE_VERSION/Autoupdate"
    verify_sparkle_runtime "$SPARKLE_VERSION/Updater.app"
    verify_sparkle_runtime "$SPARKLE_FRAMEWORK"
    autoupdate_entitlements="$(codesign -d --entitlements :- "$SPARKLE_VERSION/Autoupdate" 2>/dev/null || true)"
    case "$autoupdate_entitlements" in
        *"com.apple.application-identifier"*) ;;
        *)
            echo "Autoupdate entitlement 丢失" >&2
            exit 1
            ;;
    esac
fi

codesign \
    --force \
    --timestamp=none \
    --sign - \
    --requirements "$DESIGNATED_REQUIREMENT" \
    "$APP_PATH" \
    >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

ACTUAL_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"
case "$ACTUAL_REQUIREMENT" in
    *"designated => identifier \"$BUNDLE_ID\""*) ;;
    *)
        echo "应用签名身份不稳定：$ACTUAL_REQUIREMENT"
        exit 1
        ;;
esac
