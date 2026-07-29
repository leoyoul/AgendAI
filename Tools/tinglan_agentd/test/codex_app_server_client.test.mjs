import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { runCodexAppServerTurn } from "../src/codex_app_server_client.mjs";
import { makeTempDir } from "./helpers.mjs";

const fixturePath = fileURLToPath(new URL("../test-fixtures/fake_codex_app_server.mjs", import.meta.url));
const outputSchema = {
  type: "object",
  required: ["completed"],
  properties: { completed: { const: true } },
  additionalProperties: false,
};

async function runFake({
  mode = "success",
  signal,
  handshakeTimeoutMs = 1_000,
  turnTimeoutMs = 1_000,
  permissionsProfile,
  sendOutputSchema = true,
} = {}) {
  const root = await makeTempDir("tinglan-codex-client-");
  const capturePath = path.join(root, "capture.jsonl");
  const result = await runCodexAppServerTurn({
    codexBin: process.execPath,
    appServerArgs: [fixturePath],
    cwd: root,
    runtimeWorkspaceRoots: [root],
    permissionsProfile,
    sendOutputSchema,
    developerInstructions: "只写交付目录。",
    prompt: "生成会议结果。",
    outputSchema,
    model: "gpt-test",
    effort: "high",
    handshakeTimeoutMs,
    turnTimeoutMs,
    signal,
    env: {
      ...process.env,
      FAKE_CODEX_MODE: mode,
      FAKE_CODEX_CAPTURE_PATH: capturePath,
    },
  });
  return { result, capturePath, root };
}

test("App Server Client：严格执行 lifecycle 并固定静默权限参数", async () => {
  const { result, capturePath, root } = await runFake();
  const messages = (await readFile(capturePath, "utf8")).trim().split("\n").map(JSON.parse);
  assert.deepEqual(messages.map((message) => message.method), [
    "initialize", "initialized", "thread/start", "turn/start",
  ]);
  assert.deepEqual(messages[0].params.clientInfo, {
    name: "agendai_agentd",
    title: "AgendAI Meeting Agent",
    version: "0.1.0",
  });
  assert.deepEqual(messages[0].params.capabilities, {
    experimentalApi: false,
    mcpServerOpenaiFormElicitation: false,
    requestAttestation: false,
  });
  assert.equal(messages[1].id, undefined);
  assert.deepEqual(messages[1].params, {});

  const thread = messages[2].params;
  assert.equal(thread.ephemeral, true);
  assert.equal(thread.approvalPolicy, "never");
  assert.equal(thread.cwd, root);
  assert.deepEqual(thread.runtimeWorkspaceRoots, [root]);
  assert.equal(thread.sandbox, "workspace-write");
  assert.equal(thread.developerInstructions, "只写交付目录。");

  const turn = messages[3].params;
  assert.equal(turn.threadId, "thread-fake-1");
  assert.deepEqual(turn.input, [{ type: "text", text: "生成会议结果。" }]);
  assert.equal(turn.approvalPolicy, "never");
  assert.equal(turn.cwd, root);
  assert.deepEqual(turn.runtimeWorkspaceRoots, [root]);
  assert.deepEqual(turn.sandboxPolicy, {
    type: "workspaceWrite",
    networkAccess: true,
    writableRoots: [root],
  });
  assert.deepEqual(turn.outputSchema, outputSchema);
  assert.equal(turn.model, "gpt-test");
  assert.equal(turn.effort, "high");

  assert.equal(result.threadId, "thread-fake-1");
  assert.equal(result.turnId, "turn-fake-1");
  assert.equal(result.turn.status, "completed");
  assert.equal(result.finalMessage, '{"completed":true}');
  assert.equal(result.initializeResult.codexHome, "/tmp/fake-codex-home");
});

test("App Server Client：命名权限配置不与旧 sandbox 参数混用", async () => {
  const { capturePath, root } = await runFake({ permissionsProfile: "tinglan_agent" });
  const messages = (await readFile(capturePath, "utf8")).trim().split("\n").map(JSON.parse);
  assert.deepEqual(messages.map((message) => message.method), [
    "initialize",
    "initialized",
    "config/read",
    "permissionProfile/list",
    "thread/start",
    "turn/start",
  ]);
  assert.deepEqual(messages[2].params, { cwd: root, includeLayers: false });
  assert.deepEqual(messages[3].params, { cwd: root });
  assert.equal("sandbox" in messages[4].params, false);
  assert.equal("runtimeWorkspaceRoots" in messages[4].params, false);
  assert.equal(messages[4].params.ephemeral, true);
  assert.equal("sandboxPolicy" in messages[5].params, false);
  assert.equal("runtimeWorkspaceRoots" in messages[5].params, false);
});

test("App Server Client：可关闭上游不兼容的 Responses text output schema", async () => {
  const { capturePath } = await runFake({ permissionsProfile: "tinglan_agent", sendOutputSchema: false });
  const messages = (await readFile(capturePath, "utf8")).trim().split("\n").map(JSON.parse);
  assert.equal(messages[5].params.outputSchema, undefined);
});

test("App Server Client：JSON-RPC error 转为稳定 Provider 错误", async () => {
  await assert.rejects(
    () => runFake({ mode: "rpc-error" }),
    (error) => error.code === "PROVIDER_FAILED"
      && /JSON-RPC initialize 失败/.test(error.message)
      && error.details.some((detail) => detail === "rpc_code=4100"),
  );
});

test("App Server Client：坏 JSON 立即终止进程并返回稳定错误", async () => {
  await assert.rejects(
    () => runFake({ mode: "bad-json" }),
    (error) => error.code === "PROVIDER_FAILED" && /无效 JSON/.test(error.message),
  );
});

test("App Server Client：进程提前退出携带稳定错误", async () => {
  await assert.rejects(
    () => runFake({ mode: "exit" }),
    (error) => error.code === "PROVIDER_FAILED" && /提前退出/.test(error.message),
  );
});

test("App Server Client：stderr 输出有上限", async () => {
  await assert.rejects(
    () => runFake({ mode: "stderr-exit" }),
    (error) => error.code === "PROVIDER_FAILED"
      && error.details.join("\n").length < 70 * 1024
      && error.details.some((detail) => /stderr_truncated=true/.test(detail)),
  );
});

test("App Server Client：握手超时转为稳定 Provider 错误", async () => {
  await assert.rejects(
    () => runFake({ mode: "timeout", handshakeTimeoutMs: 30 }),
    (error) => error.code === "PROVIDER_FAILED" && /握手超时/.test(error.message),
  );
});

test("App Server Client：turn/completed 超时转为稳定 Provider 错误", async () => {
  await assert.rejects(
    () => runFake({ mode: "turn-timeout", turnTimeoutMs: 30 }),
    (error) => error.code === "PROVIDER_FAILED" && /turn\/completed 等待超时/.test(error.message),
  );
});

test("App Server Client：AbortSignal 取消转为稳定 Provider 错误", async () => {
  const controller = new AbortController();
  const promise = runFake({ mode: "timeout", signal: controller.signal, handshakeTimeoutMs: 5_000 });
  setTimeout(() => controller.abort(), 20);
  await assert.rejects(
    () => promise,
    (error) => error.code === "PROVIDER_FAILED" && /已取消/.test(error.message),
  );
});

test("App Server Client：turn/completed 失败状态不当作成功", async () => {
  await assert.rejects(
    () => runFake({ mode: "turn-failed" }),
    (error) => error.code === "PROVIDER_FAILED"
      && /turn 未成功完成/.test(error.message)
      && error.details.includes("turn_status=failed")
      && !/fake turn failed/.test(error.message),
  );
});

test("App Server Client：ephemeral turn 从流式通知获取最终消息", async () => {
  const { result, capturePath } = await runFake({ mode: "notifications-only" });
  const messages = (await readFile(capturePath, "utf8")).trim().split("\n").map(JSON.parse);
  assert.deepEqual(messages.map((message) => message.method), [
    "initialize", "initialized", "thread/start", "turn/start",
  ]);
  assert.equal(result.turn.itemsView, "notLoaded");
  assert.equal(result.finalMessage, '{"completed":true}');
});

test("App Server Client：任何交互式 Server Request 都会取消并终止", async () => {
  await assert.rejects(
    () => runFake({ mode: "server-request" }),
    (error) => error.code === "PROVIDER_FAILED"
      && /不允许的交互.*commandExecution\/requestApproval/.test(error.message),
  );
});
