import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { createFixture, insertMeeting, insertSegment, readMeeting } from "./fixtures.mjs";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const detailedSummary = `# 会议纪要
## 一、会议基本信息
时间、地点和形式：转写未提供，待确认。
## 二、参会人员确认
张三，原文依据：转写中的明确姓名，待确认。
## 三、会议背景与目的
本次会议讨论产品联调安排，具体触发事项待确认。
## 四、议程与讨论过程
围绕联调进度、依赖和风险进行了讨论，转写未提供更多分歧信息。
## 五、已确认结论
继续推进联调；原文依据：张三提出本周完成联调。
## 六、未决问题与风险
完整参会人员和依赖仍待确认。
## 七、行动项候选
完成联调；原文依据：张三提出本周完成；负责人和截止时间待确认。
## 八、人工确认清单
确认参会人员、会议形式、结论和行动项。`;

function environment(fixture) {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: process.env.HOME ?? fixture.root,
    LANG: process.env.LANG ?? "en_US.UTF-8",
    TINGLAN_DB_PATH: fixture.config.databasePath,
    TINGLAN_LEDGER_PATH: fixture.config.ledgerPath,
    TINGLAN_OBSIDIAN_ROOT: fixture.config.obsidianRoot,
    TINGLAN_NOTIFYUTIL_PATH: "/usr/bin/true",
    TINGLAN_BUSY_TIMEOUT_MS: "1000",
  };
}

async function callRaw(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  if (result.isError) {
    const message = result.content?.find((item) => item.type === "text")?.text;
    throw new Error(message || `${name} 调用失败`);
  }
  return result;
}

async function call(client, name, args = {}) {
  return (await callRaw(client, name, args)).structuredContent;
}

test("真实 STDIO MCP 暴露八个受注解工具并完成先审阅后归档", async (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  insertMeeting(fixture);
  insertSegment(fixture);

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--no-warnings", path.join(projectRoot, "src/index.mjs")],
    cwd: projectRoot,
    env: environment(fixture),
    stderr: "pipe",
  });
  const client = new Client({ name: "tinglan-test-client", version: "0.1.0" });
  await client.connect(transport);
  t.after(async () => client.close());

  assert.match(client.getInstructions(), /prepare_handoff_review/);
  assert.match(client.getInstructions(), /不要自动创建禅道任务/);
  const listed = await client.listTools();
  assert.deepEqual(
    listed.tools.map((tool) => tool.name).sort(),
    [
      "begin_handoff",
      "complete_handoff",
      "confirm_handoff",
      "get_delivery_status",
      "get_meeting_packet",
      "list_pending_meetings",
      "prepare_handoff_review",
      "record_delivery",
    ],
  );
  const readTool = listed.tools.find((tool) => tool.name === "get_meeting_packet");
  const writeTool = listed.tools.find((tool) => tool.name === "confirm_handoff");
  const recordTool = listed.tools.find((tool) => tool.name === "record_delivery");
  assert.equal(readTool.annotations.readOnlyHint, true);
  assert.equal(writeTool.annotations.readOnlyHint, false);
  assert.equal(writeTool.annotations.destructiveHint, true);
  assert.equal(recordTool.annotations.idempotentHint, false);

  const pending = await call(client, "list_pending_meetings");
  assert.equal(pending.meetings.length, 1);
  const meetingId = pending.meetings[0].meeting_id;
  const hash = pending.meetings[0].content_hash;
  const packetResult = await callRaw(client, "get_meeting_packet", { meeting_id: meetingId });
  assert.equal(packetResult.structuredContent, undefined);
  assert.equal(packetResult.content.length, 1);
  const packet = JSON.parse(packetResult.content[0].text);
  assert.equal(packet.content_hash, hash);
  assert.deepEqual(Object.keys(packet.segments[0]).sort(), [
    "end_ms",
    "speaker",
    "start_ms",
    "text",
  ]);
  assert.doesNotMatch(packetResult.content[0].text, /segment_id/);
  await call(client, "begin_handoff", { meeting_id: meetingId, content_hash: hash });
  const recordedSummary = await callRaw(client, "record_delivery", {
    meeting_id: meetingId,
    content_hash: hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  assert.equal(
    recordedSummary.structuredContent.artifacts.some((artifact) => "content" in artifact),
    false,
  );
  assert.doesNotMatch(recordedSummary.content[0].text, /本次会议讨论产品联调安排/);
  await call(client, "record_delivery", {
    meeting_id: meetingId,
    content_hash: hash,
    destination: "obsidian",
    status: "succeeded",
  });
  const reviewReadyResult = await callRaw(client, "prepare_handoff_review", {
    meeting_id: meetingId,
    content_hash: hash,
  });
  const reviewReady = reviewReadyResult.structuredContent;
  assert.equal(reviewReady.state, "review_ready");
  assert.equal(reviewReady.artifacts.some((artifact) => "content" in artifact), false);
  assert.doesNotMatch(reviewReadyResult.content[0].text, /本次会议讨论产品联调安排/);
  const compactStatus = await call(client, "get_delivery_status", {
    meeting_id: meetingId,
    content_hash: hash,
  });
  assert.equal(compactStatus.summary, undefined);
  assert.equal(compactStatus.artifacts.some((artifact) => "content" in artifact), false);
  const statusWithSummary = await call(client, "get_delivery_status", {
    meeting_id: meetingId,
    content_hash: hash,
    include_summary: true,
  });
  assert.equal(statusWithSummary.summary, detailedSummary);
  assert.equal(statusWithSummary.artifacts.some((artifact) => "content" in artifact), false);
  assert.equal(readMeeting(fixture).is_archived, 0);
  const reviewPending = await call(client, "list_pending_meetings");
  assert.equal(reviewPending.meetings[0].attention_type, "human_review");
  const completed = await call(client, "confirm_handoff", {
    meeting_id: meetingId,
    content_hash: hash,
    attendees: [{ name: "张三", role: "项目负责人" }],
    context: { location: "线上", format: "视频会议" },
    corrections: "无其他修订。",
    confirmed: true,
  });
  assert.equal(completed.state, "completed");
  assert.equal(readMeeting(fixture).is_archived, 1);
});

test("未迁移数据库不阻塞握手，调用工具时给出迁移提示", async (t) => {
  const fixture = createFixture({ migrated: false });
  t.after(() => fixture.cleanup());

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--no-warnings", path.join(projectRoot, "src/index.mjs")],
    cwd: projectRoot,
    env: environment(fixture),
    stderr: "pipe",
  });
  const client = new Client({ name: "tinglan-migration-test-client", version: "0.1.0" });
  await client.connect(transport);
  t.after(async () => client.close());

  const listed = await client.listTools();
  assert.equal(listed.tools.length, 8);
  assert.equal(fs.existsSync(fixture.config.ledgerPath), false);
  const result = await client.callTool({
    name: "list_pending_meetings",
    arguments: {},
  });
  assert.equal(result.isError, true);
  const message = result.content?.find((item) => item.type === "text")?.text;
  assert.match(message ?? "", /尚未完成交接字段迁移/);
  assert.match(message ?? "", /请先安装并启动新版会小纪/);
});
