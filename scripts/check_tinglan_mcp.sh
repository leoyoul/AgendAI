#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MCP_DIR="$ROOT_DIR/Tools/tinglan_mcp"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"

if [ ! -x "$NODE_BIN" ]; then
    echo "缺少会小纪 MCP 所需 Node：$NODE_BIN"
    exit 1
fi

node_major="$($NODE_BIN -p 'process.versions.node.split(".")[0]')"
if [ "$node_major" -ne 25 ]; then
    echo "会小纪 MCP 当前锁定 Node 25，实际版本：$($NODE_BIN --version)"
    exit 1
fi

cd "$MCP_DIR"

if [ ! -d node_modules ]; then
    npm ci --ignore-scripts
fi

npm ls --omit=dev >/dev/null

for file in src/*.mjs; do
    "$NODE_BIN" --check "$file"
done

"$NODE_BIN" --test

if [ "${TINGLAN_VALIDATE_REAL_DB:-0}" = "1" ]; then
    "$NODE_BIN" --no-warnings --input-type=module -e '
        import { loadConfig } from "./src/config.mjs";
        import { MeetingStore } from "./src/meeting_store.mjs";
        const config = loadConfig();
        new MeetingStore({
          databasePath: config.databasePath,
          busyTimeoutMs: config.busyTimeoutMs,
          staleProcessingSeconds: config.staleProcessingSeconds,
        }).validateSchema();
        process.stdout.write("真实会小纪数据库 MCP schema 检查通过\n");
    '
fi

echo "会小纪 MCP 检查通过"
