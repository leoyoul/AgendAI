#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AGENT_DIR="$ROOT_DIR/Tools/tinglan_agentd"

NODE_MAJOR=$(node -p 'Number(process.versions.node.split(".")[0])')
if [ "$NODE_MAJOR" -lt 25 ]; then
  echo "tinglan-agentd 需要 Node.js 25 或更高版本，当前主版本：$NODE_MAJOR" >&2
  exit 1
fi

test -f "$AGENT_DIR/package-lock.json"
test -f "$AGENT_DIR/contracts/job-request.schema.json"
test -f "$AGENT_DIR/contracts/result-manifest.schema.json"

cd "$AGENT_DIR"
npm test

echo "tinglan-agentd 检查通过（Node ${NODE_MAJOR}，协议、SQLite、HTTP 和真实子进程烟测均已执行）"
