import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { sha256 } from "./content_hash.mjs";

const DESTINATIONS = ["codex", "obsidian", "zentao_candidates", "failure_notice"];

function nowSeconds() {
  return Date.now() / 1000;
}

function normalizeCandidateText(value) {
  return String(value ?? "")
    .normalize("NFC")
    .replace(/\r\n?/g, "\n")
    .trim();
}

export function stableCandidateId(meetingId, contentHash, candidate) {
  const key = {
    meeting_id: meetingId,
    content_hash: contentHash,
    evidence: normalizeCandidateText(candidate.evidence),
    title: normalizeCandidateText(candidate.title),
  };
  return sha256(JSON.stringify(key));
}

function withTransaction(db, callback) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const value = callback();
    db.exec("COMMIT");
    return value;
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {}
    throw error;
  }
}

export class SyncLedger {
  constructor({ ledgerPath, busyTimeoutMs = 5000 }) {
    this.ledgerPath = ledgerPath;
    fs.mkdirSync(path.dirname(ledgerPath), { recursive: true, mode: 0o700 });
    fs.chmodSync(path.dirname(ledgerPath), 0o700);
    this.db = new DatabaseSync(ledgerPath, { allowExtension: false });
    this.db.enableDefensive(true);
    this.db.exec(`PRAGMA busy_timeout=${Math.trunc(busyTimeoutMs)}`);
    this.db.exec("PRAGMA journal_mode=WAL");
    this.db.exec("PRAGMA foreign_keys=ON");
    this.db.exec("PRAGMA trusted_schema=OFF");
    this.#migrate();
    fs.chmodSync(ledgerPath, 0o600);
  }

  close() {
    this.db.close();
  }

  #migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS deliveries (
        meeting_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        destination TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('succeeded', 'failed')),
        attempts INTEGER NOT NULL DEFAULT 0,
        error_summary TEXT,
        external_ref TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (meeting_id, content_hash, destination)
      );

      CREATE TABLE IF NOT EXISTS artifacts (
        meeting_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('codex_summary', 'obsidian_source', 'obsidian_draft')),
        content TEXT,
        path TEXT,
        checksum TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (meeting_id, content_hash, kind)
      );

      CREATE TABLE IF NOT EXISTS task_candidates (
        candidate_id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        evidence TEXT NOT NULL,
        assignee TEXT,
        due_date TEXT,
        status TEXT NOT NULL CHECK (status IN ('awaiting_approval', 'creating', 'created', 'skipped')),
        zentao_task_id TEXT,
        zentao_url TEXT,
        obsidian_path TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_candidates_meeting_version
        ON task_candidates(meeting_id, content_hash, created_at);

      CREATE TABLE IF NOT EXISTS failure_notice_claims (
        meeting_id TEXT PRIMARY KEY,
        content_hash TEXT NOT NULL,
        claimed_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS handoff_reviews (
        meeting_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('pending', 'changes_requested', 'confirmed')),
        attendees_json TEXT NOT NULL DEFAULT '[]',
        context_json TEXT NOT NULL DEFAULT '{}',
        corrections TEXT NOT NULL DEFAULT '',
        confirmed_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (meeting_id, content_hash)
      );

      CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY,
        started_at REAL NOT NULL,
        completed_at REAL,
        result_count INTEGER NOT NULL DEFAULT 0,
        error_summary TEXT
      );
    `);
    // Successful deliveries must never retain a failure message. This also repairs
    // ledgers written by the earlier Obsidian argument-order bug.
    this.db.exec(
      "UPDATE deliveries SET error_summary = NULL WHERE status = 'succeeded' AND error_summary IS NOT NULL",
    );
  }

  #record(meetingId, contentHash, destination, status, error = null, externalRef = null) {
    if (!DESTINATIONS.includes(destination)) {
      throw new Error(`不支持的交付目的地：${destination}`);
    }
    const timestamp = nowSeconds();
    this.db
      .prepare(
        `INSERT INTO deliveries (
           meeting_id, content_hash, destination, status, attempts,
           error_summary, external_ref, created_at, updated_at
         ) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
         ON CONFLICT(meeting_id, content_hash, destination) DO UPDATE SET
           status = excluded.status,
           attempts = deliveries.attempts + 1,
           error_summary = excluded.error_summary,
           external_ref = COALESCE(excluded.external_ref, deliveries.external_ref),
           updated_at = excluded.updated_at`,
      )
      .run(
        meetingId,
        contentHash,
        destination,
        status,
        error == null ? null : String(error).slice(0, 1000),
        externalRef == null ? null : JSON.stringify(externalRef),
        timestamp,
        timestamp,
      );
  }

  recordFailure(meetingId, contentHash, destination, error) {
    this.#record(meetingId, contentHash, destination, "failed", error);
  }

  recordSuccess(meetingId, contentHash, destination, externalRef = null) {
    this.#record(meetingId, contentHash, destination, "succeeded", null, externalRef);
  }

  saveSummary(meetingId, contentHash, summary) {
    const normalized = String(summary ?? "").replace(/\r\n?/g, "\n").trim();
    if (!normalized) throw new Error("Codex 摘要不能为空");
    return withTransaction(this.db, () => {
      const timestamp = nowSeconds();
      const succeeded = this.hasSucceeded(meetingId, contentHash, "codex");
      if (!succeeded) {
        this.db
          .prepare(
            `INSERT INTO artifacts (
               meeting_id, content_hash, kind, content, path, checksum, created_at, updated_at
             ) VALUES (?, ?, 'codex_summary', ?, NULL, ?, ?, ?)
             ON CONFLICT(meeting_id, content_hash, kind) DO UPDATE SET
               content = excluded.content,
               checksum = excluded.checksum,
               updated_at = excluded.updated_at`,
          )
          .run(
            meetingId,
            contentHash,
            normalized,
            sha256(normalized),
            timestamp,
            timestamp,
          );
      }
      this.#record(meetingId, contentHash, "codex", "succeeded");
      return this.getArtifact(meetingId, contentHash, "codex_summary");
    });
  }

  updateSummaryArtifact(meetingId, contentHash, summary) {
    const normalized = String(summary ?? "").replace(/\r\n?/g, "\n").trim();
    if (!normalized) throw new Error("Codex 摘要不能为空");
    const timestamp = nowSeconds();
    const result = this.db
      .prepare(
        `UPDATE artifacts SET content = ?, checksum = ?, updated_at = ?
          WHERE meeting_id = ? AND content_hash = ? AND kind = 'codex_summary'`,
      )
      .run(
        normalized,
        sha256(normalized),
        timestamp,
        meetingId,
        contentHash,
      );
    if (result.changes !== 1) throw new Error("Codex 摘要账本不存在");
    return this.getArtifact(meetingId, contentHash, "codex_summary");
  }

  saveFileArtifacts(meetingId, contentHash, source, draft) {
    return withTransaction(this.db, () => {
      const timestamp = nowSeconds();
      const insert = this.db.prepare(
        `INSERT INTO artifacts (
           meeting_id, content_hash, kind, content, path, checksum, created_at, updated_at
         ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?)
         ON CONFLICT(meeting_id, content_hash, kind) DO UPDATE SET
           path = excluded.path, checksum = excluded.checksum, updated_at = excluded.updated_at`,
      );
      insert.run(
        meetingId,
        contentHash,
        "obsidian_source",
        source.path,
        source.checksum,
        timestamp,
        timestamp,
      );
      insert.run(
        meetingId,
        contentHash,
        "obsidian_draft",
        draft.path,
        draft.checksum,
        timestamp,
        timestamp,
      );
      this.#record(
        meetingId,
        contentHash,
        "obsidian",
        "succeeded",
        null,
        {
          source_path: source.path,
          draft_path: draft.path,
        },
      );
    });
  }

  updateDraftArtifact(meetingId, contentHash, draft) {
    const timestamp = nowSeconds();
    const result = this.db
      .prepare(
        `UPDATE artifacts SET path = ?, checksum = ?, updated_at = ?
          WHERE meeting_id = ? AND content_hash = ? AND kind = 'obsidian_draft'`,
      )
      .run(draft.path, draft.checksum, timestamp, meetingId, contentHash);
    if (result.changes !== 1) throw new Error("Obsidian 草稿账本不存在");
  }

  updateCandidateObsidianPath(meetingId, contentHash, draftPath) {
    const timestamp = nowSeconds();
    this.db
      .prepare(
        `UPDATE task_candidates SET obsidian_path = ?, updated_at = ?
          WHERE meeting_id = ? AND content_hash = ?`,
      )
      .run(draftPath, timestamp, meetingId, contentHash);
  }

  ensureReview(meetingId, contentHash) {
    const timestamp = nowSeconds();
    this.db
      .prepare(
        `INSERT INTO handoff_reviews (
           meeting_id, content_hash, status, attendees_json, context_json,
           corrections, confirmed_at, created_at, updated_at
         ) VALUES (?, ?, 'pending', '[]', '{}', '', NULL, ?, ?)
         ON CONFLICT(meeting_id, content_hash) DO NOTHING`,
      )
      .run(meetingId, contentHash, timestamp, timestamp);
    return this.getReview(meetingId, contentHash);
  }

  getReview(meetingId, contentHash) {
    const row = this.db
      .prepare(
        `SELECT meeting_id, content_hash, status, attendees_json, context_json,
                corrections, confirmed_at, created_at, updated_at
           FROM handoff_reviews WHERE meeting_id = ? AND content_hash = ?`,
      )
      .get(meetingId, contentHash);
    if (!row) return null;
    return {
      meeting_id: row.meeting_id,
      content_hash: row.content_hash,
      status: row.status,
      attendees: JSON.parse(row.attendees_json),
      context: JSON.parse(row.context_json),
      corrections: row.corrections,
      confirmed_at: row.confirmed_at,
      created_at: row.created_at,
      updated_at: row.updated_at,
    };
  }

  saveReviewConfirmation(
    meetingId,
    contentHash,
    { attendees = [], context = {}, corrections = "", confirmed },
  ) {
    if (!Array.isArray(attendees)) throw new Error("attendees 必须是数组");
    if (context == null || typeof context !== "object" || Array.isArray(context)) {
      throw new Error("context 必须是对象");
    }
    if (typeof confirmed !== "boolean") throw new Error("confirmed 必须是布尔值");
    const normalizedAttendees = attendees.map((attendee) => ({
      name: normalizeCandidateText(attendee?.name),
      role: normalizeCandidateText(attendee?.role) || null,
    }));
    if (normalizedAttendees.some((attendee) => !attendee.name)) {
      throw new Error("每位参会人员都必须提供姓名");
    }
    const normalizedContext = Object.fromEntries(
      Object.entries(context)
        .map(([key, value]) => [String(key), normalizeCandidateText(value)])
        .sort(([left], [right]) => left.localeCompare(right, "en")),
    );
    const normalizedCorrections = Array.isArray(corrections)
      ? corrections.map(normalizeCandidateText).filter(Boolean).join("\n")
      : normalizeCandidateText(corrections);
    return withTransaction(this.db, () => {
      const existing = this.getReview(meetingId, contentHash) ?? this.ensureReview(meetingId, contentHash);
      if (existing.status === "confirmed") {
        const same =
          JSON.stringify(existing.attendees) === JSON.stringify(normalizedAttendees) &&
          JSON.stringify(existing.context) === JSON.stringify(normalizedContext) &&
          existing.corrections === normalizedCorrections &&
          confirmed;
        if (same) return { ...existing, state: "already_confirmed" };
        throw new Error("人工确认已完成，不能用不同内容覆盖");
      }
      const status = confirmed ? "confirmed" : "changes_requested";
      const timestamp = nowSeconds();
      this.db
        .prepare(
          `UPDATE handoff_reviews SET status = ?, attendees_json = ?, context_json = ?,
                  corrections = ?, confirmed_at = ?, updated_at = ?
             WHERE meeting_id = ? AND content_hash = ?`,
        )
        .run(
          status,
          JSON.stringify(normalizedAttendees),
          JSON.stringify(normalizedContext),
          normalizedCorrections,
          confirmed ? timestamp : null,
          timestamp,
          meetingId,
          contentHash,
        );
      return { ...this.getReview(meetingId, contentHash), state: status };
    });
  }

  saveCandidates(meetingId, contentHash, candidates, obsidianPath = null) {
    if (!Array.isArray(candidates)) throw new Error("candidates 必须是数组");
    return withTransaction(this.db, () => {
      const timestamp = nowSeconds();
      const statement = this.db.prepare(
        `INSERT INTO task_candidates (
           candidate_id, meeting_id, content_hash, title, description, evidence,
           assignee, due_date, status, zentao_task_id, zentao_url, obsidian_path,
           created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(candidate_id) DO UPDATE SET
           title = excluded.title,
           description = excluded.description,
           evidence = excluded.evidence,
           assignee = excluded.assignee,
           due_date = excluded.due_date,
           status = CASE
             WHEN task_candidates.status IN ('created', 'skipped')
               THEN task_candidates.status
             WHEN task_candidates.status = 'creating'
                  AND excluded.status = 'awaiting_approval'
               THEN task_candidates.status
             ELSE excluded.status
           END,
           zentao_task_id = COALESCE(task_candidates.zentao_task_id, excluded.zentao_task_id),
           zentao_url = COALESCE(task_candidates.zentao_url, excluded.zentao_url),
           obsidian_path = COALESCE(excluded.obsidian_path, task_candidates.obsidian_path),
           updated_at = excluded.updated_at`,
      );
      candidates.map((candidate) => {
        const title = normalizeCandidateText(candidate.title);
        const evidence = normalizeCandidateText(candidate.evidence);
        if (!title || !evidence) {
          throw new Error("每个禅道候选都必须包含非空 title 和 evidence");
        }
        const status = candidate.status ?? "awaiting_approval";
        if (!["awaiting_approval", "creating", "created", "skipped"].includes(status)) {
          throw new Error(`不支持的候选状态：${status}`);
        }
        const zentaoTaskId = normalizeCandidateText(candidate.zentao_task_id);
        if (status === "created" && !zentaoTaskId) {
          throw new Error("created 候选必须包含 zentao_task_id");
        }
        const candidateId = stableCandidateId(meetingId, contentHash, {
          title,
          evidence,
        });
        statement.run(
          candidateId,
          meetingId,
          contentHash,
          title,
          normalizeCandidateText(candidate.description),
          evidence,
          normalizeCandidateText(candidate.assignee) || null,
          normalizeCandidateText(candidate.due_date) || null,
          status,
          zentaoTaskId || null,
          normalizeCandidateText(candidate.zentao_url) || null,
          obsidianPath,
          timestamp,
          timestamp,
        );
        return candidateId;
      });
      return this.listCandidates(meetingId, contentHash);
    });
  }

  hasFailureNoticeClaim(meetingId) {
    return Boolean(
      this.db
        .prepare("SELECT 1 AS found FROM failure_notice_claims WHERE meeting_id = ?")
        .get(meetingId),
    );
  }

  claimFailureNotice(meetingId, contentHash) {
    return withTransaction(this.db, () => {
      const result = this.db
        .prepare(
          `INSERT INTO failure_notice_claims (meeting_id, content_hash, claimed_at)
           VALUES (?, ?, ?) ON CONFLICT(meeting_id) DO NOTHING`,
        )
        .run(meetingId, contentHash, nowSeconds());
      if (result.changes !== 1) return false;
      this.#record(meetingId, contentHash, "failure_notice", "succeeded");
      return true;
    });
  }

  listFailedDeliveries(destination) {
    if (!DESTINATIONS.includes(destination)) {
      throw new Error(`不支持的交付目的地：${destination}`);
    }
    return this.db
      .prepare(
        `SELECT meeting_id, content_hash, updated_at
           FROM deliveries WHERE destination = ? AND status = 'failed'
          ORDER BY updated_at ASC, meeting_id ASC`,
      )
      .all(destination);
  }

  getArtifact(meetingId, contentHash, kind) {
    return (
      this.db
        .prepare(
          `SELECT meeting_id, content_hash, kind, content, path, checksum, created_at, updated_at
             FROM artifacts WHERE meeting_id = ? AND content_hash = ? AND kind = ?`,
        )
        .get(meetingId, contentHash, kind) ?? null
    );
  }

  listCandidates(meetingId, contentHash) {
    return this.db
      .prepare(
        `SELECT candidate_id, title, description, evidence, assignee, due_date,
                status, zentao_task_id, zentao_url, obsidian_path
           FROM task_candidates
          WHERE meeting_id = ? AND content_hash = ?
          ORDER BY created_at ASC, candidate_id ASC`,
      )
      .all(meetingId, contentHash);
  }

  hasSucceeded(meetingId, contentHash, destination) {
    const row = this.db
      .prepare(
        `SELECT 1 AS found FROM deliveries
          WHERE meeting_id = ? AND content_hash = ? AND destination = ?
            AND status = 'succeeded'`,
      )
      .get(meetingId, contentHash, destination);
    return Boolean(row);
  }

  hasFailed(meetingId, contentHash, destination) {
    const row = this.db
      .prepare(
        `SELECT 1 AS found FROM deliveries
          WHERE meeting_id = ? AND content_hash = ? AND destination = ?
            AND status = 'failed'`,
      )
      .get(meetingId, contentHash, destination);
    return Boolean(row);
  }

  pendingDestinations(meetingId, contentHash) {
    const pending = ["codex", "obsidian", "zentao_candidates"].filter(
      (destination) => !this.hasSucceeded(meetingId, contentHash, destination),
    );
    const review = this.getReview(meetingId, contentHash);
    if (review && review.status !== "confirmed") {
      return ["human_review", ...pending.filter((destination) => destination === "zentao_candidates")];
    }
    return pending;
  }

  getStatus(meetingId, contentHash) {
    const deliveries = this.db
      .prepare(
        `SELECT destination, status, attempts, error_summary, external_ref, updated_at
           FROM deliveries WHERE meeting_id = ? AND content_hash = ?
          ORDER BY destination ASC`,
      )
      .all(meetingId, contentHash)
      .map((row) => ({
        ...row,
        external_ref: row.external_ref ? JSON.parse(row.external_ref) : null,
      }));
    return {
      meeting_id: meetingId,
      content_hash: contentHash,
      deliveries,
      artifacts: [
        this.getArtifact(meetingId, contentHash, "codex_summary"),
        this.getArtifact(meetingId, contentHash, "obsidian_source"),
        this.getArtifact(meetingId, contentHash, "obsidian_draft"),
      ].filter(Boolean),
      task_candidates: this.listCandidates(meetingId, contentHash),
      review: this.getReview(meetingId, contentHash),
      pending_destinations: this.pendingDestinations(meetingId, contentHash),
    };
  }
}
