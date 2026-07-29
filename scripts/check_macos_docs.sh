#!/usr/bin/env sh
set -eu

if ! grep -q "AgendAI 会小纪" README.md; then
  echo "README 未包含产品名称"
  exit 1
fi

if ! grep -q "macOS 14" README.md; then
  echo "README 未说明系统要求"
  exit 1
fi

if ! grep -q "MIT License" README.md || [ ! -f LICENSE ]; then
  echo "README 或仓库缺少许可证说明"
  exit 1
fi

for file in CONTRIBUTING.md SECURITY.md; do
  if [ ! -f "$file" ]; then
    echo "缺少公开仓库文档：$file"
    exit 1
  fi
done

metadata_file="Packaging/AItingjiApp-Info.plist"
if [ ! -f "$metadata_file" ]; then
  echo "缺少 App 元数据文件：$metadata_file"
  exit 1
fi

for key in NSMicrophoneUsageDescription NSScreenCaptureUsageDescription NSAudioCaptureUsageDescription; do
  if ! grep -q "$key" "$metadata_file"; then
    echo "Info.plist 缺少权限用途说明：$key"
    exit 1
  fi
done

if ! grep -q "swift build --product AItingjiApp" scripts/check_macos.sh; then
  echo "检查脚本未覆盖 App 构建"
  exit 1
fi

if ! grep -q "python3 tests/macos_packaging_tests.py" scripts/check_macos.sh; then
  echo "检查脚本未覆盖 macOS 打包契约测试"
  exit 1
fi

echo "公开仓库文档检查通过"
