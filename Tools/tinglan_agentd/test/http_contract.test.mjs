import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { createAgentHttpServer } from "../src/http_server.mjs";
import { JobStore } from "../src/job_store.mjs";
import { Runner } from "../src/runner.mjs";
import {
  validateErrorResponse,
  validateJobStatus,
  validateResultResponse,
  validateSubmitResponse,
} from "../src/schemas.mjs";
import { makeRequest, makeTempDir, waitFor } from "./helpers.mjs";

async function harness(t, { maxJsonBytes = 20 * 1024 * 1024, provider, receiveJob } = {}) {
  const root = await makeTempDir();
  const jobsRoot = path.join(root, "jobs");
  await mkdir(jobsRoot);
  const jobStore = new JobStore(path.join(root, "agent.sqlite"));
  const runner = new Runner({ jobStore, jobsRoot, provider, pollIntervalMs: 20 });
  const config = {
    host: "127.0.0.1", port: 0, jobsRoot, inputRoots: [], provider: "mock", maxJsonBytes,
    requestTimeoutMs: 1234, headersTimeoutMs: 500,
  };
  const token = "test-token-that-is-definitely-at-least-32-bytes";
  const server = createAgentHttpServer({ config, token, jobStore, runner, receiveJob });
  await new Promise((resolve, reject) => server.listen(0, config.host, (error) => error ? reject(error) : resolve()));
  const address = server.address();
  t.after(async () => {
    await runner.stop();
    await new Promise((resolve) => server.close(resolve));
    jobStore.close();
  });
  return { root, jobsRoot, jobStore, runner, server, token, baseURL: `http://127.0.0.1:${address.port}` };
}

async function json(response) {
  return response.json();
}

function auth(token, extra = {}) {
  return { authorization: `Bearer ${token}`, ...extra };
}

test("HTTP：healthz 无需鉴权，其他接口使用统一 401", async (t) => {
  const agent = await harness(t);
  assert.equal(agent.server.requestTimeout, 1234);
  assert.equal(agent.server.headersTimeout, 500);
  const health = await fetch(`${agent.baseURL}/healthz`);
  assert.equal(health.status, 200);
  assert.deepEqual(await json(health), { status: "ok", service: "tinglan-agentd", protocol_version: "1.0" });

  const unauthorized = await fetch(`${agent.baseURL}/v1/jobs/missing`);
  assert.equal(unauthorized.status, 401);
  assert.equal(validateErrorResponse(await json(unauthorized)).error.code, "AUTH_REQUIRED");
  const wrong = await fetch(`${agent.baseURL}/v1/jobs/missing`, { headers: auth(`${agent.token}x`) });
  assert.equal(wrong.status, 401);
});

test("HTTP：接收基础设施异常统一为 INTERNAL_ERROR 且不泄漏原始错误", async (t) => {
  const agent = await harness(t, { receiveJob: async () => { throw new Error("SECRET database path /private/db"); } });
  const request = makeRequest();
  const response = await fetch(`${agent.baseURL}/v1/jobs`, {
    method: "POST",
    headers: auth(agent.token, { "content-type": "application/json", "idempotency-key": request.request_id }),
    body: JSON.stringify(request),
  });
  assert.equal(response.status, 500);
  const payload = validateErrorResponse(await json(response));
  assert.equal(payload.error.code, "INTERNAL_ERROR");
  assert.doesNotMatch(payload.error.message, /SECRET|private\/db/);
});

test("HTTP：提交强制 JSON、20 MiB 上限和 Idempotency-Key", async (t) => {
  const agent = await harness(t, { maxJsonBytes: 100 });
  const request = makeRequest();
  const wrongType = await fetch(`${agent.baseURL}/v1/jobs`, {
    method: "POST", headers: auth(agent.token, { "content-type": "text/plain" }), body: "{}",
  });
  assert.equal(wrongType.status, 415);
  assert.equal((await json(wrongType)).error.code, "UNSUPPORTED_MEDIA_TYPE");

  const tooLarge = await fetch(`${agent.baseURL}/v1/jobs`, {
    method: "POST", headers: auth(agent.token, { "content-type": "application/json", "idempotency-key": request.request_id }), body: "x".repeat(101),
  });
  assert.equal(tooLarge.status, 413);
  assert.equal((await json(tooLarge)).error.code, "PAYLOAD_TOO_LARGE");

  const second = await harness(t);
  const missingKey = await fetch(`${second.baseURL}/v1/jobs`, {
    method: "POST", headers: auth(second.token, { "content-type": "application/json" }), body: JSON.stringify(request),
  });
  assert.equal(missingKey.status, 400);
  const mismatch = await fetch(`${second.baseURL}/v1/jobs`, {
    method: "POST", headers: auth(second.token, { "content-type": "application/json", "idempotency-key": "other" }), body: JSON.stringify(request),
  });
  assert.equal(mismatch.status, 400);
  assert.equal((await json(mismatch)).error.code, "INVALID_REQUEST");
});

test("HTTP：202 提交、相同请求幂等、不同内容冲突", async (t) => {
  const agent = await harness(t);
  const request = makeRequest();
  const options = {
    method: "POST",
    headers: auth(agent.token, { "content-type": "application/json", "idempotency-key": request.request_id }),
    body: JSON.stringify(request),
  };
  const first = await fetch(`${agent.baseURL}/v1/jobs`, options);
  assert.equal(first.status, 202);
  assert.equal(validateSubmitResponse(await json(first)).job_id, request.request_id);
  const second = await fetch(`${agent.baseURL}/v1/jobs`, options);
  assert.equal(second.status, 202);
  assert.equal(validateSubmitResponse(await json(second)).job_id, request.request_id);
  assert.equal(agent.jobStore.listJobIds().length, 1);

  const changed = structuredClone(request);
  changed.transcript.plain_text = "不同内容";
  const conflict = await fetch(`${agent.baseURL}/v1/jobs`, {
    ...options, body: JSON.stringify(changed),
  });
  assert.equal(conflict.status, 409);
  assert.equal((await json(conflict)).error.code, "IDEMPOTENCY_CONFLICT");
});

test("HTTP：后台 Runner 轮询完成并返回严格结果契约", async (t) => {
  const agent = await harness(t);
  agent.runner.start();
  const request = makeRequest();
  const response = await fetch(`${agent.baseURL}/v1/jobs`, {
    method: "POST",
    headers: auth(agent.token, { "content-type": "application/json", "idempotency-key": request.request_id }),
    body: JSON.stringify(request),
  });
  assert.equal(response.status, 202);
  const status = await waitFor(async () => {
    const current = await fetch(`${agent.baseURL}/v1/jobs/${request.request_id}`, { headers: auth(agent.token) });
    const payload = validateJobStatus(await json(current));
    return payload.status === "succeeded" ? payload : null;
  });
  assert.equal(status.meeting_id, request.meeting.id);
  const result = await fetch(`${agent.baseURL}/v1/jobs/${request.request_id}/result`, { headers: auth(agent.token) });
  assert.equal(result.status, 200);
  const payload = validateResultResponse(await json(result));
  assert.equal(payload.result_path, path.join(agent.jobsRoot, request.request_id, "output"));
  assert.equal(payload.manifest_path, "manifest.json");
});

test("HTTP：未知作业、未完成结果和 Provider 失败有稳定错误", async (t) => {
  const agent = await harness(t, { provider: async () => { throw new Error("模拟 Provider 失败"); } });
  const unknown = await fetch(`${agent.baseURL}/v1/jobs/missing`, { headers: auth(agent.token) });
  assert.equal(unknown.status, 404);
  assert.equal((await json(unknown)).error.code, "JOB_NOT_FOUND");

  const request = makeRequest();
  await fetch(`${agent.baseURL}/v1/jobs`, {
    method: "POST",
    headers: auth(agent.token, { "content-type": "application/json", "idempotency-key": request.request_id }),
    body: JSON.stringify(request),
  });
  const premature = await fetch(`${agent.baseURL}/v1/jobs/${request.request_id}/result`, { headers: auth(agent.token) });
  assert.equal(premature.status, 409);
  assert.equal((await json(premature)).error.code, "JOB_NOT_SUCCEEDED");
  agent.runner.start();
  const failed = await waitFor(() => {
    const job = agent.jobStore.get(request.request_id);
    return job?.status === "failed" ? job : null;
  });
  assert.equal(failed.error_code, "PROVIDER_FAILED");
  assert.match(failed.error_message, /模拟 Provider 失败/);
});
