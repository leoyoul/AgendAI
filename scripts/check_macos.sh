#!/usr/bin/env sh
set -eu

sh scripts/check_macos_docs.sh
sh scripts/check_tinglan_agentd.sh

for removed in backend frontend Dockerfile docker-compose.yml pyproject.toml uv.lock scripts/check.sh; do
  if [ -e "$removed" ]; then
    echo "旧 Web/Docker 原型文件仍存在：$removed"
    exit 1
  fi
done

python3 tests/macos_packaging_tests.py
swift test
swift build --product AItingjiApp
swift build --product AItingjiCaptureSmoke
swift build --product AItingjiLiveSmoke
sh scripts/package_macos_app.sh
tmp_check_dir="$(mktemp -d "/tmp/agendai-check.XXXXXX")"
DMG_PATH="dist/AgendAI-v0.1.3-macOS-universal.dmg"
MOUNT_ROOT="$tmp_check_dir/mount"
MOUNT_POINT="$MOUNT_ROOT/AgendAI 会小纪 0.1.3"
mkdir -p "$MOUNT_ROOT"
attach_output="$(hdiutil attach -nobrowse -mountroot "$MOUNT_ROOT" "$DMG_PATH")"
device="$(printf '%s\n' "$attach_output" | awk '$1 ~ /^\/dev\// && /Apple_HFS/ { print $1; exit }')"
cleanup_check() {
  if [ -n "${device:-}" ]; then
    detach_attempt=0
    while [ "$detach_attempt" -lt 3 ]; do
      if hdiutil detach "$device" -force >/dev/null 2>&1; then
        device=""
        break
      fi
      detach_attempt=$((detach_attempt + 1))
      sleep 1
    done
  fi
  if [ -n "${device:-}" ]; then
    echo "DMG 临时挂载点清理失败：$device" >&2
    return 1
  fi
  rm -rf "$tmp_check_dir"
}
trap cleanup_check EXIT

if [ -z "$device" ] || [ ! -d "$MOUNT_POINT/AgendAI 会小纪.app" ]; then
  echo "DMG 挂载或 app 入口检查失败"
  exit 1
fi
if [ ! -L "$MOUNT_POINT/Applications" ] || [ "$(readlink "$MOUNT_POINT/Applications")" != "/Applications" ]; then
  echo "DMG 缺少 /Applications 快捷入口"
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/AgendAI 会小纪.app"
resources_dir="$MOUNT_POINT/AgendAI 会小纪.app/Contents/Resources"

if find "$resources_dir" -name voiceprint_sidecar -print -quit | grep -q .; then
  echo "安装包仍包含已移除的说话人 sidecar 资源：voiceprint_sidecar"
  exit 1
fi

if find "$resources_dir" -name setup_voiceprint_sidecar.sh -print -quit | grep -q .; then
  echo "安装包仍包含已移除的说话人 sidecar 资源：setup_voiceprint_sidecar.sh"
  exit 1
fi

for forbidden_directory in .venv venv .voiceprint-py312 .voiceprint-venv models weights checkpoints; do
  if find "$resources_dir" -type d -name "$forbidden_directory" -print -quit | grep -q .; then
    echo "安装包不应包含 Python 环境或模型目录：$forbidden_directory"
    exit 1
  fi
done

if find "$resources_dir" -type f \( -name '*.pt' -o -name '*.pth' -o -name '*.bin' -o -name '*.onnx' -o -name '*.safetensors' -o -name '*.ckpt' \) -print -quit | grep -q .; then
  echo "安装包不应包含模型权重文件"
  exit 1
fi

if find "$resources_dir" -name .DS_Store -print -quit | grep -q .; then
  echo "安装包不应包含 .DS_Store"
  exit 1
fi

echo "macOS 原生工程检查通过"
