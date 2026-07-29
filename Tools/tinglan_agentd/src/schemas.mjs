import path from "node:path";
import { z } from "zod";

const MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER;
const TRIMMED_NONEMPTY_PATTERN = /^\S(?:[\s\S]*\S)?$/;
const TRIMMED_OPTIONAL_PATTERN = /^(?:|\S(?:[\s\S]*\S)?)$/;
const ABSOLUTE_POSIX_PATH_PATTERN = /^\/[^\0]*$/;
const RELATIVE_RESULT_PATH_PATTERN = /^(?!\/)(?![A-Za-z]:\/)(?!.*(?:^|\/)\.\.?(?:\/|$))(?!.*\/\/)(?!.*\\)[^\0/]+(?:\/[^\0/]+)*$/;

export const MAX_RESULT_ASSETS = 100;
export const MAX_REPORT_BYTES = 20 * 1024 * 1024;
export const MAX_TODOS_BYTES = 5 * 1024 * 1024;
export const MAX_RESULT_ASSET_BYTES = 50 * 1024 * 1024;
export const MAX_RESULT_PACKAGE_BYTES = 200 * 1024 * 1024;

const protocolVersionSchema = z.literal("1.0", {
  errorMap: () => ({ message: "协议版本必须为 1.0" }),
});

const trimmedString = (label, { allowEmpty = false, max = 1_000_000 } = {}) => z.string()
  .max(max, `${label}过长`)
  .regex(allowEmpty ? TRIMMED_OPTIONAL_PATTERN : TRIMMED_NONEMPTY_PATTERN, `${label}必须预先移除首尾空白`);
const nonEmptyId = (label) => trimmedString(label, { max: 200 });
const safeComponentId = (label) => z.string().regex(
  /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/,
  `${label}必须是安全的单一路径组件`,
);
const jobIdSchema = safeComponentId("作业 ID");
const sha256Schema = z.string().regex(/^[a-f0-9]{64}$/, "SHA-256 必须是 64 位小写十六进制");
const isoDateSchema = z.string().datetime({ offset: true, message: "时间必须是 ISO 8601 格式" });
const statusSchema = z.enum(["queued", "running", "succeeded", "failed", "cancelled"]);

function isSafeRelativeResultPath(value) {
  if (typeof value !== "string" || value.length === 0 || value === "." || value === "..") return false;
  if (value.includes("\\") || value.includes("\0") || path.posix.isAbsolute(value) || path.win32.isAbsolute(value)) return false;
  const parts = value.split("/");
  if (parts.some((part) => part.length === 0 || part === "." || part === "..")) return false;
  return path.posix.normalize(value) === value;
}

export const relativeResultPathSchema = z.string()
  .regex(RELATIVE_RESULT_PATH_PATTERN, "结果文件必须使用规范相对路径")
  .refine(isSafeRelativeResultPath, "结果文件必须使用规范相对路径");

const participantSchema = z.object({
  name: trimmedString("参会人姓名", { max: 500 }),
  role: trimmedString("参会人角色", { max: 500 }).optional(),
  speaker: trimmedString("参会人说话人", { max: 500 }).optional(),
}).strict();

const transcriptSegmentSchema = z.object({
  id: nonEmptyId("片段 ID"),
  start_ms: z.number().int().nonnegative("片段开始时间不能为负数").max(MAX_SAFE_INTEGER, "片段开始时间超过安全整数范围"),
  end_ms: z.number().int().nonnegative("片段结束时间不能为负数").max(MAX_SAFE_INTEGER, "片段结束时间超过安全整数范围"),
  speaker: trimmedString("片段说话人", { allowEmpty: true, max: 10_000 }),
  text: trimmedString("片段文本", { allowEmpty: true, max: 1_000_000 }),
}).strict().superRefine((segment, context) => {
  if (segment.end_ms < segment.start_ms) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["end_ms"],
      message: "片段结束时间不能早于开始时间",
    });
  }
}).describe("结构 Schema 校验非负安全整数；end_ms >= start_ms 由 runtime Zod 跨字段门禁。");

const attachmentSchema = z.object({
  id: nonEmptyId("附件 ID"),
  file_name: trimmedString("附件文件名", { max: 255 }),
  media_type: trimmedString("附件媒体类型", { max: 255 }),
  size_bytes: z.number().int().nonnegative("附件大小不能为负数").max(100 * 1024 * 1024, "单个附件不能超过 100 MiB"),
  sha256: sha256Schema,
  source_path: z.string().regex(ABSOLUTE_POSIX_PATH_PATTERN, "附件 source_path 必须是绝对路径"),
}).strict();

export const jobRequestSchema = z.object({
  schema_version: protocolVersionSchema,
  request_id: jobIdSchema,
  meeting: z.object({
    id: safeComponentId("会议 ID"),
    title: trimmedString("会议标题", { allowEmpty: true, max: 10_000 }),
    started_at: isoDateSchema,
    ended_at: isoDateSchema,
    timezone: trimmedString("时区", { max: 200 }),
    capture_source: trimmedString("采集来源", { max: 200 }),
    participants: z.array(participantSchema).max(500),
  }).strict().superRefine((meeting, context) => {
    if (Date.parse(meeting.ended_at) < Date.parse(meeting.started_at)) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["ended_at"], message: "会议结束时间不能早于开始时间" });
    }
  }).describe("结构 Schema 校验 ISO 时间；ended_at >= started_at 由 runtime Zod 跨字段门禁。"),
  transcript: z.object({
    language: trimmedString("转写语言", { max: 100 }),
    plain_text: trimmedString("完整转写", { allowEmpty: true, max: 20 * 1024 * 1024 }),
    segments: z.array(transcriptSegmentSchema).max(200_000),
  }).strict(),
  attachments: z.array(attachmentSchema).max(20, "附件最多 20 个").superRefine((attachments, context) => {
    const total = attachments.reduce((sum, attachment) => sum + attachment.size_bytes, 0);
    if (total > 500 * 1024 * 1024) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: "附件总大小不能超过 500 MiB" });
    }
  }).describe("最多 20 个附件、单附件 100 MiB；总附件 <= 500 MiB 由 runtime Zod 跨字段门禁。"),
  analysis: z.object({
    goal: trimmedString("分析目标", { allowEmpty: true, max: 1_000_000 }),
    language: trimmedString("分析语言", { max: 100 }),
  }).strict(),
  output: z.object({
    report_format: z.literal("html"),
    todos_format: z.literal("json"),
    locale: trimmedString("输出 locale", { max: 100 }),
  }).strict(),
}).strict();

export const submitResponseSchema = z.object({
  schema_version: protocolVersionSchema,
  job_id: jobIdSchema,
  request_id: jobIdSchema,
  status: statusSchema,
}).strict();

const jobErrorSchema = z.object({
  code: trimmedString("错误码", { max: 200 }),
  message: z.string().max(2000),
}).strict();

export const jobStatusSchema = z.object({
  schema_version: protocolVersionSchema,
  job_id: jobIdSchema,
  request_id: jobIdSchema,
  meeting_id: safeComponentId("会议 ID"),
  provider: trimmedString("Provider", { max: 200 }),
  status: statusSchema,
  created_at: isoDateSchema,
  updated_at: isoDateSchema,
  started_at: isoDateSchema.nullable(),
  completed_at: isoDateSchema.nullable(),
  error: jobErrorSchema.nullable(),
}).strict();

const providerSchema = z.object({
  name: trimmedString("Provider 名称", { max: 200 }),
  run_id: trimmedString("Provider run_id", { max: 500 }),
}).strict();

export const resultResponseSchema = z.object({
  schema_version: protocolVersionSchema,
  job_id: jobIdSchema,
  request_id: jobIdSchema,
  meeting_id: safeComponentId("会议 ID"),
  request_hash: sha256Schema,
  provider: providerSchema,
  result_path: z.string().regex(ABSOLUTE_POSIX_PATH_PATTERN, "result_path 必须是绝对路径"),
  manifest_path: relativeResultPathSchema,
  manifest_sha256: sha256Schema,
}).strict();

export const errorResponseSchema = z.object({
  error: z.object({
    code: trimmedString("错误码", { max: 200 }),
    message: z.string().max(2000),
    details: z.array(z.unknown()),
  }).strict(),
}).strict();

const fileDescriptorSchema = z.object({
  path: relativeResultPathSchema,
  size_bytes: z.number().int().nonnegative().max(MAX_SAFE_INTEGER),
  sha256: sha256Schema,
}).strict();

const assetDescriptorSchema = fileDescriptorSchema.extend({
  size_bytes: z.number().int().nonnegative().max(MAX_RESULT_ASSET_BYTES, "单个结果资源超过 50 MiB 上限"),
  media_type: trimmedString("资源媒体类型", { max: 255 }),
}).strict();

export const resultManifestSchema = z.object({
  schema_version: protocolVersionSchema,
  job_id: jobIdSchema,
  request_id: jobIdSchema,
  request_hash: sha256Schema,
  meeting_id: safeComponentId("会议 ID"),
  provider: providerSchema,
  generated_at: isoDateSchema,
  report: fileDescriptorSchema.extend({
    path: z.literal("report.html"),
    size_bytes: z.number().int().nonnegative().max(MAX_REPORT_BYTES, "report.html 超过 20 MiB 上限"),
  }).strict(),
  todos: fileDescriptorSchema.extend({
    path: z.literal("todos.json"),
    size_bytes: z.number().int().nonnegative().max(MAX_TODOS_BYTES, "todos.json 超过 5 MiB 上限"),
    count: z.number().int().nonnegative().max(MAX_SAFE_INTEGER),
  }).strict(),
  assets: z.array(assetDescriptorSchema).max(MAX_RESULT_ASSETS, "结果资源最多 100 个"),
  skills_used: z.array(trimmedString("Skill 名称", { max: 500 })),
  warnings: z.array(z.string().max(2000)),
}).strict().superRefine((manifest, context) => {
  const total = manifest.report.size_bytes + manifest.todos.size_bytes
    + manifest.assets.reduce((sum, asset) => sum + asset.size_bytes, 0);
  if (total > MAX_RESULT_PACKAGE_BYTES) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "结果包总量超过 200 MiB 上限" });
  }
}).describe("结构 Schema 固定 report.html/todos.json 并限制文件数量和单文件大小；report、todos、assets 声明总量 <= 200 MiB 由 runtime Zod 跨字段门禁，manifest.json 自身实际字节由结果包 runtime 校验计入 200 MiB 总量。");

const evidenceSchema = z.object({
  segment_id: nonEmptyId("证据片段 ID"),
  quote: trimmedString("证据原文", { max: 100_000 }),
  time_range: trimmedString("证据时间范围", { max: 200 }),
}).strict();

const todoItemSchema = z.object({
  id: nonEmptyId("待办 ID"),
  title: trimmedString("待办标题", { max: 10_000 }),
  description: trimmedString("待办描述", { allowEmpty: true, max: 100_000 }),
  owner: trimmedString("待办负责人", { max: 1000 }).nullable(),
  deadline: trimmedString("待办期限", { max: 1000 }).nullable(),
  deliverable: trimmedString("待办交付物", { allowEmpty: true, max: 100_000 }).nullable(),
  acceptance_criteria: trimmedString("待办验收标准", { allowEmpty: true, max: 100_000 }).nullable(),
  evidence: z.array(evidenceSchema),
  confirmation_status: z.literal("pending_confirmation", {
    errorMap: () => ({ message: "待办首次输出必须为 pending_confirmation（待确认）" }),
  }),
  proposed_workflow: z.enum(["none", "zentao"]),
}).strict().superRefine((item, context) => {
  if (item.owner !== null && item.evidence.length === 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["owner"], message: "非空负责人必须提供负责人证据" });
  }
  if (item.deadline !== null && item.evidence.length === 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["deadline"], message: "非空期限必须提供会议证据" });
  }
}).describe("owner/deadline 非空时 evidence 必须非空，此规则由 runtime Zod 跨字段门禁。");

export const todosSchema = z.object({
  schema_version: protocolVersionSchema,
  job_id: jobIdSchema,
  meeting_id: safeComponentId("会议 ID"),
  items: z.array(todoItemSchema),
}).strict();

export const schemaDefinitions = Object.freeze({
  "job-request.schema.json": jobRequestSchema,
  "submit-response.schema.json": submitResponseSchema,
  "job-status.schema.json": jobStatusSchema,
  "result-response.schema.json": resultResponseSchema,
  "error-response.schema.json": errorResponseSchema,
  "result-manifest.schema.json": resultManifestSchema,
  "todos.schema.json": todosSchema,
});

function parse(schema, value) {
  const result = schema.safeParse(value);
  if (result.success) return result.data;
  const message = result.error.issues.map((issue) => `${issue.path.join(".") || "root"}: ${issue.message}`).join("; ");
  throw new Error(message);
}

export const validateJobRequest = (value) => parse(jobRequestSchema, value);
export const validateSubmitResponse = (value) => parse(submitResponseSchema, value);
export const validateJobStatus = (value) => parse(jobStatusSchema, value);
export const validateResultResponse = (value) => parse(resultResponseSchema, value);
export const validateErrorResponse = (value) => parse(errorResponseSchema, value);
export const validateResultManifest = (value) => parse(resultManifestSchema, value);
export const validateTodos = (value) => parse(todosSchema, value);

export function validateRelativeResultPath(value) {
  return parse(relativeResultPathSchema, value);
}
