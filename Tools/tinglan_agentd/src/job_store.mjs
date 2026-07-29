import { chmodSync, mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

import { AgentError } from "./errors.mjs";

function now() {
  return new Date().toISOString();
}

const DATABASE_VERSION = 1;
const REQUIRED_JOB_COLUMNS = [
  "job_id", "request_hash", "meeting_id", "provider", "status", "attempts",
  "input_path", "result_path", "error_code", "error_message", "created_at",
  "started_at", "completed_at", "updated_at",
];
const CREATE_JOBS_SQL = `
  CREATE TABLE jobs (
    job_id TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,
    meeting_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    input_path TEXT NOT NULL,
    result_path TEXT,
    error_code TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    updated_at TEXT NOT NULL
  ) STRICT;
`;

class JobStoreSchemaError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "JobStoreSchemaError";
    this.code = code;
  }
}

export class JobStore {
  #database;
  #closed = false;

  constructor(databasePathOrOptions) {
    const databasePath = typeof databasePathOrOptions === "string"
      ? databasePathOrOptions
      : databasePathOrOptions.databasePath;
    if (!path.isAbsolute(databasePath)) throw new Error("Agent 作业库路径必须是绝对路径");
    mkdirSync(path.dirname(databasePath), { recursive: true, mode: 0o700 });
    this.databasePath = databasePath;
    this.#database = new DatabaseSync(databasePath);
    try {
      chmodSync(databasePath, 0o600);
      this.#database.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;");
      this.#migrateAndValidate();
    } catch (error) {
      this.#database.close();
      this.#closed = true;
      throw error;
    }
  }

  #migrateAndValidate() {
    const version = Number(this.#database.prepare("PRAGMA user_version").get().user_version);
    if (version > DATABASE_VERSION) {
      throw new JobStoreSchemaError("AGENT_DB_VERSION_UNSUPPORTED", `Agent 作业库版本 ${version} 高于当前支持版本 ${DATABASE_VERSION}`);
    }
    const hasJobsTable = Boolean(this.#database.prepare("SELECT 1 AS found FROM sqlite_master WHERE type = 'table' AND name = 'jobs'").get());
    if (!hasJobsTable) {
      if (version !== 0) throw new JobStoreSchemaError("AGENT_DB_SCHEMA_INVALID", `Agent 作业库 v${version} 缺少 jobs 表`);
      this.#database.exec(CREATE_JOBS_SQL);
    }
    const actualColumns = new Set(this.#database.prepare("PRAGMA table_info(jobs)").all().map((row) => row.name));
    const missing = REQUIRED_JOB_COLUMNS.filter((column) => !actualColumns.has(column));
    if (missing.length > 0) {
      throw new JobStoreSchemaError("AGENT_DB_SCHEMA_INVALID", `Agent 作业库 jobs 表缺少必需列：${missing.join(", ")}`);
    }
    this.#database.exec("CREATE INDEX IF NOT EXISTS idx_jobs_status_created ON jobs(status, created_at, job_id)");
    if (version === 0) this.#database.exec(`PRAGMA user_version = ${DATABASE_VERSION}`);
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#database.close();
  }

  createOrGet({ requestId, requestHash, meetingId, provider, inputPath }) {
    this.#database.exec("BEGIN IMMEDIATE");
    try {
      const existing = this.get(requestId);
      if (existing) {
        if (existing.request_hash !== requestHash) {
          throw new AgentError("IDEMPOTENCY_CONFLICT", "request_id 已对应不同内容", { status: 409 });
        }
        this.#database.exec("COMMIT");
        return { job: existing, created: false };
      }
      const timestamp = now();
      this.#database.prepare(`
        INSERT INTO jobs (
          job_id, request_hash, meeting_id, provider, status, attempts,
          input_path, result_path, error_code, error_message,
          created_at, started_at, completed_at, updated_at
        ) VALUES (?, ?, ?, ?, 'queued', 0, ?, NULL, NULL, NULL, ?, NULL, NULL, ?)
      `).run(requestId, requestHash, meetingId, provider, inputPath, timestamp, timestamp);
      const job = this.get(requestId);
      this.#database.exec("COMMIT");
      return { job, created: true };
    } catch (error) {
      this.#database.exec("ROLLBACK");
      throw error;
    }
  }

  claimNext() {
    this.#database.exec("BEGIN IMMEDIATE");
    try {
      const candidate = this.#database.prepare(`
        SELECT job_id FROM jobs WHERE status = 'queued' ORDER BY created_at, job_id LIMIT 1
      `).get();
      if (!candidate) {
        this.#database.exec("COMMIT");
        return null;
      }
      const timestamp = now();
      const result = this.#database.prepare(`
        UPDATE jobs
        SET status = 'running', attempts = attempts + 1, started_at = ?, updated_at = ?,
            completed_at = NULL, error_code = NULL, error_message = NULL
        WHERE job_id = ? AND status = 'queued'
      `).run(timestamp, timestamp, candidate.job_id);
      if (result.changes !== 1) {
        this.#database.exec("COMMIT");
        return null;
      }
      const job = this.get(candidate.job_id);
      this.#database.exec("COMMIT");
      return job;
    } catch (error) {
      this.#database.exec("ROLLBACK");
      throw error;
    }
  }

  markSucceeded(jobId, resultPath) {
    const timestamp = now();
    const result = this.#database.prepare(`
      UPDATE jobs
      SET status = 'succeeded', result_path = ?, error_code = NULL, error_message = NULL,
          completed_at = ?, updated_at = ?
      WHERE job_id = ? AND status = 'running'
    `).run(resultPath, timestamp, timestamp, jobId);
    if (result.changes !== 1) throw new Error(`作业 ${jobId} 当前状态不是 running`);
    return this.get(jobId);
  }

  markFailed(jobId, errorCode, errorMessage) {
    const timestamp = now();
    const summary = String(errorMessage ?? "").slice(0, 2000);
    const result = this.#database.prepare(`
      UPDATE jobs
      SET status = 'failed', error_code = ?, error_message = ?, result_path = NULL,
          completed_at = ?, updated_at = ?
      WHERE job_id = ? AND status IN ('queued', 'running')
    `).run(errorCode, summary, timestamp, timestamp, jobId);
    if (result.changes !== 1) throw new Error(`作业 ${jobId} 当前状态不能转为 failed`);
    return this.get(jobId);
  }

  get(jobId) {
    return this.#database.prepare("SELECT * FROM jobs WHERE job_id = ?").get(jobId) ?? null;
  }

  listJobIds() {
    return this.#database.prepare("SELECT job_id FROM jobs").all().map((row) => row.job_id);
  }

  recoverInterrupted() {
    const timestamp = now();
    const result = this.#database.prepare(`
      UPDATE jobs
      SET status = 'queued', started_at = NULL, completed_at = NULL, updated_at = ?,
          error_code = NULL, error_message = NULL
      WHERE status = 'running'
    `).run(timestamp);
    return Number(result.changes);
  }
}
