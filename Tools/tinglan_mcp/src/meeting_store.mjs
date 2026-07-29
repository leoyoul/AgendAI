import { DatabaseSync } from "node:sqlite";
import { contentHash, normalizeSegments } from "./content_hash.mjs";

const REQUIRED_MEETING_COLUMNS = [
  "id",
  "title",
  "status",
  "created_at",
  "started_at",
  "ended_at",
  "is_archived",
  "handoff_status",
  "handoff_started_at",
  "handoff_completed_at",
  "handoff_content_hash",
  "handoff_error",
];
const REQUIRED_SEGMENT_COLUMNS = [
  "id",
  "meeting_id",
  "start_ms",
  "end_ms",
  "raw_text",
  "processed_text",
  "final_text",
  "speaker_label",
  "person_name",
  "merged_into_id",
];

function missingColumns(db, table, required) {
  const existing = new Set(
    db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name),
  );
  return required.filter((column) => !existing.has(column));
}

export function assertHandoffSchema(db) {
  const missingMeetings = missingColumns(db, "meetings", REQUIRED_MEETING_COLUMNS);
  const missingSegments = missingColumns(
    db,
    "transcript_segments",
    REQUIRED_SEGMENT_COLUMNS,
  );
  if (missingMeetings.length || missingSegments.length) {
    const details = [
      missingMeetings.length ? `meetings: ${missingMeetings.join(", ")}` : null,
      missingSegments.length
        ? `transcript_segments: ${missingSegments.join(", ")}`
        : null,
    ]
      .filter(Boolean)
      .join("; ");
    throw new Error(
      `会小纪数据库尚未完成交接字段迁移（${details}）。请先安装并启动新版会小纪完成数据库迁移。`,
    );
  }
}

function openDatabase(
  databasePath,
  readOnly,
  busyTimeoutMs,
  { allowMeetingTitleUpdate = false } = {},
) {
  const db = new DatabaseSync(databasePath, {
    readOnly,
    allowExtension: false,
  });
  db.enableDefensive(true);
  db.exec(`PRAGMA busy_timeout=${Math.trunc(busyTimeoutMs)}`);
  db.exec("PRAGMA trusted_schema=OFF");
  if (readOnly) db.exec("PRAGMA query_only=ON");
  assertHandoffSchema(db);
  if (!readOnly) {
    const SQLITE_OK = 0;
    const SQLITE_DENY = 1;
    const SQLITE_READ = 20;
    const SQLITE_SELECT = 21;
    const SQLITE_TRANSACTION = 22;
    const SQLITE_UPDATE = 23;
    const SQLITE_FUNCTION = 31;
    const writableMeetingColumns = new Set([
      "handoff_status",
      "handoff_started_at",
      "handoff_completed_at",
      "handoff_content_hash",
      "handoff_error",
      "is_archived",
    ]);
    if (allowMeetingTitleUpdate) writableMeetingColumns.add("title");
    db.setAuthorizer((actionCode, table, column) => {
      if ([SQLITE_READ, SQLITE_SELECT, SQLITE_TRANSACTION, SQLITE_FUNCTION].includes(actionCode)) {
        return SQLITE_OK;
      }
      if (
        actionCode === SQLITE_UPDATE &&
        table === "meetings" &&
        writableMeetingColumns.has(column)
      ) {
        return SQLITE_OK;
      }
      return SQLITE_DENY;
    });
  }
  return db;
}

// 仅供边界测试验证 SQLite 的只读与列级 authorizer；MCP 不暴露数据库句柄。
export function openGuardedDatabaseForTest(databasePath, readOnly, busyTimeoutMs = 5000) {
  return openDatabase(databasePath, readOnly, busyTimeoutMs);
}

function withTransaction(db, callback) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = callback();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {}
    throw error;
  }
}

function meetingMetadata(row) {
  return {
    meeting_id: row.id,
    title: row.title,
    status: row.status,
    created_at: row.created_at,
    started_at: row.started_at,
    ended_at: row.ended_at,
    is_archived: Boolean(row.is_archived),
    handoff_status: row.handoff_status,
    handoff_started_at: row.handoff_started_at,
    handoff_completed_at: row.handoff_completed_at,
    handoff_content_hash: row.handoff_content_hash,
    handoff_error: row.handoff_error,
  };
}

export class MeetingStore {
  constructor({ databasePath, busyTimeoutMs = 5000, staleProcessingSeconds = 7200 }) {
    this.databasePath = databasePath;
    this.busyTimeoutMs = busyTimeoutMs;
    this.staleProcessingSeconds = staleProcessingSeconds;
  }

  validateSchema() {
    const db = openDatabase(this.databasePath, true, this.busyTimeoutMs);
    db.close();
  }

  #segments(db, meetingId) {
    return db
      .prepare(
        `SELECT id, meeting_id, start_ms, end_ms, raw_text, processed_text,
                final_text, speaker_label, person_name
           FROM transcript_segments
          WHERE meeting_id = ? AND merged_into_id IS NULL
          ORDER BY start_ms ASC, end_ms ASC, id ASC`,
      )
      .all(meetingId);
  }

  #directory(db) {
    const tables = new Set(
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map((row) => row.name),
    );
    if (!tables.has("people") || !tables.has("terminology_entries")) {
      return { people: [], terminology: [] };
    }
    const parseList = (value) => {
      try {
        const parsed = JSON.parse(value ?? "[]");
        return Array.isArray(parsed) ? parsed : [];
      } catch {
        return [];
      }
    };
    try {
      const people = db
        .prepare(
          `SELECT id, display_name, aliases, job_title, role_tags,
                  zentao_account, zentao_user_id
             FROM people WHERE is_active = 1 ORDER BY display_name ASC`,
        )
        .all()
        .map((row) => ({
          person_id: row.id,
          name: row.display_name,
          aliases: parseList(row.aliases),
          job_title: row.job_title,
          role_tags: parseList(row.role_tags),
          zentao_account: row.zentao_account,
          zentao_user_id: row.zentao_user_id,
        }));
      const terminology = db
        .prepare(
          `SELECT id, canonical_name, aliases, category
             FROM terminology_entries WHERE is_active = 1 ORDER BY canonical_name ASC`,
        )
        .all()
        .map((row) => ({
          entry_id: row.id,
          canonical_name: row.canonical_name,
          aliases: parseList(row.aliases),
          category: row.category,
        }));
      return { people, terminology };
    } catch {
      return { people: [], terminology: [] };
    }
  }

  #packet(db, meetingId, { requireDone = true } = {}) {
    const row = db
      .prepare(
        `SELECT id, title, status, created_at, started_at, ended_at, is_archived,
                handoff_status, handoff_started_at, handoff_completed_at,
                handoff_content_hash, handoff_error
           FROM meetings WHERE id = ?`,
      )
      .get(meetingId);
    if (!row) throw new Error(`会议不存在：${meetingId}`);
    if (requireDone && (row.status !== "done" || row.is_archived)) {
      throw new Error(`会议不是可交接状态：${meetingId}`);
    }
    const rawSegments = this.#segments(db, meetingId);
    return {
      meeting: meetingMetadata(row),
      segments: normalizeSegments(rawSegments),
      directory: this.#directory(db),
      content_hash: contentHash(row, rawSegments),
    };
  }

  getMeetingPacket(meetingId, { requireDone = true } = {}) {
    const db = openDatabase(this.databasePath, true, this.busyTimeoutMs);
    try {
      return this.#packet(db, meetingId, { requireDone });
    } finally {
      db.close();
    }
  }

  listPending({ nowSeconds = Date.now() / 1000, limit = 10 } = {}) {
    const db = openDatabase(this.databasePath, true, this.busyTimeoutMs);
    try {
      const staleBefore = nowSeconds - this.staleProcessingSeconds;
      const sql = `SELECT id, title, status, created_at, started_at, ended_at, is_archived,
                  handoff_status, handoff_started_at, handoff_completed_at,
                  handoff_content_hash, handoff_error
             FROM meetings
            WHERE (
              status = 'done' AND is_archived = 0 AND (
                handoff_status IN ('pending', 'failed') OR
                (handoff_status = 'processing' AND handoff_started_at < ?) OR
                handoff_status = 'completed'
              )
            ) OR (status = 'failed' AND is_archived = 0)
            ORDER BY COALESCE(ended_at, created_at) ASC, id ASC`;
      const rows =
        limit == null
          ? db.prepare(sql).all(staleBefore)
          : db
              .prepare(`${sql} LIMIT ?`)
              .all(staleBefore, Math.max(1, Math.min(100, Math.trunc(limit))));

      return rows.map((row) => {
        const rawSegments = this.#segments(db, row.id);
        return {
          ...meetingMetadata(row),
          segment_count: rawSegments.length,
          content_hash: contentHash(row, rawSegments),
          attention_type: row.status === "failed" ? "recording_failed" : "handoff",
        };
      });
    } finally {
      db.close();
    }
  }

  beginHandoff(meetingId, expectedHash, nowSeconds = Date.now() / 1000) {
    const db = openDatabase(this.databasePath, false, this.busyTimeoutMs);
    try {
      return withTransaction(db, () => {
        const packet = this.#packet(db, meetingId);
        if (packet.content_hash !== expectedHash) {
          throw new Error("会议内容已变化，请按新 content_hash 重新处理");
        }
        const row = packet.meeting;
        if (
          row.handoff_status === "processing" &&
          row.handoff_content_hash === expectedHash &&
          row.handoff_started_at >= nowSeconds - this.staleProcessingSeconds
        ) {
          return { state: "already_processing", ...packet };
        }
        const result = db
          .prepare(
            `UPDATE meetings
                SET handoff_status = 'processing', handoff_started_at = ?,
                    handoff_completed_at = NULL, handoff_content_hash = ?,
                    handoff_error = NULL
              WHERE id = ? AND status = 'done' AND is_archived = 0 AND (
                handoff_status IN ('pending', 'failed') OR
                (handoff_status = 'processing' AND handoff_started_at < ?)
              )`,
          )
          .run(
            nowSeconds,
            expectedHash,
            meetingId,
            nowSeconds - this.staleProcessingSeconds,
          );
        if (result.changes !== 1) {
          throw new Error("会议交接状态已被其他流程修改");
        }
        return { state: "started", ...packet };
      });
    } finally {
      db.close();
    }
  }

  markHandoffFailed(meetingId, expectedHash, message) {
    const db = openDatabase(this.databasePath, false, this.busyTimeoutMs);
    try {
      const result = db
        .prepare(
          `UPDATE meetings
              SET handoff_status = 'failed', handoff_error = ?
            WHERE id = ? AND status = 'done' AND is_archived = 0
              AND handoff_status = 'processing' AND handoff_content_hash = ?`,
        )
        .run(String(message).slice(0, 1000), meetingId, expectedHash);
      return result.changes === 1;
    } finally {
      db.close();
    }
  }

  prepareHandoffReview(meetingId, expectedHash, nowSeconds = Date.now() / 1000) {
    const db = openDatabase(this.databasePath, false, this.busyTimeoutMs);
    try {
      const outcome = withTransaction(db, () => {
        const packet = this.#packet(db, meetingId, { requireDone: false });
        if (packet.content_hash !== expectedHash) {
          db.prepare(
            `UPDATE meetings
                SET handoff_status = 'pending', handoff_started_at = NULL,
                    handoff_completed_at = NULL, handoff_content_hash = NULL,
                    handoff_error = '会议内容在交接过程中发生变化'
              WHERE id = ? AND status = 'done' AND is_archived = 0
                AND handoff_status = 'processing' AND handoff_content_hash = ?`,
          ).run(meetingId, expectedHash);
          return { state: "content_changed" };
        }
        const row = packet.meeting;
        if (
          row.status === "done" &&
          !row.is_archived &&
          row.handoff_status === "completed" &&
          row.handoff_content_hash === expectedHash
        ) {
          return { state: "already_review_ready", packet };
        }
        const result = db
          .prepare(
            `UPDATE meetings
                SET handoff_status = 'completed', handoff_completed_at = ?,
                    handoff_content_hash = ?, handoff_error = NULL, is_archived = 0
              WHERE id = ? AND status = 'done' AND is_archived = 0
                AND handoff_status = 'processing' AND handoff_content_hash = ?`,
          )
          .run(nowSeconds, expectedHash, meetingId, expectedHash);
        if (result.changes !== 1) {
          throw new Error("会议尚未完成摘要与 Obsidian 交付，不能进入人工确认");
        }
        return { state: "review_ready", packet };
      });
      if (outcome.state === "content_changed") {
        throw new Error("会议内容在交接过程中发生变化，已重新排队");
      }
      return outcome;
    } finally {
      db.close();
    }
  }

  completeHandoff(meetingId, expectedHash, nowSeconds = Date.now() / 1000) {
    const db = openDatabase(this.databasePath, false, this.busyTimeoutMs);
    try {
      const outcome = withTransaction(db, () => {
        const packet = this.#packet(db, meetingId, { requireDone: false });
        if (
          packet.meeting.status === "done" &&
          packet.meeting.is_archived &&
          packet.meeting.handoff_status === "completed" &&
          packet.meeting.handoff_content_hash === expectedHash
        ) {
          return { state: "already_completed", packet };
        }
        if (packet.content_hash !== expectedHash) {
          db.prepare(
            `UPDATE meetings
                SET handoff_status = 'pending', handoff_started_at = NULL,
                    handoff_completed_at = NULL, handoff_content_hash = NULL,
                    handoff_error = '会议内容在交接过程中发生变化'
              WHERE id = ? AND status = 'done' AND is_archived = 0
                AND handoff_status IN ('processing', 'completed') AND handoff_content_hash = ?`,
          ).run(meetingId, expectedHash);
          return { state: "content_changed" };
        }
        const result = db
          .prepare(
            `UPDATE meetings
                SET handoff_status = 'completed', handoff_completed_at = ?,
                    handoff_content_hash = ?, handoff_error = NULL, is_archived = 1
              WHERE id = ? AND status = 'done' AND is_archived = 0
                AND handoff_status = 'completed' AND handoff_content_hash = ?`,
          )
          .run(nowSeconds, expectedHash, meetingId, expectedHash);
        if (result.changes !== 1) {
          throw new Error("会议完成或归档状态已被其他流程修改");
        }
        return { state: "completed", packet };
      });
      if (outcome.state === "content_changed") {
        throw new Error("会议内容在交接过程中发生变化，已重新排队");
      }
      return outcome;
    } finally {
      db.close();
    }
  }

  updateCompletedMeetingTitle(meetingId, expectedHash, title) {
    const normalizedTitle = String(title ?? "").normalize("NFC").trim();
    if (!normalizedTitle) throw new Error("会议标题不能为空");
    const db = openDatabase(this.databasePath, false, this.busyTimeoutMs, {
      allowMeetingTitleUpdate: true,
    });
    try {
      return withTransaction(db, () => {
        const packet = this.#packet(db, meetingId, { requireDone: false });
        const meeting = packet.meeting;
        if (
          meeting.status !== "done" ||
          meeting.handoff_status !== "completed" ||
          meeting.handoff_content_hash !== expectedHash
        ) {
          throw new Error("会议不是可修订标题的已完成交接版本");
        }
        if (meeting.title === normalizedTitle) {
          return { state: "already_updated", title: normalizedTitle };
        }
        const result = db
          .prepare(
            `UPDATE meetings SET title = ?
              WHERE id = ? AND status = 'done' AND handoff_status = 'completed'
                AND handoff_content_hash = ?`,
          )
          .run(normalizedTitle, meetingId, expectedHash);
        if (result.changes !== 1) throw new Error("会议标题更新状态已被其他流程修改");
        return { state: "updated", title: normalizedTitle };
      });
    } finally {
      db.close();
    }
  }
}
