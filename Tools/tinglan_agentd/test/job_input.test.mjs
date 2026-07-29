import assert from "node:assert/strict";
import { access, mkdir, readFile, readdir, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { computeRequestHash } from "../src/hash.mjs";
import { DEFAULT_RECEIVE_LOCK_TIMEOUT_MS, cleanOrphanJobs, receiveJobInput } from "../src/job_input.mjs";
import { JobStore } from "../src/job_store.mjs";
import { makeRequest, makeTempDir, writeFixture } from "./helpers.mjs";

async function setup() {
  const root = await makeTempDir();
  const jobsRoot = path.join(root, "jobs");
  await mkdir(jobsRoot);
  const store = new JobStore(path.join(root, "agent.sqlite"));
  return { root, jobsRoot, store };
}

test("原子输入：写 request、复制附件并移除原始 source_path", async (t) => {
  const { root, jobsRoot, store } = await setup();
  t.after(() => store.close());
  const fixture = await writeFixture(root, "需求.txt", "需求正文");
  const request = makeRequest({
    attachments: [{
      id: "attachment-1", file_name: "需求.txt", media_type: "text/plain",
      size_bytes: fixture.size, sha256: fixture.sha256, source_path: fixture.path,
    }],
  });
  const result = await receiveJobInput({ request, jobsRoot, jobStore: store, inputRoots: [root], provider: "mock" });
  assert.equal(result.created, true);
  assert.equal(result.job.status, "queued");
  const input = JSON.parse(await readFile(path.join(jobsRoot, request.request_id, "input/request.json"), "utf8"));
  assert.equal(input.attachments[0].source_path, "attachments/需求.txt");
  assert.equal(await readFile(path.join(jobsRoot, request.request_id, "input/attachments/需求.txt"), "utf8"), "需求正文");
  assert.deepEqual((await readdir(path.join(jobsRoot, request.request_id))).filter((name) => name.includes("staging")), []);
});

test("原子输入：附件复制失败不产生 queued 作业", async (t) => {
  const { jobsRoot, store } = await setup();
  t.after(() => store.close());
  const request = makeRequest({
    attachments: [{
      id: "missing", file_name: "missing.txt", media_type: "text/plain",
      size_bytes: 1, sha256: "a".repeat(64), source_path: "/not/allowed/missing.txt",
    }],
  });
  await assert.rejects(() => receiveJobInput({ request, jobsRoot, jobStore: store, inputRoots: [], provider: "mock" }));
  assert.equal(store.get(request.request_id), null);
});

test("原子输入：数据库插入失败留下的完整孤儿目录可由启动清理删除", async () => {
  const { jobsRoot, store } = await setup();
  const request = makeRequest();
  const failingStore = {
    get: (id) => store.get(id),
    listJobIds: () => store.listJobIds(),
    createOrGet: () => { throw new Error("模拟数据库插入失败"); },
  };
  await assert.rejects(
    () => receiveJobInput({ request, jobsRoot, jobStore: failingStore, inputRoots: [], provider: "mock" }),
    (error) => error.code === "INTERNAL_ERROR" && error.message === "接收作业输入失败" && !error.message.includes("数据库"),
  );
  await access(path.join(jobsRoot, request.request_id, "input/request.json"));
  const removed = await cleanOrphanJobs({ jobsRoot, jobStore: store });
  assert.ok(removed.includes(request.request_id));
  await assert.rejects(() => access(path.join(jobsRoot, request.request_id)));
  store.close();
});

test("原子输入：input 发布后进程中断可清理并用同一 request 重试", async (t) => {
  const { jobsRoot, store } = await setup();
  t.after(() => store.close());
  const request = makeRequest();
  await assert.rejects(() => receiveJobInput({
    request, jobsRoot, jobStore: store, inputRoots: [], provider: "mock",
    hooks: { afterInputPublished: () => { throw new Error("模拟进程退出"); } },
  }), (error) => error.code === "INTERNAL_ERROR" && !error.message.includes("模拟进程退出"));
  assert.equal(store.get(request.request_id), null);
  await cleanOrphanJobs({ jobsRoot, jobStore: store });
  assert.equal((await receiveJobInput({ request, jobsRoot, jobStore: store, inputRoots: [], provider: "mock" })).created, true);
});

test("原子输入：并发相同 request 只保留一个输入和一个作业", async (t) => {
  const { jobsRoot, store } = await setup();
  t.after(() => store.close());
  const request = makeRequest();
  const results = await Promise.all([
    receiveJobInput({ request: structuredClone(request), jobsRoot, jobStore: store, inputRoots: [], provider: "mock" }),
    receiveJobInput({ request: structuredClone(request), jobsRoot, jobStore: store, inputRoots: [], provider: "mock" }),
  ]);
  assert.equal(results.filter((result) => result.created).length, 1);
  assert.equal(store.listJobIds().length, 1);
  assert.deepEqual((await readdir(path.join(jobsRoot, request.request_id))).sort(), ["input"]);
});

test("原子输入：相同 request_id 不同哈希冲突", async (t) => {
  const { jobsRoot, store } = await setup();
  t.after(() => store.close());
  const request = makeRequest();
  await receiveJobInput({ request, jobsRoot, jobStore: store, inputRoots: [], provider: "mock" });
  const changed = structuredClone(request);
  changed.transcript.plain_text = "不同内容";
  assert.notEqual(computeRequestHash(request), computeRequestHash(changed));
  await assert.rejects(
    () => receiveJobInput({ request: changed, jobsRoot, jobStore: store, inputRoots: [], provider: "mock" }),
    (error) => error.code === "IDEMPOTENCY_CONFLICT",
  );
});

test("原子输入：拒绝同名 jobRoot 符号链接，启动清理只 unlink 链接本身", async (t) => {
  const { jobsRoot, store } = await setup();
  t.after(() => store.close());
  const request = makeRequest();
  const outside = await makeTempDir("tinglan-agentd-outside-");
  const sentinel = path.join(outside, "sentinel.txt");
  await writeFile(sentinel, "do-not-delete");
  const linkPath = path.join(jobsRoot, request.request_id);
  await symlink(outside, linkPath);
  await assert.rejects(
    () => receiveJobInput({ request, jobsRoot, jobStore: store, inputRoots: [], provider: "mock" }),
    /符号链接|普通目录|越界/,
  );
  const removed = await cleanOrphanJobs({ jobsRoot, jobStore: store });
  assert.ok(removed.includes(request.request_id));
  await assert.rejects(() => access(linkPath));
  assert.equal(await readFile(sentinel, "utf8"), "do-not-delete");
});

test("原子输入：默认接收锁覆盖大附件时长，慢首请求并发提交复用同一作业", async (t) => {
  assert.ok(DEFAULT_RECEIVE_LOCK_TIMEOUT_MS >= 10 * 60 * 1000);
  const { jobsRoot, store } = await setup();
  t.after(() => store.close());
  const request = makeRequest();
  let releaseFirst;
  let firstPublished;
  const published = new Promise((resolve) => { firstPublished = resolve; });
  const gate = new Promise((resolve) => { releaseFirst = resolve; });
  const first = receiveJobInput({
    request: structuredClone(request), jobsRoot, jobStore: store, inputRoots: [], provider: "mock",
    hooks: { afterInputPublished: async () => { firstPublished(); await gate; } },
    receiveLockTimeoutMs: 1000,
  });
  await published;
  const second = receiveJobInput({
    request: structuredClone(request), jobsRoot, jobStore: store, inputRoots: [], provider: "mock",
    receiveLockTimeoutMs: 1000,
  });
  await new Promise((resolve) => setTimeout(resolve, 100));
  releaseFirst();
  const results = await Promise.all([first, second]);
  assert.equal(results.filter((result) => result.created).length, 1);
  assert.equal(store.listJobIds().length, 1);
});
