import assert from "node:assert/strict";
import { access, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { AgentError } from "../src/errors.mjs";
import { computeRequestHash } from "../src/hash.mjs";
import { JobStore } from "../src/job_store.mjs";
import { executeMockProvider } from "../src/providers/mock_provider.mjs";
import { Runner } from "../src/runner.mjs";
import { makeRequest, makeTempDir, waitFor } from "./helpers.mjs";

async function setupQueuedJob() {
  const root = await makeTempDir();
  const jobsRoot = path.join(root, "jobs");
  const jobRoot = path.join(jobsRoot, "job-1");
  const inputPath = path.join(jobRoot, "input");
  await mkdir(inputPath, { recursive: true });
  const request = makeRequest({ request_id: "job-1" });
  const requestHash = computeRequestHash(request);
  await writeFile(path.join(inputPath, "request.json"), JSON.stringify(request));
  const store = new JobStore(path.join(root, "agent.sqlite"));
  store.createOrGet({
    requestId: "job-1", requestHash, meetingId: "meeting-1", provider: "mock", inputPath,
  });
  return { store, jobsRoot, jobRoot, request, job: store.get("job-1") };
}

test("Runner：保留 RESULT_INVALID 等稳定 AgentError 错误码", async (t) => {
  const { store, jobsRoot } = await setupQueuedJob();
  t.after(() => store.close());
  const runner = new Runner({
    jobStore: store,
    jobsRoot,
    pollIntervalMs: 10,
    provider: async () => { throw new AgentError("RESULT_INVALID", "结果包无效", { status: 500 }); },
  });
  runner.start();
  t.after(() => runner.stop());
  const failed = await waitFor(() => store.get("job-1")?.status === "failed" ? store.get("job-1") : null);
  assert.equal(failed.error_code, "RESULT_INVALID");
});

test("Runner：执行 Provider 前清理当前作业的旧 result staging", async (t) => {
  const { store, jobsRoot, jobRoot } = await setupQueuedJob();
  t.after(() => store.close());
  const stalePath = path.join(jobRoot, "staging/result-stale");
  await mkdir(stalePath, { recursive: true });
  await writeFile(path.join(stalePath, "partial"), "partial");
  const runner = new Runner({
    jobStore: store,
    jobsRoot,
    pollIntervalMs: 10,
    provider: async () => {
      await assert.rejects(() => access(stalePath));
      throw new Error("测试结束");
    },
  });
  runner.start();
  t.after(() => runner.stop());
  const failed = await waitFor(() => store.get("job-1")?.status === "failed" ? store.get("job-1") : null);
  assert.equal(failed.error_message, "测试结束");
});

test("Runner：claim 基础设施异常通过回调报告且不产生 unhandled rejection", async () => {
  const errors = [];
  const unhandled = [];
  const onUnhandled = (reason) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);
  try {
    const runner = new Runner({
      jobStore: { claimNext: () => { throw new Error("SQLite unavailable"); } },
      jobsRoot: "/tmp/jobs",
      pollIntervalMs: 10,
      onInfrastructureError: (error) => errors.push(error),
    });
    runner.start();
    await waitFor(() => errors.length > 0);
    await runner.stop();
    await new Promise((resolve) => setImmediate(resolve));
    assert.match(errors[0].message, /SQLite unavailable/);
    assert.deepEqual(unhandled, []);
  } finally {
    process.off("unhandledRejection", onUnhandled);
  }
});

test("Runner：markFailed 基础设施异常被报告而非 unhandled", async (t) => {
  const { store, jobsRoot } = await setupQueuedJob();
  t.after(() => store.close());
  const errors = [];
  store.markFailed = () => { throw new Error("disk full"); };
  const runner = new Runner({
    jobStore: store, jobsRoot, pollIntervalMs: 10,
    provider: async () => { throw new Error("provider failed"); },
    onInfrastructureError: (error) => errors.push(error),
  });
  runner.start();
  await waitFor(() => errors.length > 0);
  await runner.stop();
  assert.match(errors[0].message, /disk full/);
});

test("Runner：markSucceeded 基础设施异常被报告而非转成作业失败", async (t) => {
  const { store, jobsRoot, jobRoot, job } = await setupQueuedJob();
  t.after(() => store.close());
  await executeMockProvider({ job, jobRoot });
  const errors = [];
  store.markSucceeded = () => { throw new Error("database read-only"); };
  const runner = new Runner({
    jobStore: store, jobsRoot, pollIntervalMs: 10,
    onInfrastructureError: (error) => errors.push(error),
  });
  runner.start();
  await waitFor(() => errors.length > 0);
  await runner.stop();
  assert.match(errors[0].message, /read-only/);
  assert.equal(store.get("job-1").status, "running");
});

test("Runner：running 恢复时复用身份匹配的完整 output，不重复调用 Provider", async (t) => {
  const { store, jobsRoot, jobRoot, job } = await setupQueuedJob();
  t.after(() => store.close());
  await executeMockProvider({ job, jobRoot });
  let providerCalls = 0;
  const runner = new Runner({
    jobStore: store, jobsRoot, pollIntervalMs: 10,
    provider: async () => { providerCalls += 1; throw new Error("不应重跑"); },
  });
  runner.start();
  t.after(() => runner.stop());
  const succeeded = await waitFor(() => store.get("job-1")?.status === "succeeded" ? store.get("job-1") : null);
  assert.equal(providerCalls, 0);
  assert.equal(succeeded.result_path, path.join(jobRoot, "output"));
});

test("Runner：已有 output 身份不匹配时标记 RESULT_INVALID，不重跑 Provider", async (t) => {
  const { store, jobsRoot, jobRoot, job } = await setupQueuedJob();
  t.after(() => store.close());
  await executeMockProvider({ job: { ...job, request_hash: "f".repeat(64) }, jobRoot });
  let providerCalls = 0;
  const runner = new Runner({
    jobStore: store, jobsRoot, pollIntervalMs: 10,
    provider: async () => { providerCalls += 1; },
  });
  runner.start();
  t.after(() => runner.stop());
  const failed = await waitFor(() => store.get("job-1")?.status === "failed" ? store.get("job-1") : null);
  assert.equal(providerCalls, 0);
  assert.equal(failed.error_code, "RESULT_INVALID");
});

test("Runner：Provider 默认执行超时并标记失败", async (t) => {
  const { store, jobsRoot } = await setupQueuedJob();
  t.after(() => store.close());
  const runner = new Runner({
    jobStore: store, jobsRoot, pollIntervalMs: 10, executionTimeoutMs: 30,
    provider: async () => new Promise(() => {}),
  });
  runner.start();
  t.after(() => runner.stop());
  const failed = await waitFor(() => store.get("job-1")?.status === "failed" ? store.get("job-1") : null);
  assert.equal(failed.error_code, "PROVIDER_FAILED");
  assert.match(failed.error_message, /超时/);
});

test("Runner：stop 会 abort 挂死 Provider 并在截止时间内返回，running 留待重启恢复", async (t) => {
  const { store, jobsRoot } = await setupQueuedJob();
  t.after(() => store.close());
  let started = false;
  let aborted = false;
  const runner = new Runner({
    jobStore: store, jobsRoot, pollIntervalMs: 10, shutdownTimeoutMs: 100,
    provider: async ({ signal }) => {
      started = true;
      signal.addEventListener("abort", () => { aborted = true; });
      return new Promise(() => {});
    },
  });
  runner.start();
  await waitFor(() => started);
  const began = Date.now();
  await runner.stop();
  assert.ok(Date.now() - began < 500);
  assert.equal(aborted, true);
  assert.equal(store.get("job-1").status, "running");
});
