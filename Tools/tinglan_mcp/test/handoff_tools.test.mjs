import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { MeetingStore } from "../src/meeting_store.mjs";
import { ObsidianWriter } from "../src/obsidian_writer.mjs";
import { HandoffService } from "../src/server.mjs";
import { stableCandidateId, SyncLedger } from "../src/sync_ledger.mjs";
import {
  createFixture,
  insertMeeting,
  insertSegment,
  openFixture,
  readMeeting,
} from "./fixtures.mjs";

function fixtureWithMeeting(t, meeting = {}) {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  insertMeeting(fixture, meeting);
  insertSegment(fixture);
  return fixture;
}

const detailedSummary = `# 会议纪要

## 一、会议基本信息
- 会议标题：产品周会
- 会议时间：2025-07-01 09:00-09:30
- 会议地点/形式：转写未提供，待确认

## 二、参会人员确认
- 张三：发言人 1；原文依据：张三表示本周完成联调；状态：待确认
- 未识别人员：转写未提供明确姓名；原文依据：发言人 2；状态：待确认

## 三、会议背景与目的
本次会议围绕产品周会的联调进度进行，具体触发事项和预期目标仍需人工确认。

## 四、议程与讨论过程
### 主题一：联调进度
张三提出当前联调安排，发言人 2 讨论了依赖和风险；转写没有记录更多取舍过程。

## 五、已确认结论
- 仅确认本周需要继续推进联调；原文依据：张三表示本周完成联调。

## 六、未决问题与风险
- 会议地点/形式、完整参会人员和联调依赖仍待确认。

## 七、行动项候选
- 事项：完成联调；原文依据：张三表示本周完成联调；负责人：待确认；截止时间：待确认；依赖：待确认；确认状态：待确认。

## 八、人工确认清单
- 参会人员：待确认
- 会议地点/形式：待确认
- 关键结论和行动项：待确认
`;

function confirmedReview(meetingId, contentHash) {
  return {
    meeting_id: meetingId,
    content_hash: contentHash,
    attendees: [{ name: "张三", role: "项目负责人" }],
    context: { location: "线上会议", format: "视频会议" },
    corrections: "参会人员和会议形式已由用户确认。",
    confirmed: true,
  };
}

test("begin 使用 CAS、重复调用幂等且两小时后可接管", (t) => {
  const fixture = fixtureWithMeeting(t);
  const store = new MeetingStore(fixture.config);
  const hash = store.getMeetingPacket("meeting-0001").content_hash;
  assert.equal(store.beginHandoff("meeting-0001", hash, 10_000).state, "started");
  assert.equal(
    store.beginHandoff("meeting-0001", hash, 10_001).state,
    "already_processing",
  );
  assert.equal(readMeeting(fixture).handoff_started_at, 10_000);
  assert.equal(store.beginHandoff("meeting-0001", hash, 17_201).state, "started");
  assert.equal(readMeeting(fixture).handoff_started_at, 17_201);
  assert.throws(() => store.beginHandoff("meeting-0001", "0".repeat(64)), /内容已变化/);
});

test("账本权限、目的地唯一约束和进程重启摘要续跑", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  const hash = "a".repeat(64);
  let ledger = new SyncLedger(fixture.config);
  ledger.saveSummary("m1", hash, "## 摘要\n内容");
  ledger.saveSummary("m1", hash, "不同的重试摘要不会覆盖首份结果");
  assert.equal(ledger.getArtifact("m1", hash, "codex_summary").content, "## 摘要\n内容");
  assert.equal(
    ledger.getStatus("m1", hash).deliveries.find((row) => row.destination === "codex")
      .attempts,
    2,
  );
  ledger.close();

  const directoryMode = fs.statSync(path.dirname(fixture.config.ledgerPath)).mode & 0o777;
  const fileMode = fs.statSync(fixture.config.ledgerPath).mode & 0o777;
  assert.equal(directoryMode, 0o700);
  assert.equal(fileMode, 0o600);

  ledger = new SyncLedger(fixture.config);
  assert.equal(ledger.getArtifact("m1", hash, "codex_summary").content, "## 摘要\n内容");
  ledger.close();
});

test("稳定候选 ID 支持 creating 意图落账且不会被重复确认降级", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  const ledger = new SyncLedger(fixture.config);
  t.after(() => ledger.close());
  const hash = "b".repeat(64);
  const base = { title: "提交报价", evidence: "王工：周五前提交报价。" };
  assert.equal(
    stableCandidateId("m1", hash, base),
    stableCandidateId("m1", hash, { ...base, description: "不影响身份" }),
  );
  ledger.saveCandidates("m1", hash, [{ ...base, status: "creating" }]);
  ledger.saveCandidates("m1", hash, [{ ...base, status: "awaiting_approval" }]);
  assert.equal(ledger.listCandidates("m1", hash)[0].status, "creating");
  ledger.saveCandidates("m1", hash, [
    {
      ...base,
      status: "created",
      zentao_task_id: "123",
      zentao_url: "https://zentao.example/task/123",
    },
  ]);
  const created = ledger.listCandidates("m1", hash)[0];
  assert.equal(created.status, "created");
  assert.equal(created.zentao_task_id, "123");
  ledger.saveCandidates("m1", hash, [{ ...base, status: "creating" }]);
  ledger.saveCandidates("m1", hash, [{ ...base, status: "skipped" }]);
  ledger.saveCandidates("m1", hash, [
    { ...base, status: "created", zentao_task_id: "replacement" },
  ]);
  assert.equal(ledger.listCandidates("m1", hash)[0].status, "created");
  assert.equal(ledger.listCandidates("m1", hash)[0].zentao_task_id, "123");
  assert.throws(
    () => ledger.saveCandidates("m2", hash, [{ ...base, status: "created" }]),
    /必须包含 zentao_task_id/,
  );
  ledger.saveCandidates("m3", hash, [{ ...base, status: "skipped" }]);
  ledger.saveCandidates("m3", hash, [
    { ...base, status: "created", zentao_task_id: "should-not-replace" },
  ]);
  assert.equal(ledger.listCandidates("m3", hash)[0].status, "skipped");
});

test("Obsidian 使用安全确定路径，崩溃后复用文件且保留用户编辑", async (t) => {
  const fixture = fixtureWithMeeting(t, { title: "../季度/复盘:*?" });
  const store = new MeetingStore(fixture.config);
  const packet = store.getMeetingPacket("meeting-0001");
  let crashed = false;
  const crashingWriter = new ObsidianWriter({
    root: fixture.config.obsidianRoot,
    hooks: {
      afterSourcePublish() {
        if (!crashed) {
          crashed = true;
          throw new Error("模拟源文件发布后崩溃");
        }
      },
    },
  });
  await assert.rejects(
    crashingWriter.writeMeeting(packet, packet.content_hash, "## 摘要\n第一版"),
    /模拟源文件发布后崩溃/,
  );

  const writer = new ObsidianWriter({ root: fixture.config.obsidianRoot });
  const first = await writer.writeMeeting(packet, packet.content_hash, "## 摘要\n第一版");
  assert.ok(first.source.path.startsWith(path.resolve(fixture.config.obsidianRoot) + path.sep));
  assert.doesNotMatch(path.basename(first.source.path), /[/:*?]/);
  fs.appendFileSync(first.draft.path, "\n用户补充内容\n");
  const retried = await writer.writeMeeting(packet, packet.content_hash, "## 摘要\n重试生成");
  assert.equal(retried.draft.path, first.draft.path);
  assert.match(fs.readFileSync(first.draft.path, "utf8"), /用户补充内容/);
  assert.equal(retried.draft.checksum, stableFileHash(first.draft.path));
  await assert.rejects(
    writer.verifyArtifacts(
      packet.meeting.meeting_id,
      packet.content_hash,
      "/tmp/outside-source.md",
      first.draft.path,
    ),
    /根目录之外/,
  );
});

test("Obsidian 拒绝根目录内的符号链接逃逸", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const packet = new MeetingStore(fixture.config).getMeetingPacket("meeting-0001");
  const outside = path.join(fixture.root, "outside");
  const sourceParent = path.join(
    fixture.config.obsidianRoot,
    "30_Sources/会小纪会议",
  );
  fs.mkdirSync(sourceParent, { recursive: true });
  fs.mkdirSync(outside);
  fs.symlinkSync(outside, path.join(sourceParent, "2025"), "dir");
  const writer = new ObsidianWriter({ root: fixture.config.obsidianRoot });
  await assert.rejects(
    writer.writeMeeting(packet, packet.content_hash, "摘要"),
    /符号链接/,
  );
  assert.deepEqual(fs.readdirSync(outside), []);
});

function stableFileHash(filePath) {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

test("服务端完整交接：文件、候选、归档和通知均幂等", async (t) => {
  const fixture = fixtureWithMeeting(t);
  let notifications = 0;
  const service = new HandoffService(fixture.config, {
    notifier: () => {
      notifications += 1;
      return true;
    },
  });
  t.after(() => service.close());
  const pending = service.listPendingMeetings().meetings;
  assert.equal(pending.length, 1);
  const { meeting_id: meetingId, content_hash: hash } = pending[0];
  service.beginHandoff(meetingId, hash);
  await service.recordDelivery({
    meeting_id: meetingId,
    content_hash: hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: meetingId,
    content_hash: hash,
    destination: "obsidian",
    status: "succeeded",
  });
  const status = await service.recordDelivery({
    meeting_id: meetingId,
    content_hash: hash,
    destination: "zentao_candidates",
    status: "succeeded",
    candidates: [{ title: "完成联调", evidence: "张三：本周完成联调。" }],
  });
  assert.equal(status.task_candidates.length, 1);
  const obsidianDelivery = status.deliveries.find((row) => row.destination === "obsidian");
  assert.equal(obsidianDelivery.error_summary, null);
  assert.deepEqual(Object.keys(obsidianDelivery.external_ref).sort(), ["draft_path", "source_path"]);
  const reviewReady = await service.prepareHandoffReview(meetingId, hash);
  assert.equal(reviewReady.state, "review_ready");
  assert.equal(reviewReady.archived, false);
  assert.equal(notifications, 1);
  assert.equal(readMeeting(fixture).is_archived, 0);
  assert.equal(readMeeting(fixture).handoff_status, "completed");
  const completed = await service.confirmHandoff(confirmedReview(meetingId, hash));
  assert.equal(completed.state, "completed");
  assert.equal(notifications, 2);
  assert.equal(readMeeting(fixture).is_archived, 1);
  assert.equal((await service.confirmHandoff(confirmedReview(meetingId, hash))).state, "already_completed");
  assert.equal(notifications, 2);
  await service.recordDelivery({
    meeting_id: meetingId,
    content_hash: hash,
    destination: "zentao_candidates",
    status: "succeeded",
    candidates: [
      {
        title: "完成联调",
        evidence: "张三：本周完成联调。",
        status: "creating",
      },
    ],
  });
  const reconciled = await service.recordDelivery({
    meeting_id: meetingId,
    content_hash: hash,
    destination: "zentao_candidates",
    status: "succeeded",
    candidates: [
      {
        title: "完成联调",
        evidence: "张三：本周完成联调。",
        status: "created",
        zentao_task_id: "T-42",
        zentao_url: "https://zentao.example/task/42",
      },
    ],
  });
  assert.equal(reconciled.task_candidates[0].status, "created");
  assert.match(
    fs.readFileSync(
      reconciled.artifacts.find((artifact) => artifact.kind === "obsidian_draft").path,
      "utf8",
    ),
    /T-42/,
  );
});

test("详细纪要必须交代基本信息、参会人员、过程、结论、风险和行动项", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config);
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await assert.rejects(
    service.recordDelivery({
      meeting_id: "meeting-0001",
      content_hash: packet.content_hash,
      destination: "codex",
      status: "succeeded",
      summary: "## 摘要\n一句话，不足以作为会议纪要。",
    }),
    /详细会议纪要缺少必要章节/,
  );
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  const review = await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  assert.equal(review.state, "review_ready");
  assert.equal(readMeeting(fixture).is_archived, 0);
  assert.equal(readMeeting(fixture).handoff_status, "completed");
});

test("未人工确认不能归档，confirm_handoff 写入参会人和会议背景并幂等", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config);
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  await assert.rejects(
    service.completeHandoff("meeting-0001", packet.content_hash),
    /必须通过 confirm_handoff/,
  );
  const draftPath = service
    .getDeliveryStatus("meeting-0001", packet.content_hash)
    .artifacts.find((artifact) => artifact.kind === "obsidian_draft").path;
  fs.appendFileSync(draftPath, "\n用户保留的补充说明\n");
  const confirmed = await service.confirmHandoff({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    attendees: [{ name: "张三", role: "项目负责人" }],
    context: { location: "线上会议", format: "视频会议" },
    corrections: "参会人员中的张三已确认。",
    confirmed: true,
  });
  assert.equal(confirmed.state, "completed");
  assert.equal(readMeeting(fixture).is_archived, 1);
  assert.equal(readMeeting(fixture).handoff_status, "completed");
  const content = fs.readFileSync(draftPath, "utf8");
  assert.match(content, /用户保留的补充说明/);
  assert.match(content, /张三/);
  assert.match(content, /线上会议/);
  const repeated = await service.confirmHandoff({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    attendees: [{ name: "张三", role: "项目负责人" }],
    context: { location: "线上会议", format: "视频会议" },
    corrections: "参会人员中的张三已确认。",
    confirmed: true,
  });
  assert.equal(repeated.state, "already_completed");
  await assert.rejects(
    service.confirmHandoff({
      ...confirmedReview("meeting-0001", packet.content_hash),
      attendees: [{ name: "李四" }],
    }),
    /不能用不同内容覆盖/,
  );
});

test("人工确认的新标题同步到会小纪、纪要、Obsidian 路径和候选任务", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config, { notifier: () => true });
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "zentao_candidates",
    status: "succeeded",
    candidates: [{ title: "确认模板", evidence: "原文明确要求确认模板" }],
  });
  await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  const before = service.getDeliveryStatus("meeting-0001", packet.content_hash);
  const oldSource = before.artifacts.find((artifact) => artifact.kind === "obsidian_source").path;
  const oldDraft = before.artifacts.find((artifact) => artifact.kind === "obsidian_draft").path;
  fs.appendFileSync(oldDraft, "\n用户保留的标题修订说明\n");

  const input = {
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    attendees: [{ name: "张三", role: "项目负责人" }],
    context: { meeting_format: "线上会议", title: "国控需求澄清与讨论会0716" },
    corrections: "会议标题改成：国控需求澄清与讨论会0716。",
    confirmed: true,
  };
  const confirmed = await service.confirmHandoff(input);
  assert.equal(confirmed.state, "completed");
  assert.equal(confirmed.title_update.state, "updated");
  assert.equal(readMeeting(fixture).title, "国控需求澄清与讨论会0716");
  assert.equal(readMeeting(fixture).is_archived, 1);

  const status = service.getDeliveryStatus("meeting-0001", packet.content_hash);
  const summary = status.artifacts.find((artifact) => artifact.kind === "codex_summary").content;
  const source = status.artifacts.find((artifact) => artifact.kind === "obsidian_source");
  const draft = status.artifacts.find((artifact) => artifact.kind === "obsidian_draft");
  assert.match(summary, /- 标题：国控需求澄清与讨论会0716/);
  assert.doesNotMatch(summary, /会议标题：产品周会/);
  assert.match(path.basename(source.path), /国控需求澄清与讨论会0716/);
  assert.match(path.basename(draft.path), /国控需求澄清与讨论会0716/);
  assert.equal(fs.existsSync(oldSource), false);
  assert.equal(fs.existsSync(oldDraft), false);
  assert.match(fs.readFileSync(source.path, "utf8"), /# 国控需求澄清与讨论会0716 - 原始转写/);
  const draftContent = fs.readFileSync(draft.path, "utf8");
  assert.match(draftContent, /^# 国控需求澄清与讨论会0716$/m);
  assert.match(draftContent, /- 标题：国控需求澄清与讨论会0716/);
  assert.match(draftContent, /用户保留的标题修订说明/);
  assert.equal(status.task_candidates[0].obsidian_path, draft.path);

  const repeated = await service.confirmHandoff(input);
  assert.equal(repeated.state, "already_completed");
  assert.equal(repeated.title_update.state, "already_updated");
});

test("review-ready 会议列为 human_review，否决确认只保留修改意见且不归档", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config);
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  const pending = service.listPendingMeetings().meetings;
  assert.equal(pending.length, 1);
  assert.equal(pending[0].attention_type, "human_review");
  assert.deepEqual(pending[0].pending_destinations, ["human_review"]);
  const requested = await service.confirmHandoff({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    attendees: [],
    context: { location: "待确认", format: "待确认" },
    corrections: "请补充完整参会人员。",
    confirmed: false,
  });
  assert.equal(requested.state, "review_changes_requested");
  assert.equal(readMeeting(fixture).is_archived, 0);
  assert.equal(service.listPendingMeetings().meetings[0].attention_type, "human_review");
});

test("人工确认区更新做正文 CAS，并能以相同确认内容安全重试", async (t) => {
  const fixture = fixtureWithMeeting(t);
  let injectEdit = true;
  const writer = new ObsidianWriter({
    root: fixture.config.obsidianRoot,
    hooks: {
      beforeReviewReplace({ draftPath }) {
        if (injectEdit) {
          injectEdit = false;
          fs.appendFileSync(draftPath, "\n并发用户补充\n");
        }
      },
    },
  });
  const service = new HandoffService(fixture.config, { writer });
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  const input = confirmedReview("meeting-0001", packet.content_hash);
  await assert.rejects(service.confirmHandoff(input), /更新人工确认区期间发生变化/);
  assert.equal(readMeeting(fixture).is_archived, 0);
  const draftPath = service
    .getDeliveryStatus("meeting-0001", packet.content_hash)
    .artifacts.find((artifact) => artifact.kind === "obsidian_draft").path;
  assert.match(fs.readFileSync(draftPath, "utf8"), /并发用户补充/);
  const retried = await service.confirmHandoff(input);
  assert.equal(retried.state, "completed");
  assert.equal(readMeeting(fixture).is_archived, 1);
  assert.match(fs.readFileSync(draftPath, "utf8"), /确认状态：已确认/);
});

test("摘要和 Obsidian 不能绕过 begin_handoff", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config);
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  await assert.rejects(
    service.recordDelivery({
      meeting_id: "meeting-0001",
      content_hash: packet.content_hash,
      destination: "codex",
      status: "succeeded",
      summary: "越权摘要",
    }),
    /尚未 begin_handoff/,
  );
  assert.equal(
    service.getDeliveryStatus("meeting-0001", packet.content_hash).deliveries.length,
    0,
  );
});

test("禅道候选失败不改变会议交接状态，摘要和 Obsidian 成功后仍可归档", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config, { notifier: () => true });
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "zentao_candidates",
    status: "failed",
    error: "候选提取暂时失败",
  });
  assert.equal(readMeeting(fixture).handoff_status, "processing");
  assert.equal(
    service.getDeliveryStatus("meeting-0001", packet.content_hash).deliveries.find(
      (row) => row.destination === "zentao_candidates",
    ).status,
    "failed",
  );
  await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  assert.equal(readMeeting(fixture).is_archived, 0);
  assert.equal(service.listPendingMeetings().meetings[0].attention_type, "human_review");
  assert.equal(
    (await service.confirmHandoff(confirmedReview("meeting-0001", packet.content_hash))).state,
    "completed",
  );
  const retry = service.listPendingMeetings().meetings;
  assert.equal(retry.length, 1);
  assert.equal(retry[0].handoff_status, "completed");
  assert.equal(retry[0].attention_type, "delivery_retry");
  assert.deepEqual(retry[0].pending_destinations, ["zentao_candidates"]);
  assert.equal(
    service.getMeetingPacket("meeting-0001").content_hash,
    packet.content_hash,
  );
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "zentao_candidates",
    status: "succeeded",
    candidates: [{ title: "补充候选", evidence: "原文中的明确行动项" }],
  });
  assert.equal(service.listPendingMeetings().meetings.length, 0);
});

test("候选保存后机器区更新失败不会提前成功，重试补写后才成功", async (t) => {
  const fixture = fixtureWithMeeting(t);
  let shouldFail = true;
  const writer = new ObsidianWriter({
    root: fixture.config.obsidianRoot,
    hooks: {
      beforeManagedReplace() {
        if (shouldFail) {
          shouldFail = false;
          throw new Error("模拟机器区更新崩溃");
        }
      },
    },
  });
  const service = new HandoffService(fixture.config, { writer });
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  const input = {
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "zentao_candidates",
    status: "succeeded",
    candidates: [{ title: "完成联调", evidence: "原文明确要求完成联调" }],
  };
  await assert.rejects(service.recordDelivery(input), /机器区更新崩溃/);
  let delivery = service
    .getDeliveryStatus("meeting-0001", packet.content_hash)
    .deliveries.find((row) => row.destination === "zentao_candidates");
  assert.equal(delivery.status, "failed");
  assert.equal(readMeeting(fixture).handoff_status, "processing");
  const retried = await service.recordDelivery(input);
  delivery = retried.deliveries.find((row) => row.destination === "zentao_candidates");
  assert.equal(delivery.status, "succeeded");
  const draft = retried.artifacts.find((artifact) => artifact.kind === "obsidian_draft");
  assert.match(fs.readFileSync(draft.path, "utf8"), /完成联调/);
});

test("两份文件发布后、账本写入前崩溃，重启只补账本不重复文件", async (t) => {
  const fixture = fixtureWithMeeting(t);
  let shouldCrash = true;
  const crashingWriter = new ObsidianWriter({
    root: fixture.config.obsidianRoot,
    hooks: {
      afterDraftPublish() {
        if (shouldCrash) {
          shouldCrash = false;
          throw new Error("模拟文件发布后账本前崩溃");
        }
      },
    },
  });
  let service = new HandoffService(fixture.config, { writer: crashingWriter });
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await assert.rejects(
    service.recordDelivery({
      meeting_id: "meeting-0001",
      content_hash: packet.content_hash,
      destination: "obsidian",
      status: "succeeded",
    }),
    /账本前崩溃/,
  );
  service.close();
  assert.equal(readMeeting(fixture).handoff_status, "failed");
  assert.equal(findMarkdown(fixture.config.obsidianRoot).length, 2);

  service = new HandoffService(fixture.config);
  t.after(() => service.close());
  service.beginHandoff("meeting-0001", packet.content_hash);
  const status = await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  assert.equal(
    status.deliveries.find((row) => row.destination === "obsidian").status,
    "succeeded",
  );
  assert.equal(findMarkdown(fixture.config.obsidianRoot).length, 2);
});

function findMarkdown(root) {
  if (!fs.existsSync(root)) return [];
  return fs
    .readdirSync(root, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md"));
}

test("禅道机器区更新做正文 CAS，并保留并发用户编辑", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const packet = new MeetingStore(fixture.config).getMeetingPacket("meeting-0001");
  let draftPath;
  const writer = new ObsidianWriter({
    root: fixture.config.obsidianRoot,
    hooks: {
      beforeManagedReplace({ draftPath: target }) {
        fs.appendFileSync(target, "\n并发用户编辑\n");
      },
    },
  });
  const files = await writer.writeMeeting(packet, packet.content_hash, "摘要");
  draftPath = files.draft.path;
  await assert.rejects(
    writer.updateZentaoBlock(draftPath, "meeting-0001", packet.content_hash, [
      {
        candidate_id: "candidate-1",
        title: "联调",
        status: "awaiting_approval",
      },
    ]),
    /更新期间发生变化/,
  );
  const content = fs.readFileSync(draftPath, "utf8");
  assert.match(content, /并发用户编辑/);
  assert.doesNotMatch(content, /candidate-1/);
});

test("prepare 缺少前置交付会拒绝，内容变化会提交 pending 后报错", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config, { notifier: () => true });
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await assert.rejects(
    service.prepareHandoffReview("meeting-0001", packet.content_hash),
    /摘要尚未成功/,
  );
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  const db = openFixture(fixture);
  db.prepare("UPDATE meetings SET title = ? WHERE id = ?").run("标题已修改", "meeting-0001");
  db.close();
  await assert.rejects(
    service.prepareHandoffReview("meeting-0001", packet.content_hash),
    /发生变化，已重新排队/,
  );
  const meeting = readMeeting(fixture);
  assert.equal(meeting.handoff_status, "pending");
  assert.equal(meeting.is_archived, 0);
  assert.equal(meeting.handoff_content_hash, null);
});

test("恢复先发生时，重复 confirm 不会把会议重新归档", async (t) => {
  const fixture = fixtureWithMeeting(t);
  const service = new HandoffService(fixture.config, { notifier: () => true });
  t.after(() => service.close());
  const packet = service.getMeetingPacket("meeting-0001");
  service.beginHandoff("meeting-0001", packet.content_hash);
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "codex",
    status: "succeeded",
    summary: detailedSummary,
  });
  await service.recordDelivery({
    meeting_id: "meeting-0001",
    content_hash: packet.content_hash,
    destination: "obsidian",
    status: "succeeded",
  });
  await service.prepareHandoffReview("meeting-0001", packet.content_hash);
  await service.confirmHandoff(confirmedReview("meeting-0001", packet.content_hash));
  const db = openFixture(fixture);
  db.prepare(
    `UPDATE meetings SET is_archived = 0, handoff_status = 'pending',
       handoff_started_at = NULL, handoff_completed_at = NULL,
       handoff_content_hash = NULL WHERE id = ?`,
  ).run("meeting-0001");
  db.close();
  await assert.rejects(
    service.confirmHandoff(confirmedReview("meeting-0001", packet.content_hash)),
    /尚未进入待人工确认/,
  );
  assert.equal(readMeeting(fixture).is_archived, 0);
});

test("录音失败会议只产生一次 failure_notice", async (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  insertMeeting(fixture, {
    id: "failed-meeting",
    status: "failed",
    handoff_status: "ignored",
    error_message: "录音设备断开",
  });
  const service = new HandoffService(fixture.config);
  t.after(() => service.close());
  const first = service.listPendingMeetings().meetings;
  assert.equal(first.length, 1);
  assert.equal(first[0].pending_destinations[0], "failure_notice");
  const claimed = await service.recordDelivery({
    meeting_id: first[0].meeting_id,
    content_hash: first[0].content_hash,
    destination: "failure_notice",
    status: "succeeded",
  });
  assert.equal(claimed.failure_notice_claimed, true);
  assert.equal(
    claimed.deliveries.find((row) => row.destination === "failure_notice").attempts,
    1,
  );
  const conflict = await service.recordDelivery({
    meeting_id: first[0].meeting_id,
    content_hash: first[0].content_hash,
    destination: "failure_notice",
    status: "succeeded",
  });
  assert.equal(conflict.failure_notice_claimed, false);
  assert.equal(
    conflict.deliveries.find((row) => row.destination === "failure_notice").attempts,
    1,
  );
  assert.equal(service.listPendingMeetings().meetings.length, 0);
  const db = openFixture(fixture);
  db.prepare("UPDATE meetings SET title = ? WHERE id = ?").run(
    "失败会议标题已修改",
    "failed-meeting",
  );
  db.close();
  assert.equal(service.listPendingMeetings().meetings.length, 0);
  assert.equal(
    service.ledger.claimFailureNotice("failed-meeting", "f".repeat(64)),
    false,
  );
  assert.equal(
    service.ledger.getStatus("failed-meeting", "f".repeat(64)).deliveries.length,
    0,
  );
});

test("大量已 claim 的失败提醒不会饿死正常 pending 会议", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  for (let index = 0; index < 101; index += 1) {
    insertMeeting(fixture, {
      id: `failed-${String(index).padStart(3, "0")}`,
      status: "failed",
      ended_at: index,
      handoff_status: "ignored",
    });
  }
  insertMeeting(fixture, {
    id: "normal-pending",
    status: "done",
    ended_at: 1000,
    handoff_status: "pending",
  });
  const service = new HandoffService(fixture.config);
  t.after(() => service.close());
  for (const meeting of service.store.listPending({ limit: null })) {
    if (meeting.attention_type === "recording_failed") {
      service.ledger.claimFailureNotice(meeting.meeting_id, meeting.content_hash);
    }
  }
  assert.deepEqual(
    service.listPendingMeetings().meetings.map((meeting) => meeting.meeting_id),
    ["normal-pending"],
  );
});
