#!/opt/homebrew/bin/node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const execute = process.argv.includes("--execute");
const meetingIds = process.argv.slice(2).filter((value) => value !== "--execute");

if (!meetingIds.length) {
  throw new Error("请提供至少一个 meeting_id");
}
if (new Set(meetingIds).size !== meetingIds.length) {
  throw new Error("meeting_id 不能重复");
}

const home = os.homedir();
const databasePath = process.env.TINGLAN_DB_PATH ??
  path.join(home, "Library/Application Support/会小纪/ai-tingji.sqlite");
const ledgerPath = process.env.TINGLAN_LEDGER_PATH ??
  path.join(home, "Library/Application Support/会小纪 Codex Bridge/sync.sqlite");
const obsidianRoot = path.resolve(
  process.env.TINGLAN_OBSIDIAN_ROOT ?? path.join(home, "Documents/AgendAI"),
);
const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "Z");
const backupRoot = path.join(
  home,
  "Library/Application Support/会小纪 Codex Bridge/Backups",
  `minutes-rebuild-${stamp}`,
);

function placeholders(values) {
  return values.map(() => "?").join(", ");
}

function ensureFile(filePath, label) {
  const stat = fs.statSync(filePath);
  if (!stat.isFile()) throw new Error(`${label} 不是普通文件：${filePath}`);
}

ensureFile(databasePath, "会小纪数据库");
ensureFile(ledgerPath, "同步账本");

const database = new DatabaseSync(databasePath, { readOnly: true, allowExtension: false });
database.exec("PRAGMA query_only=ON");
const meetings = database
  .prepare(
    `SELECT id, title, status, is_archived, handoff_status, handoff_content_hash
       FROM meetings WHERE id IN (${placeholders(meetingIds)}) ORDER BY id`,
  )
  .all(...meetingIds);
database.close();

if (meetings.length !== meetingIds.length) {
  const found = new Set(meetings.map((meeting) => meeting.id));
  throw new Error(`会议不存在：${meetingIds.filter((id) => !found.has(id)).join(", ")}`);
}
for (const meeting of meetings) {
  if (
    meeting.status !== "done" ||
    meeting.is_archived !== 1 ||
    meeting.handoff_status !== "completed" ||
    !meeting.handoff_content_hash
  ) {
    throw new Error(`会议不是可安全重建的已归档版本：${meeting.id}`);
  }
}

const ledger = new DatabaseSync(ledgerPath, { readOnly: true, allowExtension: false });
ledger.exec("PRAGMA query_only=ON");
const terminalCandidates = ledger
  .prepare(
    `SELECT meeting_id, candidate_id, status FROM task_candidates
      WHERE meeting_id IN (${placeholders(meetingIds)}) AND status IN ('creating', 'created')`,
  )
  .all(...meetingIds);
if (terminalCandidates.length) {
  ledger.close();
  throw new Error("存在创建中或已创建的禅道任务候选，拒绝清理交付账本");
}
const draftArtifacts = ledger
  .prepare(
    `SELECT meeting_id, path FROM artifacts
      WHERE meeting_id IN (${placeholders(meetingIds)}) AND kind = 'obsidian_draft'`,
  )
  .all(...meetingIds);
ledger.close();

const realRoot = fs.realpathSync(obsidianRoot);
for (const artifact of draftArtifacts) {
  if (!artifact.path || !fs.existsSync(artifact.path)) continue;
  const realDraft = fs.realpathSync(artifact.path);
  if (!realDraft.startsWith(`${realRoot}${path.sep}`)) {
    throw new Error(`草稿不在 Obsidian 根目录内：${artifact.path}`);
  }
}

const preview = {
  execute,
  backup_root: backupRoot,
  meetings: meetings.map(({ id, title }) => ({ id, title })),
  draft_count: draftArtifacts.length,
};
if (!execute) {
  process.stdout.write(`${JSON.stringify(preview, null, 2)}\n`);
  process.exit(0);
}

fs.mkdirSync(backupRoot, { recursive: true, mode: 0o700 });
const sqlite3 = "/usr/bin/sqlite3";
for (const [source, target] of [
  [databasePath, path.join(backupRoot, "ai-tingji.sqlite")],
  [ledgerPath, path.join(backupRoot, "sync.sqlite")],
]) {
  const result = spawnSync(sqlite3, [source, `.backup '${target.replaceAll("'", "''")}'`], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`SQLite 备份失败：${result.stderr || result.stdout}`);
  }
  const check = spawnSync(sqlite3, [target, "PRAGMA integrity_check;"], { encoding: "utf8" });
  if (check.status !== 0 || check.stdout.trim() !== "ok") {
    throw new Error(`SQLite 备份完整性检查失败：${target}`);
  }
}

const draftBackupDirectory = path.join(backupRoot, "drafts");
fs.mkdirSync(draftBackupDirectory, { recursive: true, mode: 0o700 });
const movedDrafts = [];
try {
  for (const artifact of draftArtifacts) {
    if (!artifact.path || !fs.existsSync(artifact.path)) continue;
    const target = path.join(
      draftBackupDirectory,
      `${artifact.meeting_id}-${path.basename(artifact.path)}`,
    );
    fs.copyFileSync(artifact.path, target, fs.constants.COPYFILE_EXCL);
    fs.unlinkSync(artifact.path);
    movedDrafts.push({ source: artifact.path, backup: target });
  }

  const writer = new DatabaseSync(databasePath, { allowExtension: false });
  writer.exec("PRAGMA busy_timeout=5000");
  writer.prepare("ATTACH DATABASE ? AS ledger").run(ledgerPath);
  writer.exec("BEGIN IMMEDIATE");
  try {
    const args = meetingIds;
    writer
      .prepare(`DELETE FROM ledger.task_candidates WHERE meeting_id IN (${placeholders(args)})`)
      .run(...args);
    writer
      .prepare(`DELETE FROM ledger.artifacts WHERE meeting_id IN (${placeholders(args)})`)
      .run(...args);
    writer
      .prepare(`DELETE FROM ledger.deliveries WHERE meeting_id IN (${placeholders(args)})`)
      .run(...args);
    writer
      .prepare(`DELETE FROM ledger.handoff_reviews WHERE meeting_id IN (${placeholders(args)})`)
      .run(...args);
    const updated = writer
      .prepare(
        `UPDATE meetings
            SET is_archived = 0,
                handoff_status = 'pending',
                handoff_started_at = NULL,
                handoff_completed_at = NULL,
                handoff_content_hash = NULL,
                handoff_error = NULL
          WHERE id IN (${placeholders(args)})
            AND status = 'done' AND is_archived = 1 AND handoff_status = 'completed'`,
      )
      .run(...args);
    if (updated.changes !== meetingIds.length) {
      throw new Error(`仅重排队 ${updated.changes}/${meetingIds.length} 场会议`);
    }
    writer.exec("COMMIT");
  } catch (error) {
    writer.exec("ROLLBACK");
    throw error;
  } finally {
    writer.close();
  }
} catch (error) {
  for (const draft of movedDrafts.reverse()) {
    if (!fs.existsSync(draft.source) && fs.existsSync(draft.backup)) {
      fs.copyFileSync(draft.backup, draft.source);
    }
  }
  throw error;
}

spawnSync("/usr/bin/notifyutil", ["-p", "io.github.leoyoul.agendai.handoff.changed"]);
process.stdout.write(`${JSON.stringify({ ...preview, requeued: meetingIds.length }, null, 2)}\n`);
