import { spawnSync } from "node:child_process";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { MeetingStore } from "./meeting_store.mjs";
import { SyncLedger } from "./sync_ledger.mjs";
import { ObsidianWriter } from "./obsidian_writer.mjs";

function shortText(value) {
  return JSON.stringify(value, null, 2).slice(0, 12_000);
}

function toolResult(value, text = null) {
  return {
    content: [{ type: "text", text: text ?? shortText(value) }],
    structuredContent: value,
  };
}

function textOnlyResult(text) {
  return {
    content: [{ type: "text", text }],
  };
}

function compactMeetingPacketText(packet) {
  return JSON.stringify({
    meeting_id: packet.meeting.meeting_id,
    title: packet.meeting.title,
    started_at: packet.meeting.started_at,
    ended_at: packet.meeting.ended_at,
    content_hash: packet.content_hash,
    segments: packet.segments.map((segment) => ({
      start_ms: segment.start_ms,
      end_ms: segment.end_ms,
      speaker: segment.speaker,
      text: segment.text,
    })),
    directory: packet.directory,
  });
}

function compactStatus(value, { includeSummary = false } = {}) {
  const compact = {};
  for (const key of [
    "meeting_id",
    "content_hash",
    "state",
    "review_required",
    "archived",
    "notification_sent",
    "failure_notice_claimed",
  ]) {
    if (value?.[key] !== undefined) compact[key] = value[key];
  }
  if (Array.isArray(value?.deliveries)) compact.deliveries = value.deliveries;
  if (Array.isArray(value?.artifacts)) {
    compact.artifacts = value.artifacts.map((artifact) => ({
      kind: artifact.kind,
      path: artifact.path ?? null,
      checksum: artifact.checksum,
    }));
    if (includeSummary) {
      compact.summary =
        value.artifacts.find((artifact) => artifact.kind === "codex_summary")?.content ?? null;
    }
  }
  if (Array.isArray(value?.task_candidates)) {
    compact.task_candidates = value.task_candidates;
  }
  if (Array.isArray(value?.pending_destinations)) {
    compact.pending_destinations = value.pending_destinations;
  }
  if (value?.review !== undefined) compact.review = value.review;
  return compact;
}

function errorResult(error) {
  const message = error instanceof Error ? error.message : String(error);
  return {
    content: [{ type: "text", text: message }],
    isError: true,
  };
}

const REQUIRED_MINUTE_SECTIONS = [
  "一、会议基本信息",
  "二、参会人员确认",
  "三、会议背景与目的",
  "四、议程与讨论过程",
  "五、已确认结论",
  "六、未决问题与风险",
  "七、行动项候选",
  "八、人工确认清单",
];

export function validateDetailedMinutes(summary) {
  const normalized = String(summary ?? "").replace(/\r\n?/g, "\n").trim();
  if (!normalized) throw new Error("Codex 摘要不能为空");
  const headings = new Set(
    normalized
      .split("\n")
      .map((line) => line.match(/^##\s+(.+?)\s*$/)?.[1])
      .filter(Boolean),
  );
  const missing = REQUIRED_MINUTE_SECTIONS.filter((section) => !headings.has(section));
  if (missing.length) {
    throw new Error(`详细会议纪要缺少必要章节：${missing.join("、")}`);
  }
  if (!/待确认|未提供|未知/.test(normalized)) {
    throw new Error("详细会议纪要必须明确标出无法从转写确认的信息");
  }
  if (!/原文依据|原文证据|转写/.test(normalized)) {
    throw new Error("详细会议纪要必须保留关键结论和行动项的原文依据");
  }
  return normalized;
}

export function applyConfirmedMeetingTitle(summary, title) {
  const normalizedTitle = String(title ?? "").normalize("NFC").trim();
  if (!normalizedTitle) throw new Error("会议标题不能为空");
  const normalized = String(summary ?? "").replace(/\r\n?/g, "\n").trim();
  const sectionPattern = /(##\s+一、会议基本信息\s*\n)([\s\S]*?)(?=\n##\s+|$)/;
  const match = normalized.match(sectionPattern);
  if (!match) throw new Error("会议纪要缺少“会议基本信息”章节");
  const titlePattern = /^-\s*(?:会议)?标题\s*[：:].*$/m;
  const details = titlePattern.test(match[2])
    ? match[2].replace(titlePattern, `- 标题：${normalizedTitle}`)
    : `- 标题：${normalizedTitle}\n${match[2]}`;
  return validateDetailedMinutes(
    normalized.replace(sectionPattern, `${match[1]}${details}`),
  );
}

function defaultNotifier(config) {
  const result = spawnSync(config.notifyutilPath, ["-p", config.notifyKey], {
    stdio: "ignore",
    timeout: 3000,
  });
  return result.status === 0;
}

export class HandoffService {
  constructor(config, dependencies = {}) {
    this.config = config;
    this._store = dependencies.store ?? null;
    this._ledger = dependencies.ledger ?? null;
    this._writer = dependencies.writer ?? null;
    this._notifier = dependencies.notifier ?? null;
  }

  get store() {
    this._store ??= new MeetingStore({
      databasePath: this.config.databasePath,
      busyTimeoutMs: this.config.busyTimeoutMs,
      staleProcessingSeconds: this.config.staleProcessingSeconds,
    });
    return this._store;
  }

  get ledger() {
    this._ledger ??= new SyncLedger({
      ledgerPath: this.config.ledgerPath,
      busyTimeoutMs: this.config.busyTimeoutMs,
    });
    return this._ledger;
  }

  get writer() {
    this._writer ??= new ObsidianWriter({ root: this.config.obsidianRoot });
    return this._writer;
  }

  get notifier() {
    this._notifier ??= () => defaultNotifier(this.config);
    return this._notifier;
  }

  close() {
    this._ledger?.close();
  }

  validate() {
    this.store.validateSchema();
  }

  listPendingMeetings() {
    const rows = this.store.listPending({ limit: null });
    const meetings = rows
      .filter((meeting) => {
        if (meeting.attention_type !== "recording_failed") return true;
        return !this.ledger.hasFailureNoticeClaim(meeting.meeting_id);
      })
      .map((meeting) => ({
        meeting_id: meeting.meeting_id,
        title: meeting.title,
        ended_at: meeting.ended_at,
        segment_count: meeting.segment_count,
        content_hash: meeting.content_hash,
        handoff_status: meeting.handoff_status,
        attention_type:
          meeting.status === "done" &&
          !meeting.is_archived &&
          meeting.handoff_status === "completed"
            ? "human_review"
            : meeting.attention_type,
        pending_destinations:
          meeting.status === "done" &&
          !meeting.is_archived &&
          meeting.handoff_status === "completed"
            ? ["human_review"]
            : meeting.attention_type === "recording_failed"
            ? ["failure_notice"]
            : this.ledger.pendingDestinations(meeting.meeting_id, meeting.content_hash),
        review: this.ledger.getReview(meeting.meeting_id, meeting.content_hash),
      }));
    const existing = new Set(
      meetings.map((meeting) => `${meeting.meeting_id}:${meeting.content_hash}`),
    );
    for (const failed of this.ledger.listFailedDeliveries("zentao_candidates")) {
      const key = `${failed.meeting_id}:${failed.content_hash}`;
      if (existing.has(key)) continue;
      try {
        const packet = this.store.getMeetingPacket(failed.meeting_id, {
          requireDone: false,
        });
        const meeting = packet.meeting;
        const isCurrentCompletedVersion =
          meeting.status === "done" &&
          meeting.is_archived &&
          meeting.handoff_status === "completed" &&
          meeting.handoff_content_hash === failed.content_hash;
        const isCurrentProcessingVersion =
          meeting.status === "done" &&
          !meeting.is_archived &&
          meeting.handoff_status === "processing" &&
          meeting.handoff_content_hash === failed.content_hash;
        if (!isCurrentCompletedVersion && !isCurrentProcessingVersion) {
          continue;
        }
        meetings.push({
          meeting_id: meeting.meeting_id,
          title: meeting.title,
          ended_at: meeting.ended_at,
          segment_count: packet.segments.length,
          content_hash: packet.content_hash,
          handoff_status: meeting.handoff_status,
          attention_type: "delivery_retry",
          pending_destinations: ["zentao_candidates"],
        });
        existing.add(key);
      } catch {}
    }
    meetings.sort(
      (left, right) =>
        (left.ended_at ?? 0) - (right.ended_at ?? 0) ||
        left.meeting_id.localeCompare(right.meeting_id, "en"),
    );
    return {
      meetings: meetings.slice(0, this.config.maxPendingMeetings),
    };
  }

  getMeetingPacket(meetingId) {
    const packet = this.store.getMeetingPacket(meetingId, { requireDone: false });
    const meeting = packet.meeting;
    const normalPending = meeting.status === "done" && !meeting.is_archived;
    const retryingArchivedCandidate =
      meeting.status === "done" &&
      meeting.is_archived &&
      meeting.handoff_status === "completed" &&
      Boolean(meeting.handoff_content_hash) &&
      this.ledger.hasFailed(meetingId, meeting.handoff_content_hash, "zentao_candidates");
    if (!normalPending && !retryingArchivedCandidate) {
      throw new Error(`会议不是可读取的交接版本：${meetingId}`);
    }
    return retryingArchivedCandidate
      ? { ...packet, content_hash: meeting.handoff_content_hash }
      : packet;
  }

  beginHandoff(meetingId, contentHash) {
    const result = this.store.beginHandoff(meetingId, contentHash);
    return {
      meeting_id: meetingId,
      content_hash: contentHash,
      state: result.state,
      pending_destinations: this.ledger.pendingDestinations(meetingId, contentHash),
    };
  }

  async recordDelivery(input) {
    const { meeting_id: meetingId, content_hash: contentHash, destination, status } = input;
    const packet = this.store.getMeetingPacket(meetingId, {
      requireDone: !["failure_notice", "zentao_candidates"].includes(destination),
    });
    const archivedCurrentVersion =
      destination === "zentao_candidates" &&
      packet.meeting.status === "done" &&
      packet.meeting.is_archived &&
      packet.meeting.handoff_status === "completed" &&
      packet.meeting.handoff_content_hash === contentHash;
    if (packet.content_hash !== contentHash && !archivedCurrentVersion) {
      throw new Error("会议内容已变化，拒绝记录旧版本交付结果");
    }
    if (destination === "failure_notice" && packet.meeting.status !== "failed") {
      throw new Error("failure_notice 只用于录音失败会议");
    }
    if (destination !== "failure_notice") {
      const processingCurrentVersion =
        packet.meeting.status === "done" &&
        !packet.meeting.is_archived &&
        packet.meeting.handoff_status === "processing" &&
        packet.meeting.handoff_content_hash === contentHash;
      const completedCurrentVersion =
        destination === "zentao_candidates" &&
        packet.meeting.status === "done" &&
        packet.meeting.is_archived &&
        packet.meeting.handoff_status === "completed" &&
        packet.meeting.handoff_content_hash === contentHash;
      if (!processingCurrentVersion && !completedCurrentVersion) {
        throw new Error("会议版本尚未 begin_handoff，或交接状态已变化");
      }
    }
    if (status === "failed") {
      if (!input.error) throw new Error("失败交付必须提供 error");
      this.ledger.recordFailure(meetingId, contentHash, destination, input.error);
      if (["codex", "obsidian"].includes(destination)) {
        this.store.markHandoffFailed(meetingId, contentHash, input.error);
      }
      return this.ledger.getStatus(meetingId, contentHash);
    }

    try {
      if (destination === "codex") {
        this.ledger.saveSummary(
          meetingId,
          contentHash,
          validateDetailedMinutes(input.summary),
        );
      } else if (destination === "obsidian") {
        const summary = this.ledger.getArtifact(meetingId, contentHash, "codex_summary");
        if (!summary?.content) throw new Error("缺少已持久化的 Codex 摘要");
        const candidates = this.ledger.listCandidates(meetingId, contentHash);
        const files = await this.writer.writeMeeting(
          packet,
          contentHash,
          summary.content,
          candidates,
        );
        this.ledger.saveFileArtifacts(meetingId, contentHash, files.source, files.draft);
      } else if (destination === "zentao_candidates") {
        const draft = this.ledger.getArtifact(meetingId, contentHash, "obsidian_draft");
        if (!draft?.path) throw new Error("缺少已写入的 Obsidian 草稿");
        const candidates = this.ledger.saveCandidates(
          meetingId,
          contentHash,
          input.candidates ?? [],
          draft.path,
        );
        const updated = await this.writer.updateZentaoBlock(
          draft.path,
          meetingId,
          contentHash,
          candidates,
        );
        this.ledger.updateDraftArtifact(meetingId, contentHash, updated);
        this.ledger.recordSuccess(meetingId, contentHash, destination, {
          candidate_ids: candidates.map((candidate) => candidate.candidate_id),
        });
      } else if (destination === "failure_notice") {
        const claimed = this.ledger.claimFailureNotice(meetingId, contentHash);
        return {
          ...this.ledger.getStatus(meetingId, contentHash),
          failure_notice_claimed: claimed,
        };
      } else {
        throw new Error(`不支持的交付目的地：${destination}`);
      }
      return this.ledger.getStatus(meetingId, contentHash);
    } catch (error) {
      this.ledger.recordFailure(meetingId, contentHash, destination, error.message);
      if (["codex", "obsidian"].includes(destination)) {
        this.store.markHandoffFailed(meetingId, contentHash, error.message);
      }
      throw error;
    }
  }

  async completeHandoff(meetingId, contentHash) {
    void meetingId;
    void contentHash;
    throw new Error("不能直接归档会议；必须通过 confirm_handoff 保存人工确认后归档");
  }

  async prepareHandoffReview(meetingId, contentHash) {
    if (!this.ledger.hasSucceeded(meetingId, contentHash, "codex")) {
      throw new Error("Codex 摘要尚未成功持久化");
    }
    if (!this.ledger.hasSucceeded(meetingId, contentHash, "obsidian")) {
      throw new Error("Obsidian 原始转写和 AI 草稿尚未全部写入");
    }
    const source = this.ledger.getArtifact(meetingId, contentHash, "obsidian_source");
    const draft = this.ledger.getArtifact(meetingId, contentHash, "obsidian_draft");
    if (!source?.path || !draft?.path) throw new Error("Obsidian 文件账本不完整");
    const summary = this.ledger.getArtifact(meetingId, contentHash, "codex_summary");
    validateDetailedMinutes(summary?.content);
    await this.writer.verifyArtifacts(
      meetingId,
      contentHash,
      source.path,
      draft.path,
    );
    const result = this.store.prepareHandoffReview(meetingId, contentHash);
    this.ledger.ensureReview(meetingId, contentHash);
    const notificationSent = result.state === "review_ready" ? this.notifier() : false;
    return {
      meeting_id: meetingId,
      content_hash: contentHash,
      state: result.state,
      review_required: true,
      archived: false,
      notification_sent: notificationSent,
      review: this.ledger.getReview(meetingId, contentHash),
      ...this.ledger.getStatus(meetingId, contentHash),
    };
  }

  async #archiveHandoff(meetingId, contentHash) {
    const source = this.ledger.getArtifact(meetingId, contentHash, "obsidian_source");
    const draft = this.ledger.getArtifact(meetingId, contentHash, "obsidian_draft");
    if (!source?.path || !draft?.path) throw new Error("Obsidian 文件账本不完整");
    await this.writer.verifyArtifacts(meetingId, contentHash, source.path, draft.path);
    const result = this.store.completeHandoff(meetingId, contentHash);
    const notificationSent = result.state === "completed" ? this.notifier() : false;
    return {
      meeting_id: meetingId,
      content_hash: contentHash,
      state: result.state,
      notification_sent: notificationSent,
      archived: result.state === "completed" || result.state === "already_completed",
      review: this.ledger.getReview(meetingId, contentHash),
    };
  }

  async #applyConfirmedTitle(meetingId, contentHash, title) {
    const normalizedTitle = String(title ?? "").normalize("NFC").trim();
    if (!normalizedTitle) return null;
    if (/\r|\n|\0/.test(normalizedTitle)) {
      throw new Error("会议标题不能包含换行或空字符");
    }
    const packet = this.store.getMeetingPacket(meetingId, { requireDone: false });
    if (packet.meeting.title === normalizedTitle) {
      return { title: normalizedTitle, state: "already_updated" };
    }
    if (
      packet.meeting.status !== "done" ||
      packet.meeting.handoff_status !== "completed" ||
      packet.meeting.handoff_content_hash !== contentHash
    ) {
      throw new Error("会议不是可修订标题的已完成交接版本");
    }
    const summary = this.ledger.getArtifact(meetingId, contentHash, "codex_summary");
    const source = this.ledger.getArtifact(meetingId, contentHash, "obsidian_source");
    const draft = this.ledger.getArtifact(meetingId, contentHash, "obsidian_draft");
    if (!summary?.content || !source?.path || !draft?.path) {
      throw new Error("会议标题修订所需的交接产物不完整");
    }
    const updatedSummary = applyConfirmedMeetingTitle(summary.content, normalizedTitle);
    const relabeled = await this.writer.relabelMeeting({
      packet,
      contentHash,
      sourcePath: source.path,
      draftPath: draft.path,
      title: normalizedTitle,
    });
    this.ledger.updateSummaryArtifact(meetingId, contentHash, updatedSummary);
    this.ledger.saveFileArtifacts(
      meetingId,
      contentHash,
      relabeled.source,
      relabeled.draft,
    );
    this.ledger.updateCandidateObsidianPath(meetingId, contentHash, relabeled.draft.path);
    const updated = this.store.updateCompletedMeetingTitle(
      meetingId,
      contentHash,
      normalizedTitle,
    );
    const retainedSupersededPaths = await this.writer.removeSupersededArtifacts(
      relabeled.superseded,
      meetingId,
      contentHash,
    );
    return {
      ...updated,
      title: normalizedTitle,
      source_path: relabeled.source.path,
      draft_path: relabeled.draft.path,
      retained_superseded_paths: retainedSupersededPaths,
      notification_sent: this.notifier(),
    };
  }

  async confirmHandoff(input) {
    const {
      meeting_id: meetingId,
      content_hash: contentHash,
      attendees,
      context: inputContext,
      meeting_context: meetingContext,
      corrections = "",
      confirmed,
    } = input;
    if (!Array.isArray(attendees)) throw new Error("人工确认必须明确提供 attendees 数组");
    if (confirmed !== true && confirmed !== false) {
      throw new Error("confirmed 必须明确为 true 或 false");
    }
    const context = inputContext ?? meetingContext;
    if (!context || typeof context !== "object" || Array.isArray(context)) {
      throw new Error("人工确认必须明确提供 context 对象");
    }
    const packet = this.store.getMeetingPacket(meetingId, { requireDone: false });
    const archivedCurrentVersion =
      packet.meeting.status === "done" &&
      packet.meeting.is_archived &&
      packet.meeting.handoff_status === "completed" &&
      packet.meeting.handoff_content_hash === contentHash;
    if (packet.content_hash !== contentHash && !archivedCurrentVersion) {
      throw new Error("会议内容已变化，请按新 content_hash 重新处理");
    }
    if (archivedCurrentVersion) {
      const review = this.ledger.saveReviewConfirmation(meetingId, contentHash, {
        attendees,
        context,
        corrections,
        confirmed,
      });
      const titleUpdate = confirmed
        ? await this.#applyConfirmedTitle(meetingId, contentHash, review.context?.title)
        : null;
      return {
        meeting_id: meetingId,
        content_hash: contentHash,
        state: "already_completed",
        archived: true,
        title_update: titleUpdate,
        review: this.ledger.getReview(meetingId, contentHash),
      };
    }
    if (
      packet.meeting.status !== "done" ||
      packet.meeting.is_archived ||
      packet.meeting.handoff_status !== "completed" ||
      packet.meeting.handoff_content_hash !== contentHash
    ) {
      throw new Error("会议尚未进入待人工确认状态");
    }
    const source = this.ledger.getArtifact(meetingId, contentHash, "obsidian_source");
    const draft = this.ledger.getArtifact(meetingId, contentHash, "obsidian_draft");
    if (!source?.path || !draft?.path) throw new Error("Obsidian 文件账本不完整");
    const review = this.ledger.saveReviewConfirmation(meetingId, contentHash, {
      attendees,
      context,
      corrections,
      confirmed,
    });
    const updatedDraft = await this.writer.updateReviewBlock(
      draft.path,
      meetingId,
      contentHash,
      review,
    );
    this.ledger.updateDraftArtifact(meetingId, contentHash, updatedDraft);
    if (!confirmed) {
      return {
        meeting_id: meetingId,
        content_hash: contentHash,
        state: "review_changes_requested",
        archived: false,
        review: this.ledger.getReview(meetingId, contentHash),
      };
    }
    const archived = await this.#archiveHandoff(meetingId, contentHash);
    const titleUpdate = await this.#applyConfirmedTitle(
      meetingId,
      contentHash,
      review.context?.title,
    );
    return {
      ...archived,
      title_update: titleUpdate,
      review: this.ledger.getReview(meetingId, contentHash),
    };
  }

  getDeliveryStatus(meetingId, contentHash) {
    return this.ledger.getStatus(meetingId, contentHash);
  }
}

const candidateSchema = z.object({
  title: z.string().min(1),
  description: z.string().optional(),
  evidence: z.string().min(1),
  assignee: z.string().optional(),
  due_date: z.string().optional(),
  status: z.enum(["awaiting_approval", "creating", "created", "skipped"]).optional(),
  zentao_task_id: z.string().optional(),
  zentao_url: z.string().url().optional(),
});

const attendeeSchema = z.object({
  name: z.string().min(1),
  role: z.string().optional(),
});

const reviewContextSchema = z.record(z.string());

function register(server, name, config, callback, formatResult = null) {
  server.registerTool(name, config, async (input) => {
    try {
      const value = await callback(input);
      return formatResult ? formatResult(value, input) : toolResult(value);
    } catch (error) {
      return errorResult(error);
    }
  });
}

export function createMcpServer(service) {
  const server = new McpServer(
    { name: "agendai-codex-mcp", version: "0.1.0" },
    {
      instructions:
        "先调用 list_pending_meetings。正常会议每轮最多处理一场：依次 begin、读取 packet、生成包含八个必需章节的详细中文会议纪要、记录 codex 摘要、obsidian 和禅道候选，摘要与 Obsidian 成功后调用 prepare_handoff_review。prepare 后会议保持 completed 且未归档，attention_type=human_review 的会议只能向用户展示并请求确认，不能重复生成或归档；只有用户明确提供 attendees、context、corrections 并确认后才调用 confirm_handoff。录音失败会议只记录一次 failure_notice。不要使用 shell 或直接 SQL，不要猜测负责人或截止日期，不要自动创建禅道任务。",
    },
  );

  register(
    server,
    "list_pending_meetings",
    {
      description: "列出最多十场待交接或需一次性提醒的会小纪会议",
      inputSchema: {},
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    () => service.listPendingMeetings(),
  );
  register(
    server,
    "get_meeting_packet",
    {
      description: "以单份紧凑文本读取规范化最终转写，不返回音频、模型配置或重复结构",
      inputSchema: { meeting_id: z.string().min(1) },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    ({ meeting_id }) => service.getMeetingPacket(meeting_id),
    (packet) => textOnlyResult(compactMeetingPacketText(packet)),
  );
  register(
    server,
    "begin_handoff",
    {
      description: "以内容哈希 CAS 开始或接管一场会议交接",
      inputSchema: {
        meeting_id: z.string().min(1),
        content_hash: z.string().regex(/^[a-f0-9]{64}$/),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    ({ meeting_id, content_hash }) => service.beginHandoff(meeting_id, content_hash),
  );
  register(
    server,
    "record_delivery",
    {
      description: "记录目的地成功或失败；Obsidian 只能写入固定会议目录",
      inputSchema: {
        meeting_id: z.string().min(1),
        content_hash: z.string().regex(/^[a-f0-9]{64}$/),
        destination: z.enum([
          "codex",
          "obsidian",
          "zentao_candidates",
          "failure_notice",
        ]),
        status: z.enum(["succeeded", "failed"]),
        summary: z.string().optional(),
        candidates: z.array(candidateSchema).optional(),
        error: z.string().optional(),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    (input) => service.recordDelivery(input),
    (status) => toolResult(compactStatus(status)),
  );
  register(
    server,
    "complete_handoff",
    {
      description: "兼容旧客户端的归档入口；没有人工确认时拒绝归档",
      inputSchema: {
        meeting_id: z.string().min(1),
        content_hash: z.string().regex(/^[a-f0-9]{64}$/),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    ({ meeting_id, content_hash }) => service.completeHandoff(meeting_id, content_hash),
  );
  register(
    server,
    "prepare_handoff_review",
    {
      description: "校验详细会议纪要并进入待人工确认状态；不会归档会议",
      inputSchema: {
        meeting_id: z.string().min(1),
        content_hash: z.string().regex(/^[a-f0-9]{64}$/),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    ({ meeting_id, content_hash }) =>
      service.prepareHandoffReview(meeting_id, content_hash),
    (status) => toolResult(compactStatus(status)),
  );
  register(
    server,
    "confirm_handoff",
    {
      description: "保存用户确认的参会人员、会议背景和修订意见；确认后才归档",
      inputSchema: {
        meeting_id: z.string().min(1),
        content_hash: z.string().regex(/^[a-f0-9]{64}$/),
        attendees: z.array(attendeeSchema),
        context: reviewContextSchema.optional(),
        meeting_context: reviewContextSchema.optional(),
        corrections: z.union([z.string(), z.array(z.string())]).optional(),
        confirmed: z.boolean(),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    (input) => service.confirmHandoff(input),
    (status) => toolResult(compactStatus(status)),
  );
  register(
    server,
    "get_delivery_status",
    {
      description: "紧凑查询目的地状态和禅道候选；仅 include_summary=true 时返回完整纪要",
      inputSchema: {
        meeting_id: z.string().min(1),
        content_hash: z.string().regex(/^[a-f0-9]{64}$/),
        include_summary: z.boolean().optional(),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    ({ meeting_id, content_hash }) => service.getDeliveryStatus(meeting_id, content_hash),
    (status, input) =>
      toolResult(compactStatus(status, { includeSummary: input.include_summary === true })),
  );
  return server;
}
