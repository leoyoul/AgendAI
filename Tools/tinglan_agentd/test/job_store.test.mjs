import assert from "node:assert/strict";
import { lstat } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { JobStore } from "../src/job_store.mjs";
import { makeTempDir } from "./helpers.mjs";

async function makeStore() {
  const root = await makeTempDir();
  const databasePath = path.join(root, "agent.sqlite");
  return { root, databasePath, store: new JobStore(databasePath) };
}

function jobInput(id = "job-1", hash = "a".repeat(64)) {
  return {
    requestId: id,
    requestHash: hash,
    meetingId: "meeting-1",
    provider: "mock",
    inputPath: `/tmp/${id}/input`,
  };
}

test("作业库：创建作业并按 request_id 幂等复用", async (t) => {
  const { store, databasePath } = await makeStore();
  t.after(() => store.close());
  const first = store.createOrGet(jobInput());
  assert.equal(first.created, true);
  assert.equal(first.job.job_id, "job-1");
  assert.equal(first.job.status, "queued");
  const second = store.createOrGet(jobInput());
  assert.equal(second.created, false);
  assert.deepEqual(second.job, first.job);
  assert.equal((await lstat(databasePath)).mode & 0o777, 0o600);
  const inspector = new DatabaseSync(databasePath);
  assert.equal(inspector.prepare("PRAGMA user_version").get().user_version, 1);
  inspector.close();
});

test("作业库：user_version 0 的正确 jobs 表升级到 v1", async () => {
  const root = await makeTempDir();
  const databasePath = path.join(root, "agent.sqlite");
  const legacy = new DatabaseSync(databasePath);
  legacy.exec(`
    CREATE TABLE jobs (
      job_id TEXT PRIMARY KEY, request_hash TEXT NOT NULL, meeting_id TEXT NOT NULL,
      provider TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      input_path TEXT NOT NULL, result_path TEXT, error_code TEXT, error_message TEXT,
      created_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, updated_at TEXT NOT NULL
    ) STRICT;
  `);
  legacy.close();
  const store = new JobStore(databasePath);
  store.close();
  const inspector = new DatabaseSync(databasePath);
  assert.equal(inspector.prepare("PRAGMA user_version").get().user_version, 1);
  inspector.close();
});

test("作业库：拒绝未知 user_version 和缺少必需列的 jobs 表", async () => {
  const root = await makeTempDir();
  const unknownPath = path.join(root, "unknown.sqlite");
  const unknown = new DatabaseSync(unknownPath);
  unknown.exec("PRAGMA user_version = 99");
  unknown.close();
  assert.throws(() => new JobStore(unknownPath), (error) => error.code === "AGENT_DB_VERSION_UNSUPPORTED" && /99/.test(error.message));

  const malformedPath = path.join(root, "malformed.sqlite");
  const malformed = new DatabaseSync(malformedPath);
  malformed.exec("CREATE TABLE jobs (job_id TEXT PRIMARY KEY) STRICT; PRAGMA user_version = 1");
  malformed.close();
  assert.throws(() => new JobStore(malformedPath), (error) => error.code === "AGENT_DB_SCHEMA_INVALID" && /request_hash/.test(error.message));
});

test("作业库：相同 ID 不同哈希返回幂等冲突", async (t) => {
  const { store } = await makeStore();
  t.after(() => store.close());
  store.createOrGet(jobInput());
  assert.throws(() => store.createOrGet(jobInput("job-1", "b".repeat(64))), (error) => error.code === "IDEMPOTENCY_CONFLICT");
});

test("作业库：queued -> running -> succeeded 使用状态 CAS", async (t) => {
  const { store } = await makeStore();
  t.after(() => store.close());
  store.createOrGet(jobInput());
  const claimed = store.claimNext();
  assert.equal(claimed.status, "running");
  assert.equal(claimed.attempts, 1);
  const succeeded = store.markSucceeded("job-1", "/tmp/job-1/output");
  assert.equal(succeeded.status, "succeeded");
  assert.equal(succeeded.result_path, "/tmp/job-1/output");
  assert.throws(() => store.markSucceeded("job-1", "/tmp/again"), /状态|running/);
});

test("作业库：失败摘要截断为 2000 字符", async (t) => {
  const { store } = await makeStore();
  t.after(() => store.close());
  store.createOrGet(jobInput());
  store.claimNext();
  const failed = store.markFailed("job-1", "PROVIDER_FAILED", "错".repeat(2100));
  assert.equal(failed.status, "failed");
  assert.equal(failed.error_message.length, 2000);
  assert.equal(failed.error_code, "PROVIDER_FAILED");
});

test("作业库：进程重启把 running 恢复为 queued", async () => {
  const { databasePath, store } = await makeStore();
  store.createOrGet(jobInput());
  store.claimNext();
  store.close();
  const reopened = new JobStore(databasePath);
  try {
    assert.equal(reopened.recoverInterrupted(), 1);
    const recovered = reopened.get("job-1");
    assert.equal(recovered.status, "queued");
    assert.equal(recovered.started_at, null);
    assert.equal(reopened.claimNext().attempts, 2);
  } finally {
    reopened.close();
  }
});

test("作业库：两个连接并发 claim 只成功一次", async () => {
  const { databasePath, store } = await makeStore();
  store.createOrGet(jobInput());
  const second = new JobStore(databasePath);
  try {
    const claims = [store.claimNext(), second.claimNext()].filter(Boolean);
    assert.equal(claims.length, 1);
    assert.equal(claims[0].job_id, "job-1");
  } finally {
    second.close();
    store.close();
  }
});
