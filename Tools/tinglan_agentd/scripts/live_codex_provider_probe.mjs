import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { BUNDLED_CODEX_BINARY } from "../src/config.mjs";
import { runCodexAppServerTurn } from "../src/codex_app_server_client.mjs";
import { computeRequestHash } from "../src/hash.mjs";
import { createCodexAppServerProvider } from "../src/providers/codex_app_server_provider.mjs";
import { verifyResultPackage } from "../src/result_package.mjs";

const root = await mkdtemp(path.join(os.tmpdir(), "tinglan-codex-live-"));
const codexHome = path.resolve(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"));
const configPath = path.join(codexHome, "config.toml");
const configHash = createHash("sha256").update(await readFile(configPath)).digest("hex");
const jobRoot = path.join(root, "job-live-codex-1");
const inputPath = path.join(jobRoot, "input");
await mkdir(inputPath, { recursive: true, mode: 0o700 });

const request = {
  schema_version: "1.0",
  request_id: "job-live-codex-1",
  meeting: {
    id: "meeting-live-codex-1",
    title: "合成接口联调会",
    started_at: "2026-07-18T02:00:00.000Z",
    ended_at: "2026-07-18T02:05:00.000Z",
    timezone: "Asia/Shanghai",
    capture_source: "synthetic-live-probe",
    participants: [
      { name: "陈明", role: "项目负责人", speaker: "陈明" },
      { name: "李娜", role: "客户端负责人", speaker: "李娜" },
    ],
  },
  transcript: {
    language: "zh-CN",
    plain_text: "陈明：请我在下周一前提交接口联调清单，验收标准是研发和客户端共同确认通过。李娜：客户端周二完成结果页联调，完成后在群里同步截图。",
    segments: [
      {
        id: "segment-1",
        start_ms: 0,
        end_ms: 8_000,
        speaker: "陈明",
        text: "请我在下周一前提交接口联调清单，验收标准是研发和客户端共同确认通过。",
      },
      {
        id: "segment-2",
        start_ms: 8_000,
        end_ms: 16_000,
        speaker: "李娜",
        text: "客户端周二完成结果页联调，完成后在群里同步截图。",
      },
    ],
  },
  attachments: [],
  analysis: {
    goal: "这是隔离链路验收。仅依据会议内容生成正式纪要、待确认待办和简短风险分析，不联网，不使用真实业务数据。",
    language: "zh-CN",
  },
  output: {
    report_format: "html",
    todos_format: "json",
    locale: "zh-CN",
  },
};
await writeFile(path.join(inputPath, "request.json"), `${JSON.stringify(request, null, 2)}\n`, { mode: 0o600 });

const job = {
  job_id: request.request_id,
  meeting_id: request.meeting.id,
  request_hash: computeRequestHash(request),
  provider: "codex-app-server",
  input_path: inputPath,
};

let runMetadata = null;
const notificationCounts = {};
const completedItemTypes = [];
const completedItemSummaries = [];
const diagnosticAgentMessages = [];
const provider = createCodexAppServerProvider({
  codexBin: process.env.TINGLAN_CODEX_BIN || BUNDLED_CODEX_BINARY,
  model: process.env.TINGLAN_CODEX_MODEL || undefined,
  effort: process.env.TINGLAN_CODEX_EFFORT || "medium",
  handshakeTimeoutMs: 30_000,
  turnTimeoutMs: 8 * 60 * 1_000,
  forbiddenPaths: [
    path.join(os.homedir(), "Library/Application Support/会小纪/ai-tingji.sqlite"),
    path.join(os.homedir(), "Library/Application Support/会小纪/ai-tingji.sqlite-wal"),
    path.join(os.homedir(), "Library/Application Support/会小纪/ai-tingji.sqlite-shm"),
  ],
  runTurn: async (options) => {
    const result = await runCodexAppServerTurn({
      ...options,
      onThreadStarted: ({ threadId, initializeResult, threadResult, activePermissionProfile }) => {
        runMetadata = {
          threadId,
          codexHome: initializeResult.codexHome,
          ephemeral: threadResult.thread.ephemeral,
          cwd: threadResult.cwd,
          activePermissionProfile: activePermissionProfile?.id ?? null,
        };
      },
      onNotification: ({ method, params }) => {
        if (typeof method !== "string") return;
        notificationCounts[method] = (notificationCounts[method] ?? 0) + 1;
        if (method === "item/completed" && typeof params?.item?.type === "string") {
          const item = params.item;
          completedItemTypes.push(item.type);
          if (item.type === "fileChange") {
            completedItemSummaries.push({
              type: item.type,
              status: item.status ?? null,
              paths: Array.isArray(item.changes) ? item.changes.map((change) => change?.path ?? null) : [],
            });
          } else if (item.type === "mcpToolCall") {
            completedItemSummaries.push({
              type: item.type,
              server: item.server ?? null,
              tool: item.tool ?? null,
              status: item.status ?? null,
              error: item.error?.message ?? null,
            });
          } else if (item.type === "agentMessage" && typeof item.text === "string") {
            diagnosticAgentMessages.push({ phase: item.phase ?? null, text: item.text.slice(0, 4000) });
          }
        }
      },
    });
    runMetadata.turnId = result.turnId;
    return result;
  },
});

try {
  const result = await provider({ job, jobRoot });
  const configUnchanged = createHash("sha256").update(await readFile(configPath)).digest("hex") === configHash;
  if (!configUnchanged) throw new Error("Codex config.toml 在 Agent 执行期间发生变化");
  const verified = await verifyResultPackage(result.outputPath, job);
  const reportBytes = Buffer.byteLength(await readFile(path.join(result.outputPath, "report.html")));
  process.stdout.write(`${JSON.stringify({
    status: "succeeded",
    root,
    outputPath: result.outputPath,
    ...runMetadata,
    configUnchanged,
    provider: verified.manifest.provider.name,
    reportBytes,
    todoCount: verified.todos.items.length,
    assets: verified.manifest.assets.length,
    warnings: verified.manifest.warnings,
    notificationCounts,
    completedItemTypes,
    completedItemSummaries,
    diagnosticAgentMessages,
  }, null, 2)}\n`);
} catch (error) {
  const configUnchanged = createHash("sha256").update(await readFile(configPath)).digest("hex") === configHash;
  process.stdout.write(`${JSON.stringify({
    status: "failed",
    root,
    ...runMetadata,
    configUnchanged,
    notificationCounts,
    completedItemTypes,
    completedItemSummaries,
    diagnosticAgentMessages,
    error: {
      code: error.code ?? "UNKNOWN",
      message: error.message,
      details: error.details ?? [],
      cause: error.cause?.message ?? null,
    },
  }, null, 2)}\n`);
  process.exitCode = 1;
}
