#!/usr/bin/env sh
set -eu

APP_PATH="${1:?请提供待签名的 .app 路径}"
BUNDLE_ID="${TINGLAN_BUNDLE_ID:-com.local.aitingji}"
DESIGNATED_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""

codesign \
    --force \
    --deep \
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
