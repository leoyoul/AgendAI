import os from "node:os";
import path from "node:path";

const DEFAULT_DATABASE_PATH = path.join(
  os.homedir(),
  "Library/Application Support/会小纪/ai-tingji.sqlite",
);
const DEFAULT_LEDGER_PATH = path.join(
  os.homedir(),
  "Library/Application Support/会小纪 Codex Bridge/sync.sqlite",
);
const DEFAULT_OBSIDIAN_ROOT = path.join(os.homedir(), "Documents/AgendAI");

function absolutePath(value, name) {
  if (!path.isAbsolute(value)) {
    throw new Error(`${name} 必须是绝对路径`);
  }
  return path.normalize(value);
}

export function loadConfig(env = process.env) {
  const busyTimeoutMs = Number.parseInt(env.TINGLAN_BUSY_TIMEOUT_MS ?? "5000", 10);
  if (!Number.isFinite(busyTimeoutMs) || busyTimeoutMs < 1 || busyTimeoutMs > 60_000) {
    throw new Error("TINGLAN_BUSY_TIMEOUT_MS 必须在 1 到 60000 之间");
  }

  return Object.freeze({
    databasePath: absolutePath(
      env.TINGLAN_DB_PATH ?? DEFAULT_DATABASE_PATH,
      "TINGLAN_DB_PATH",
    ),
    ledgerPath: absolutePath(
      env.TINGLAN_LEDGER_PATH ?? DEFAULT_LEDGER_PATH,
      "TINGLAN_LEDGER_PATH",
    ),
    obsidianRoot: absolutePath(
      env.TINGLAN_OBSIDIAN_ROOT ?? DEFAULT_OBSIDIAN_ROOT,
      "TINGLAN_OBSIDIAN_ROOT",
    ),
    notifyutilPath: absolutePath(
      env.TINGLAN_NOTIFYUTIL_PATH ?? "/usr/bin/notifyutil",
      "TINGLAN_NOTIFYUTIL_PATH",
    ),
    notifyKey: "io.github.leoyoul.agendai.handoff.changed",
    busyTimeoutMs,
    staleProcessingSeconds: 2 * 60 * 60,
    maxPendingMeetings: 10,
  });
}
