import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import Ajv from "ajv";
import addFormats from "ajv-formats";

import { canonicalizeRequest } from "../src/hash.mjs";
import { validateJobRequest, validateResultManifest } from "../src/schemas.mjs";
import { makeRequest } from "./helpers.mjs";

async function loadValidator(name) {
  const schema = JSON.parse(await readFile(path.resolve(import.meta.dirname, `../contracts/${name}`), "utf8"));
  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);
  return { schema, validate: ajv.compile(schema) };
}

test("协议一致性：AJV 与 Zod 对路径、小写 SHA、trim 和安全整数给出相同结论", async () => {
  const requestValidator = await loadValidator("job-request.schema.json");
  const manifestValidator = await loadValidator("result-manifest.schema.json");
  const valid = makeRequest();
  assert.equal(requestValidator.validate(valid), true);
  assert.doesNotThrow(() => validateJobRequest(valid));

  const cases = [];
  const relativeSource = makeRequest({ attachments: [{
    id: "a", file_name: "a.txt", media_type: "text/plain", size_bytes: 1,
    sha256: "a".repeat(64), source_path: "relative/a.txt",
  }] });
  cases.push(relativeSource);
  const upperHash = structuredClone(relativeSource);
  upperHash.attachments[0].source_path = "/tmp/a.txt";
  upperHash.attachments[0].sha256 = "A".repeat(64);
  cases.push(upperHash);
  const untrimmed = makeRequest();
  untrimmed.meeting.title = " 周会";
  cases.push(untrimmed);
  const unsafeInteger = makeRequest();
  unsafeInteger.transcript.segments[0].end_ms = Number.MAX_SAFE_INTEGER + 1;
  cases.push(unsafeInteger);
  for (const value of cases) {
    assert.equal(requestValidator.validate(value), false, JSON.stringify(requestValidator.validate.errors));
    assert.throws(() => validateJobRequest(value));
  }

  const manifest = {
    schema_version: "1.0", job_id: "job-1", request_id: "job-1",
    request_hash: "a".repeat(64), meeting_id: "meeting-1",
    provider: { name: "mock", run_id: "mock-job-1" }, generated_at: "2026-07-18T02:00:00.000Z",
    report: { path: "report.html", size_bytes: 1, sha256: "b".repeat(64) },
    todos: { path: "todos.json", size_bytes: 1, sha256: "c".repeat(64), count: 0 },
    assets: [{ path: "../asset.png", size_bytes: 1, sha256: "d".repeat(64), media_type: "image/png" }],
    skills_used: [], warnings: [],
  };
  assert.equal(manifestValidator.validate(manifest), false);
  assert.throws(() => validateResultManifest(manifest));
});

test("协议一致性：跨字段规则由 Zod 门禁且生成 Schema 明确标注 runtime 约束", async () => {
  const { schema, validate } = await loadValidator("job-request.schema.json");
  const reversed = makeRequest();
  reversed.meeting.ended_at = "2026-07-18T00:59:59.000Z";
  assert.equal(validate(reversed), true, "Draft 7 结构 Schema 不表达时间先后");
  assert.throws(() => validateJobRequest(reversed), /结束时间/);
  assert.match(schema.properties.meeting.description, /runtime|运行时/i);
  assert.match(schema.properties.attachments.description, /500 MiB|runtime|运行时/i);
  assert.match(schema.properties.transcript.properties.segments.items.description, /runtime|运行时/i);
  const resultSchema = JSON.parse(await readFile(path.resolve(import.meta.dirname, "../contracts/result-manifest.schema.json"), "utf8"));
  assert.match(resultSchema.description, /manifest\.json|200 MiB|runtime/);
});

test("请求哈希：相同时间片按 NFC 后 UTF-8 字节序排序，不依赖 locale", () => {
  const request = makeRequest();
  request.transcript.segments = ["😀", "ä", "z"].map((id) => ({ id, start_ms: 0, end_ms: 1, speaker: id, text: id }));
  const canonical = JSON.parse(canonicalizeRequest(request));
  assert.deepEqual(canonical.transcript.segments.map((segment) => segment.id), ["z", "ä", "😀"]);
});
