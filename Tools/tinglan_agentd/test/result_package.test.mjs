import assert from "node:assert/strict";
import { mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { computeRequestHash } from "../src/hash.mjs";
import { executeMockProvider } from "../src/providers/mock_provider.mjs";
import { publishResultPackage, validateResultPackageLimits, verifyResultPackage } from "../src/result_package.mjs";
import { validateResultManifest } from "../src/schemas.mjs";
import { makeRequest, makeTempDir } from "./helpers.mjs";

async function setupInput(request) {
  const root = await makeTempDir();
  const jobRoot = path.join(root, request.request_id);
  const inputPath = path.join(jobRoot, "input");
  await mkdir(inputPath, { recursive: true });
  await writeFile(path.join(inputPath, "request.json"), JSON.stringify(request));
  return {
    root,
    jobRoot,
    job: {
      job_id: request.request_id,
      request_hash: computeRequestHash(request),
      meeting_id: request.meeting.id,
      provider: "mock",
      input_path: inputPath,
    },
  };
}

test("Mock 结果包：HTML 转义并明确分隔正式纪要与智能分析", async () => {
  const request = makeRequest();
  request.meeting.title = "<script>alert(1)</script>项目会";
  request.transcript.plain_text = "结论 <b>不能注入</b>";
  const { jobRoot, job } = await setupInput(request);
  const result = await executeMockProvider({ job, jobRoot });
  const html = await readFile(path.join(result.outputPath, "report.html"), "utf8");
  assert.match(html, /正式纪要/);
  assert.match(html, /智能分析/);
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&lt;b&gt;不能注入&lt;\/b&gt;/);
});

test("Mock 结果包：输出空待办、准确 manifest 哈希并原子发布", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  const result = await executeMockProvider({ job, jobRoot });
  const verified = await verifyResultPackage(result.outputPath);
  assert.equal(verified.manifest.job_id, job.job_id);
  assert.equal(verified.manifest.request_hash, job.request_hash);
  assert.equal(verified.manifest.todos.count, 0);
  assert.deepEqual(verified.todos.items, []);
  assert.equal(verified.manifestSha256, result.manifestSha256);
  assert.deepEqual(await readdir(path.join(jobRoot, "staging")), []);
});

test("结果包：重复发布校验并复用已有 output", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  const first = await executeMockProvider({ job, jobRoot });
  const second = await executeMockProvider({ job, jobRoot });
  assert.equal(second.outputPath, first.outputPath);
  assert.equal(second.manifestSha256, first.manifestSha256);
});

test("结果包：拒绝远程、data、绝对和越界图片 URL", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  const base = {
    jobRoot,
    request,
    requestHash: job.request_hash,
    provider: { name: "mock", run_id: `mock-${job.job_id}` },
    generatedAt: request.meeting.ended_at,
    todos: { schema_version: "1.0", job_id: job.job_id, meeting_id: request.meeting.id, items: [] },
  };
  for (const source of ["https://example.com/a.png", "data:image/png;base64,AA", "/tmp/a.png", "../a.png", "file:///tmp/a.png"]) {
    await assert.rejects(() => publishResultPackage({
      ...base,
      reportHtml: `<!doctype html><html><body><h1>正式纪要</h1><section>智能分析</section><img src="${source}"></body></html>`,
    }), /图片|资源|相对路径/);
    await rm(path.join(jobRoot, "output"), { recursive: true, force: true });
  }
});

test("结果包：拒绝未声明资源、符号链接和篡改文件", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  await assert.rejects(() => publishResultPackage({
    jobRoot,
    request,
    requestHash: job.request_hash,
    provider: { name: "mock", run_id: `mock-${job.job_id}` },
    generatedAt: request.meeting.ended_at,
    reportHtml: "<!doctype html><html><body><h1>正式纪要</h1><section>智能分析</section><img src=\"assets/missing.png\"></body></html>",
    todos: { schema_version: "1.0", job_id: job.job_id, meeting_id: request.meeting.id, items: [] },
  }), /未在 manifest|资源/);

  const result = await executeMockProvider({ job, jobRoot });
  await writeFile(path.join(result.outputPath, "undeclared.txt"), "undeclared");
  await assert.rejects(() => verifyResultPackage(result.outputPath), /未在 manifest 声明/);
  await rm(path.join(result.outputPath, "undeclared.txt"));
  await writeFile(path.join(result.outputPath, "report.html"), "tampered");
  await assert.rejects(() => verifyResultPackage(result.outputPath), /哈希|大小/);

  await rm(path.join(result.outputPath, "report.html"));
  await symlink("/tmp/outside.html", path.join(result.outputPath, "report.html"));
  await assert.rejects(() => verifyResultPackage(result.outputPath), /符号链接|普通文件/);
});

test("结果包：拒绝 manifest 外的任意符号链接", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  const result = await executeMockProvider({ job, jobRoot });
  await symlink("/tmp/outside", path.join(result.outputPath, "undeclared-link"));
  await assert.rejects(() => verifyResultPackage(result.outputPath), /符号链接/);
});

test("结果包：坏 JSON、缺文件统一包装为 RESULT_INVALID", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  const result = await executeMockProvider({ job, jobRoot });
  await writeFile(path.join(result.outputPath, "manifest.json"), "{bad-json");
  await assert.rejects(() => verifyResultPackage(result.outputPath), (error) => error.code === "RESULT_INVALID");

  await rm(result.outputPath, { recursive: true, force: true });
  const regenerated = await executeMockProvider({ job, jobRoot });
  await rm(path.join(regenerated.outputPath, "report.html"));
  await assert.rejects(() => verifyResultPackage(regenerated.outputPath), (error) => error.code === "RESULT_INVALID");
});

test("结果包：expected job 绑定 job/hash/meeting/provider identity", async () => {
  const request = makeRequest();
  const { jobRoot, job } = await setupInput(request);
  const result = await executeMockProvider({ job, jobRoot });
  await assert.doesNotReject(() => verifyResultPackage(result.outputPath, job));
  for (const changed of [
    { ...job, job_id: "other-job" },
    { ...job, request_hash: "f".repeat(64) },
    { ...job, meeting_id: "other-meeting" },
    { ...job, provider: "codex" },
  ]) {
    await assert.rejects(() => verifyResultPackage(result.outputPath, changed), (error) => error.code === "RESULT_INVALID");
  }
});

test("结果包：manifest/runtime 统一执行文件数量与容量上限", () => {
  const base = {
    schema_version: "1.0", job_id: "job-1", request_id: "job-1", request_hash: "a".repeat(64), meeting_id: "meeting-1",
    provider: { name: "mock", run_id: "mock-job-1" }, generated_at: "2026-07-18T02:00:00.000Z",
    report: { path: "report.html", size_bytes: 1, sha256: "b".repeat(64) },
    todos: { path: "todos.json", size_bytes: 1, sha256: "c".repeat(64), count: 0 },
    assets: [], skills_used: [], warnings: [],
  };
  const invalid = [
    { ...base, report: { ...base.report, size_bytes: 20 * 1024 * 1024 + 1 } },
    { ...base, todos: { ...base.todos, size_bytes: 5 * 1024 * 1024 + 1 } },
    { ...base, assets: [{ path: "assets/a.bin", size_bytes: 50 * 1024 * 1024 + 1, sha256: "d".repeat(64), media_type: "application/octet-stream" }] },
    { ...base, assets: Array.from({ length: 101 }, (_, i) => ({ path: `assets/${i}.bin`, size_bytes: 1, sha256: "d".repeat(64), media_type: "application/octet-stream" })) },
    { ...base, report: { ...base.report, size_bytes: 20 * 1024 * 1024 }, todos: { ...base.todos, size_bytes: 5 * 1024 * 1024 }, assets: Array.from({ length: 4 }, (_, i) => ({ path: `assets/${i}.bin`, size_bytes: 50 * 1024 * 1024, sha256: "d".repeat(64), media_type: "application/octet-stream" })) },
  ];
  for (const manifest of invalid) {
    assert.throws(() => validateResultPackageLimits(manifest), /上限|超过/);
    assert.throws(() => validateResultManifest(manifest), /上限|超过|100/);
  }
  const exactlyDeclared200MiB = {
    ...base,
    report: { ...base.report, size_bytes: 20 * 1024 * 1024 },
    todos: { ...base.todos, size_bytes: 5 * 1024 * 1024 },
    assets: [50, 50, 50, 25].map((mib, i) => ({
      path: `assets/${i}.bin`, size_bytes: mib * 1024 * 1024,
      sha256: "d".repeat(64), media_type: "application/octet-stream",
    })),
  };
  assert.doesNotThrow(() => validateResultManifest(exactlyDeclared200MiB));
  assert.throws(() => validateResultPackageLimits(exactlyDeclared200MiB, 1), /200 MiB/);
  assert.throws(() => validateResultManifest({ ...base, report: { ...base.report, path: "other.html" } }), /report\.html/);
  assert.throws(() => validateResultManifest({ ...base, todos: { ...base.todos, path: "other.json" } }), /todos\.json/);
});
