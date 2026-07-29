import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";

import {
  validateErrorResponse,
  validateJobRequest,
  validateJobStatus,
  validateRelativeResultPath,
  validateResultManifest,
  validateResultResponse,
  validateSubmitResponse,
  validateTodos,
} from "../src/schemas.mjs";
import { makeRequest, makeTempDir } from "./helpers.mjs";

const execFileAsync = promisify(execFile);

test("协议：接受最小有效请求、完整转写和空分析目标", () => {
  const request = makeRequest();
  assert.equal(validateJobRequest(request).schema_version, "1.0");
  assert.equal(validateJobRequest(request).analysis.goal, "");
  assert.equal(validateJobRequest(request).transcript.segments.length, 1);
});

test("协议：接受严格附件描述", () => {
  const request = makeRequest({
    attachments: [{
      id: "attachment-1",
      file_name: "需求说明.pdf",
      media_type: "application/pdf",
      size_bytes: 1024,
      sha256: "a".repeat(64),
      source_path: "/tmp/需求说明.pdf",
    }],
  });
  assert.equal(validateJobRequest(request).attachments[0].id, "attachment-1");
});

test("协议：拒绝未知版本、空会议 ID、负时间和片段越界", () => {
  assert.throws(() => validateJobRequest(makeRequest({ schema_version: "2.0" })), /1\.0|版本/);

  const emptyMeeting = makeRequest();
  emptyMeeting.meeting.id = "";
  assert.throws(() => validateJobRequest(emptyMeeting), /会议|字符/);

  const unsafeMeeting = makeRequest();
  unsafeMeeting.meeting.id = "meeting/../../outside";
  assert.throws(() => validateJobRequest(unsafeMeeting), /会议 ID|路径组件/);

  const negative = makeRequest();
  negative.transcript.segments[0].start_ms = -1;
  assert.throws(() => validateJobRequest(negative), /时间|大于/);

  const reversed = makeRequest();
  reversed.transcript.segments[0].start_ms = 4000;
  reversed.transcript.segments[0].end_ms = 3000;
  assert.throws(() => validateJobRequest(reversed), /片段|结束/);
});

test("协议：对象拒绝未知字段", () => {
  assert.throws(() => validateJobRequest({ ...makeRequest(), unexpected: true }), /unrecognized|未知/i);
});

test("协议：结果路径必须是规范相对路径", () => {
  assert.equal(validateRelativeResultPath("assets/chart.png"), "assets/chart.png");
  for (const invalid of ["", ".", "..", "../report.html", "/tmp/report.html", "assets/../report.html", "C:\\report.html", "assets\\chart.png"]) {
    assert.throws(() => validateRelativeResultPath(invalid), /相对路径/);
  }
});

test("协议：待办必须待确认且非空负责人需要会议证据", () => {
  const base = {
    schema_version: "1.0",
    job_id: "job-1",
    meeting_id: "meeting-1",
    items: [{
      id: "todo-1",
      title: "形成实施方案",
      description: "形成初稿",
      owner: null,
      deadline: null,
      deliverable: "方案初稿",
      acceptance_criteria: "覆盖范围",
      evidence: [],
      confirmation_status: "pending_confirmation",
      proposed_workflow: "none",
    }],
  };
  assert.equal(validateTodos(base).items.length, 1);
  assert.throws(() => validateTodos({
    ...base,
    items: [{ ...base.items[0], confirmation_status: "confirmed" }],
  }), /pending_confirmation|待确认/);
  assert.throws(() => validateTodos({
    ...base,
    items: [{ ...base.items[0], owner: "张三" }],
  }), /负责人证据/);
});

test("协议：提交、状态、结果、统一错误和 manifest 均可校验", () => {
  assert.equal(validateSubmitResponse({
    schema_version: "1.0", job_id: "job-1", request_id: "job-1", status: "queued",
  }).job_id, "job-1");

  assert.equal(validateJobStatus({
    schema_version: "1.0",
    job_id: "job-1",
    request_id: "job-1",
    meeting_id: "meeting-1",
    provider: "mock",
    status: "running",
    created_at: "2026-07-18T01:00:00.000Z",
    updated_at: "2026-07-18T01:00:01.000Z",
    started_at: "2026-07-18T01:00:01.000Z",
    completed_at: null,
    error: null,
  }).status, "running");

  assert.equal(validateResultResponse({
    schema_version: "1.0",
    job_id: "job-1",
    request_id: "job-1",
    meeting_id: "meeting-1",
    request_hash: "a".repeat(64),
    provider: { name: "mock", run_id: "mock-job-1" },
    result_path: "/tmp/jobs/job-1/output",
    manifest_path: "manifest.json",
    manifest_sha256: "b".repeat(64),
  }).provider.name, "mock");

  assert.equal(validateErrorResponse({
    error: { code: "INVALID_REQUEST", message: "请求格式无效", details: [] },
  }).error.code, "INVALID_REQUEST");

  assert.equal(validateResultManifest({
    schema_version: "1.0",
    job_id: "job-1",
    request_id: "job-1",
    request_hash: "a".repeat(64),
    meeting_id: "meeting-1",
    provider: { name: "mock", run_id: "mock-job-1" },
    generated_at: "2026-07-18T02:00:00.000Z",
    report: { path: "report.html", size_bytes: 10, sha256: "b".repeat(64) },
    todos: { path: "todos.json", size_bytes: 10, sha256: "c".repeat(64), count: 0 },
    assets: [{ path: "assets/a.png", size_bytes: 1, sha256: "d".repeat(64), media_type: "image/png" }],
    skills_used: [],
    warnings: [],
  }).assets.length, 1);
});

test("协议：生成的 JSON Schema 与 Zod 真相源逐字节一致", async () => {
  const outputDir = await makeTempDir("tinglan-contracts-");
  await execFileAsync(process.execPath, ["scripts/generate_contracts.mjs", "--output-dir", outputDir], {
    cwd: path.resolve(import.meta.dirname, ".."),
  });
  const contractDir = path.resolve(import.meta.dirname, "../contracts");
  const names = (await readdir(contractDir)).filter((name) => name.endsWith(".schema.json")).sort();
  assert.equal(names.length, 7);
  for (const name of names) {
    assert.equal(await readFile(path.join(outputDir, name), "utf8"), await readFile(path.join(contractDir, name), "utf8"), name);
  }
});
