import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

export function makeRequest(overrides = {}) {
  const requestId = overrides.request_id ?? randomUUID();
  return {
    schema_version: "1.0",
    request_id: requestId,
    meeting: {
      id: "meeting-1",
      title: "项目周例会",
      started_at: "2026-07-18T01:00:00.000Z",
      ended_at: "2026-07-18T02:00:00.000Z",
      timezone: "Asia/Shanghai",
      capture_source: "mixed",
      participants: [],
    },
    transcript: {
      language: "zh-CN",
      plain_text: "确认范围并形成方案。",
      segments: [
        {
          id: "segment-1",
          start_ms: 0,
          end_ms: 3200,
          speaker: "待确认",
          text: "确认范围并形成方案。",
        },
      ],
    },
    attachments: [],
    analysis: { goal: "", language: "zh-CN" },
    output: {
      report_format: "html",
      todos_format: "json",
      locale: "zh-CN",
    },
    ...overrides,
  };
}

export async function makeTempDir(prefix = "tinglan-agentd-") {
  return mkdtemp(path.join(tmpdir(), prefix));
}

export async function writeFixture(root, name, contents) {
  const filePath = path.join(root, name);
  await writeFile(filePath, contents);
  return {
    path: filePath,
    size: Buffer.byteLength(contents),
    sha256: createHash("sha256").update(contents).digest("hex"),
  };
}

export async function waitFor(predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`等待条件超时（${timeoutMs}ms）`);
}
