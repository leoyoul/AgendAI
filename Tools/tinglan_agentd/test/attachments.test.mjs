import assert from "node:assert/strict";
import { lstat, mkdir, readFile, symlink } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import {
  ensureApiToken,
  loadConfig,
  parseInputRoots,
  verifyBearerToken,
} from "../src/config.mjs";
import { copyAttachments, validateAttachmentLimits } from "../src/attachment_store.mjs";
import { computeRequestHash } from "../src/hash.mjs";
import { makeRequest, makeTempDir, writeFixture } from "./helpers.mjs";

test("token：原子生成且权限为 0600，鉴权使用严格 Bearer 值", async () => {
  const root = await makeTempDir();
  const tokenPath = path.join(root, "api-token");
  const token = await ensureApiToken(tokenPath);
  assert.ok(Buffer.byteLength(token, "utf8") >= 32);
  assert.equal((await lstat(tokenPath)).mode & 0o777, 0o600);
  assert.equal((await readFile(tokenPath, "utf8")).trim(), token);
  assert.equal(await ensureApiToken(tokenPath), token);
  assert.equal(verifyBearerToken(`Bearer ${token}`, token), true);
  assert.equal(verifyBearerToken(`Bearer ${token}x`, token), false);
  assert.equal(verifyBearerToken("Basic abc", token), false);
});

test("token：并发首次启动使用 no-replace 发布且所有调用者得到磁盘同一 token", async () => {
  const root = await makeTempDir();
  const tokenPath = path.join(root, "api-token");
  const tokens = await Promise.all(Array.from({ length: 32 }, () => ensureApiToken(tokenPath)));
  assert.equal(new Set(tokens).size, 1);
  assert.equal(tokens[0], (await readFile(tokenPath, "utf8")).trim());
  assert.equal((await lstat(tokenPath)).mode & 0o777, 0o600);
});

test("token：拒绝预置符号链接", async () => {
  const root = await makeTempDir();
  const target = await writeFixture(root, "target-token", "x".repeat(40));
  const tokenPath = path.join(root, "api-token");
  await symlink(target.path, tokenPath);
  await assert.rejects(() => ensureApiToken(tokenPath), /符号链接/);
});

test("附件：配置只允许 127.0.0.1，白名单必须是绝对路径", () => {
  assert.equal(loadConfig({ HOME: "/tmp/home" }).host, "127.0.0.1");
  assert.throws(() => loadConfig({ HOME: "/tmp/home", TINGLAN_AGENT_HOST: "0.0.0.0" }), /127\.0\.0\.1/);
  assert.throws(() => loadConfig({ HOME: "/tmp/home", TINGLAN_AGENT_HOST: "192.168.1.2" }), /127\.0\.0\.1/);
  assert.deepEqual(parseInputRoots(""), []);
  assert.throws(() => parseInputRoots("relative/path"), /绝对路径/);
});

test("配置：只允许 Mock 或 Codex App Server，Codex 参数严格校验", () => {
  const mock = loadConfig({ HOME: "/tmp/home" });
  assert.equal(mock.provider, "mock");
  assert.equal(mock.codexHome, "/tmp/home/.codex");
  assert.match(mock.codexForbiddenPaths[0], /会小纪\/ai-tingji\.sqlite$/);
  const codex = loadConfig({
    HOME: "/tmp/home",
    TINGLAN_AGENT_PROVIDER: "codex-app-server",
    TINGLAN_CODEX_BIN: "/opt/codex/bin/codex",
    TINGLAN_CODEX_MODEL: "gpt-5.4",
    TINGLAN_CODEX_EFFORT: "high",
    TINGLAN_CODEX_HANDSHAKE_TIMEOUT_MS: "1234",
  });
  assert.equal(codex.provider, "codex-app-server");
  assert.equal(codex.codexBin, "/opt/codex/bin/codex");
  assert.equal(codex.codexHome, "/tmp/home/.codex");
  assert.equal(codex.codexModel, "gpt-5.4");
  assert.equal(codex.codexEffort, "high");
  assert.equal(codex.codexHandshakeTimeoutMs, 1234);
  assert.throws(() => loadConfig({ HOME: "/tmp/home", TINGLAN_AGENT_PROVIDER: "unknown" }), /不支持 Provider/);
  assert.throws(() => loadConfig({ HOME: "/tmp/home", TINGLAN_CODEX_BIN: "relative/codex" }), /绝对路径/);
  assert.throws(() => loadConfig({ HOME: "/tmp/home", TINGLAN_CODEX_EFFORT: "extreme" }), /推理强度/);
  assert.throws(() => loadConfig({ HOME: "/tmp/home", CODEX_HOME: "relative/.codex" }), /CODEX_HOME.*绝对路径/);
});

test("请求哈希：NFC、换行、对象键和片段顺序稳定，忽略 source_path", () => {
  const first = makeRequest();
  first.meeting.title = "Cafe\u0301\r\n周会";
  first.transcript.segments = [
    { id: "b", start_ms: 10, end_ms: 20, speaker: "B", text: "第二行\r\n" },
    { id: "a", start_ms: 0, end_ms: 9, speaker: "A", text: "第一行" },
  ];
  first.attachments = [{
    id: "a", file_name: "a.txt", media_type: "text/plain", size_bytes: 1,
    sha256: "a".repeat(64), source_path: "/first/a.txt",
  }];
  const second = structuredClone(first);
  second.meeting.title = "Caf\u00e9\n周会";
  second.transcript.segments.reverse();
  second.transcript.segments[1].text = "第二行\n";
  second.attachments[0].source_path = "/second/a.txt";
  assert.equal(computeRequestHash(first), computeRequestHash(second));
});

test("附件：空白名单仅允许无附件", async () => {
  const destinationDir = await makeTempDir();
  assert.deepEqual(await copyAttachments({ attachments: [], destinationDir, inputRoots: [] }), []);
  await assert.rejects(() => copyAttachments({
    attachments: [{ id: "a", file_name: "a", media_type: "text/plain", size_bytes: 0, sha256: "0".repeat(64), source_path: "/tmp/a" }],
    destinationDir,
    inputRoots: [],
  }), /白名单|允许/);
});

test("附件：复制普通文件并校验大小与 SHA-256，source_path 被安全相对路径替换", async () => {
  const root = await makeTempDir();
  const destinationDir = path.join(root, "destination");
  await mkdir(destinationDir);
  const fixture = await writeFixture(root, "会议记录.txt", "会议内容");
  const copied = await copyAttachments({
    attachments: [{
      id: "attachment-1", file_name: "会议记录.txt", media_type: "text/plain",
      size_bytes: fixture.size, sha256: fixture.sha256, source_path: fixture.path,
    }],
    destinationDir,
    inputRoots: [root],
  });
  assert.equal(copied[0].source_path, "attachments/会议记录.txt");
  assert.equal(await readFile(path.join(destinationDir, "会议记录.txt"), "utf8"), "会议内容");

  await assert.rejects(() => copyAttachments({
    attachments: [{
      id: "bad", file_name: "bad.txt", media_type: "text/plain",
      size_bytes: fixture.size + 1, sha256: fixture.sha256, source_path: fixture.path,
    }], destinationDir, inputRoots: [root],
  }), /大小|不一致/);
  await assert.rejects(() => copyAttachments({
    attachments: [{
      id: "upper", file_name: "upper.txt", media_type: "text/plain",
      size_bytes: fixture.size, sha256: fixture.sha256.toUpperCase(), source_path: fixture.path,
    }], destinationDir, inputRoots: [root],
  }), /小写/);
});

test("附件：拒绝白名单逃逸和符号链接", async () => {
  const root = await makeTempDir();
  const outside = await makeTempDir();
  const fixture = await writeFixture(outside, "outside.txt", "outside");
  const destinationDir = path.join(root, "destination");
  await mkdir(destinationDir);
  const metadata = {
    id: "outside", file_name: "outside.txt", media_type: "text/plain",
    size_bytes: fixture.size, sha256: fixture.sha256, source_path: fixture.path,
  };
  await assert.rejects(() => copyAttachments({ attachments: [metadata], destinationDir, inputRoots: [root] }), /白名单|允许/);

  const linkPath = path.join(root, "link.txt");
  await symlink(fixture.path, linkPath);
  await assert.rejects(() => copyAttachments({
    attachments: [{ ...metadata, source_path: linkPath }], destinationDir, inputRoots: [root],
  }), /符号链接/);
});

test("附件：资源限制和同名文件安全命名", async () => {
  assert.throws(() => validateAttachmentLimits(Array.from({ length: 21 }, (_, index) => ({ size_bytes: 0, id: String(index) }))), /20/);
  assert.throws(() => validateAttachmentLimits([{ size_bytes: 100 * 1024 * 1024 + 1, id: "large" }]), /100 MiB/);

  const root = await makeTempDir();
  const destinationDir = path.join(root, "destination");
  await mkdir(destinationDir);
  const first = await writeFixture(root, "first.txt", "one");
  const second = await writeFixture(root, "second.txt", "two");
  const copied = await copyAttachments({
    attachments: [
      { id: "1", file_name: "same.txt", media_type: "text/plain", size_bytes: first.size, sha256: first.sha256, source_path: first.path },
      { id: "2", file_name: "same.txt", media_type: "text/plain", size_bytes: second.size, sha256: second.sha256, source_path: second.path },
    ],
    destinationDir,
    inputRoots: [root],
  });
  assert.deepEqual(copied.map((item) => item.source_path), ["attachments/same.txt", "attachments/same-2.txt"]);
});
