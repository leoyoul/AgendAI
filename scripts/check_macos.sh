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
trap 'rm -rf "$tmp_check_dir"' EXIT
ditto -x -k 'dist/AgendAI 会小纪.app.zip' "$tmp_check_dir"
codesign --verify --deep --strict --verbose=2 "$tmp_check_dir/AgendAI 会小纪.app"
resources_dir="$tmp_check_dir/AgendAI 会小纪.app/Contents/Resources"

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
