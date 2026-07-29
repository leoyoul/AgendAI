#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_SUPPORT_DIR="${TINGLAN_SIDECAR_HOME:-$HOME/Library/Application Support/会小纪/VoiceprintSidecar}"
RESOURCE_DIR="${TINGLAN_SIDECAR_RESOURCE_DIR:-}"

if [ -n "$RESOURCE_DIR" ]; then
    SOURCE_DIR="$RESOURCE_DIR/voiceprint_sidecar"
else
    SOURCE_DIR="$ROOT_DIR/Tools/voiceprint_sidecar"
fi
SERVER_SOURCE="$SOURCE_DIR/server.py"
REQUIREMENTS_SOURCE="$SOURCE_DIR/requirements.txt"
VENV_DIR="$APP_SUPPORT_DIR/.voiceprint-py312"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

if [ ! -f "$SERVER_SOURCE" ] || [ ! -f "$REQUIREMENTS_SOURCE" ]; then
    echo "缺少说话人 sidecar 源文件：$SOURCE_DIR" >&2
    exit 1
fi
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "未找到 Python 3.12：$PYTHON_BIN。请安装 Python 3.12 后重试，或通过 PYTHON_BIN 指定解释器。" >&2
    exit 1
fi

mkdir -p "$APP_SUPPORT_DIR"
chmod 700 "$APP_SUPPORT_DIR"
cp "$SERVER_SOURCE" "$APP_SUPPORT_DIR/server.py"
cp "$REQUIREMENTS_SOURCE" "$APP_SUPPORT_DIR/requirements.txt"

if [ ! -x "$VENV_DIR/bin/python" ]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$APP_SUPPORT_DIR/requirements.txt"
"$VENV_DIR/bin/python" - <<'PY'
import importlib.metadata

required = ("funasr", "modelscope", "torch", "torchaudio")
missing = []
for package in required:
    try:
        print(f"{package}={importlib.metadata.version(package)}")
    except importlib.metadata.PackageNotFoundError:
        print(f"{package}=MISSING")
        missing.append(package)

if missing:
    raise SystemExit(f"sidecar 运行依赖安装不完整：{', '.join(missing)}")

try:
    import torch
    import torchaudio
except Exception as exc:
    raise SystemExit(f"sidecar PyTorch 运行时不可用：{exc}") from exc
PY

echo "sidecar 已准备：$APP_SUPPORT_DIR/server.py"
echo "Python 环境：$VENV_DIR/bin/python"
echo "首次 preload 会从 ModelScope 下载模型权重到本机缓存；权重不会被写入安装包。"
