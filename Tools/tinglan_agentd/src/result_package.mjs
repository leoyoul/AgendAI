import { randomBytes } from "node:crypto";
import { copyFile, lstat, mkdir, open, readFile, realpath, readdir, rename, rm } from "node:fs/promises";
import path from "node:path";
import { parse } from "parse5";

import { AgentError } from "./errors.mjs";
import { sha256File } from "./hash.mjs";
import {
  MAX_REPORT_BYTES,
  MAX_RESULT_ASSETS,
  MAX_RESULT_ASSET_BYTES,
  MAX_RESULT_PACKAGE_BYTES,
  MAX_TODOS_BYTES,
  validateRelativeResultPath,
  validateResultManifest,
  validateTodos,
} from "./schemas.mjs";

async function fsyncPath(targetPath) {
  const handle = await open(targetPath, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function writeDurably(filePath, contents) {
  await mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const handle = await open(filePath, "wx", 0o600);
  try {
    await handle.writeFile(contents);
    await handle.sync();
  } finally {
    await handle.close();
  }
}

const FORBIDDEN_TAGS = new Set(["base", "script", "iframe", "object", "embed", "form", "link"]);
const RESOURCE_ATTRIBUTES = new Map([
  ["img", ["src", "srcset"]],
  ["source", ["src", "srcset"]],
  ["video", ["src", "poster"]],
  ["audio", ["src"]],
  ["track", ["src"]],
  ["image", ["href", "xlink:href"]],
  ["use", ["href", "xlink:href"]],
]);

function normalizedCss(css) {
  return css
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\\([0-9a-f]{1,6})\s?/gi, (_match, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/\\(.)/gs, "$1");
}

function validateCss(css) {
  if (/(?:url\s*\(|@import\b)/i.test(normalizedCss(css))) {
    throw new AgentError("RESULT_INVALID", "首期 report.html 禁止 CSS 外部资源 url() 或 @import", { status: 500 });
  }
}

function nodeText(node) {
  if (node.nodeName === "#text") return node.value ?? "";
  return (node.childNodes ?? []).map(nodeText).join("");
}

function attrKey(attribute) {
  return attribute.prefix ? `${attribute.prefix}:${attribute.name}` : attribute.name;
}

function srcsetReferences(value) {
  if (/^\s*data:/i.test(value)) return [value.trim()];
  return value.split(",").map((candidate) => candidate.trim().split(/\s+/)[0]).filter(Boolean);
}

function validateResourceReference(reference, declaredAssets) {
  if (/^(?:https?:|data:|file:|\/\/)/i.test(reference) || path.isAbsolute(reference)) {
    throw new AgentError("RESULT_INVALID", `媒体资源必须使用包内相对路径：${reference}`, { status: 500 });
  }
  let safePath;
  try {
    safePath = validateRelativeResultPath(reference);
  } catch (cause) {
    throw new AgentError("RESULT_INVALID", `媒体资源路径无效：${reference}`, { status: 500, cause });
  }
  if (!declaredAssets.has(safePath)) {
    throw new AgentError("RESULT_INVALID", `媒体资源未在 manifest 声明：${safePath}`, { status: 500 });
  }
}

function walkReportNode(node, declaredAssets) {
  const tagName = node.tagName?.toLowerCase();
  if (tagName) {
    if (FORBIDDEN_TAGS.has(tagName)) {
      throw new AgentError("RESULT_INVALID", `report.html 禁止 ${tagName} 标签`, { status: 500 });
    }
    const attributes = new Map((node.attrs ?? []).map((attribute) => [attrKey(attribute).toLowerCase(), attribute.value]));
    for (const [name, value] of attributes) {
      if (name.startsWith("on")) throw new AgentError("RESULT_INVALID", `report.html 禁止事件属性 ${name}`, { status: 500 });
      if (name === "style") validateCss(value);
    }
    if (tagName === "style") validateCss(nodeText(node));
    for (const attributeName of RESOURCE_ATTRIBUTES.get(tagName) ?? []) {
      const value = attributes.get(attributeName);
      if (value === undefined || value.trim() === "") continue;
      const references = attributeName === "srcset" ? srcsetReferences(value) : [value.trim()];
      for (const reference of references) validateResourceReference(reference, declaredAssets);
    }
  }
  for (const child of node.childNodes ?? []) walkReportNode(child, declaredAssets);
  if (node.content) walkReportNode(node.content, declaredAssets);
}

export function validateReportHTML(html, declaredAssets) {
  const document = parse(html);
  const hasDoctype = document.childNodes.some((node) => node.nodeName === "#documentType" && node.name?.toLowerCase() === "html");
  const htmlNode = document.childNodes.find((node) => node.tagName === "html");
  const bodyNode = htmlNode?.childNodes?.find((node) => node.tagName === "body");
  if (!hasDoctype || !htmlNode || !bodyNode) {
    throw new AgentError("RESULT_INVALID", "report.html 不是完整 HTML 文档", { status: 500 });
  }
  walkReportNode(document, declaredAssets);
}

async function fileDescriptor(root, relativePath) {
  const absolutePath = path.join(root, validateRelativeResultPath(relativePath));
  const info = await lstat(absolutePath);
  if (!info.isFile() || info.isSymbolicLink()) throw new AgentError("RESULT_INVALID", `${relativePath} 必须是普通文件且不能是符号链接`, { status: 500 });
  return { path: relativePath, size_bytes: info.size, sha256: await sha256File(absolutePath) };
}

async function copyAsset(stagePath, asset) {
  const relativePath = validateRelativeResultPath(asset.path);
  if (!relativePath.startsWith("assets/")) throw new AgentError("RESULT_INVALID", "结果图片必须位于 assets/", { status: 500 });
  const sourcePath = asset.sourcePath ?? asset.source_path;
  const sourceInfo = await lstat(sourcePath);
  if (!sourceInfo.isFile() || sourceInfo.isSymbolicLink()) throw new AgentError("RESULT_INVALID", "结果资源源文件必须是普通文件", { status: 500 });
  const destinationPath = path.join(stagePath, relativePath);
  await mkdir(path.dirname(destinationPath), { recursive: true, mode: 0o700 });
  await copyFile(sourcePath, destinationPath);
  await fsyncPath(destinationPath);
  return { ...(await fileDescriptor(stagePath, relativePath)), media_type: asset.mediaType ?? asset.media_type };
}

async function ensureReusableOutput(outputPath, expectedManifestSha256, expectedJob) {
  try {
    await lstat(outputPath);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  try {
    const verified = await verifyResultPackage(outputPath, expectedJob);
    if (verified.manifestSha256 !== expectedManifestSha256) {
      throw new AgentError("RESULT_CONFLICT", "已有结果包与本次结果不一致", { status: 409 });
    }
    return verified;
  } catch (error) {
    if (error instanceof AgentError && error.code === "RESULT_CONFLICT") throw error;
    throw error;
  }
}

export function validateResultPackageLimits(manifest, manifestBytes = 0) {
  const assets = Array.isArray(manifest.assets) ? manifest.assets : [];
  if (assets.length > MAX_RESULT_ASSETS) throw new AgentError("RESULT_INVALID", "结果资源数量超过 100 个上限", { status: 500 });
  if (manifest.report?.size_bytes > MAX_REPORT_BYTES) throw new AgentError("RESULT_INVALID", "report.html 超过 20 MiB 上限", { status: 500 });
  if (manifest.todos?.size_bytes > MAX_TODOS_BYTES) throw new AgentError("RESULT_INVALID", "todos.json 超过 5 MiB 上限", { status: 500 });
  if (assets.some((asset) => asset.size_bytes > MAX_RESULT_ASSET_BYTES)) {
    throw new AgentError("RESULT_INVALID", "单个结果资源超过 50 MiB 上限", { status: 500 });
  }
  const total = (manifest.report?.size_bytes ?? 0) + (manifest.todos?.size_bytes ?? 0) + manifestBytes
    + assets.reduce((sum, asset) => sum + (asset.size_bytes ?? 0), 0);
  if (total > MAX_RESULT_PACKAGE_BYTES) throw new AgentError("RESULT_INVALID", "结果包总量超过 200 MiB 上限", { status: 500 });
  return total;
}

export async function publishResultPackage({
  jobRoot,
  request,
  requestHash,
  provider,
  generatedAt,
  reportHtml,
  todos,
  assets = [],
  skillsUsed = [],
  warnings = [],
}) {
  const stagingRoot = path.join(jobRoot, "staging");
  const stagePath = path.join(stagingRoot, `result-${process.pid}-${randomBytes(6).toString("hex")}`);
  const outputPath = path.join(jobRoot, "output");
  await mkdir(stagingRoot, { recursive: true, mode: 0o700 });
  await mkdir(stagePath, { mode: 0o700 });
  try {
    const validatedTodos = validateTodos(todos);
    if (validatedTodos.job_id !== request.request_id || validatedTodos.meeting_id !== request.meeting.id) {
      throw new AgentError("RESULT_INVALID", "todos 与当前作业或会议不匹配", { status: 500 });
    }
    await writeDurably(path.join(stagePath, "report.html"), reportHtml);
    await writeDurably(path.join(stagePath, "todos.json"), `${JSON.stringify(validatedTodos, null, 2)}\n`);
    const assetDescriptors = [];
    for (const asset of assets) assetDescriptors.push(await copyAsset(stagePath, asset));
    validateReportHTML(reportHtml, new Set(assetDescriptors.map((asset) => asset.path)));
    const manifest = validateResultManifest({
      schema_version: "1.0",
      job_id: request.request_id,
      request_id: request.request_id,
      request_hash: requestHash,
      meeting_id: request.meeting.id,
      provider,
      generated_at: generatedAt,
      report: await fileDescriptor(stagePath, "report.html"),
      todos: { ...(await fileDescriptor(stagePath, "todos.json")), count: validatedTodos.items.length },
      assets: assetDescriptors,
      skills_used: skillsUsed,
      warnings,
    });
    validateResultPackageLimits(manifest);
    await writeDurably(path.join(stagePath, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
    await fsyncPath(stagePath);
    const expectedJob = {
      job_id: request.request_id,
      request_hash: requestHash,
      meeting_id: request.meeting.id,
      provider: provider.name,
    };
    const staged = await verifyResultPackage(stagePath, expectedJob);
    const reusable = await ensureReusableOutput(outputPath, staged.manifestSha256, expectedJob);
    if (reusable) {
      return { outputPath, manifest: reusable.manifest, todos: reusable.todos, manifestSha256: reusable.manifestSha256, reused: true };
    }
    await rename(stagePath, outputPath);
    await fsyncPath(jobRoot);
    return { outputPath, manifest, todos: validatedTodos, manifestSha256: staged.manifestSha256, reused: false };
  } finally {
    await rm(stagePath, { recursive: true, force: true });
  }
}

async function verifyDeclaredFile(outputRealPath, descriptor) {
  const relativePath = validateRelativeResultPath(descriptor.path);
  const absolutePath = path.join(outputRealPath, relativePath);
  const info = await lstat(absolutePath);
  if (!info.isFile() || info.isSymbolicLink()) throw new AgentError("RESULT_INVALID", `${relativePath} 不是普通文件或是符号链接`, { status: 500 });
  const fileRealPath = await realpath(absolutePath);
  const relative = path.relative(outputRealPath, fileRealPath);
  if (relative === "" || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new AgentError("RESULT_INVALID", `${relativePath} 越出结果目录`, { status: 500 });
  }
  if (info.size !== descriptor.size_bytes) throw new AgentError("RESULT_INVALID", `${relativePath} 大小不匹配`, { status: 500 });
  if ((await sha256File(absolutePath)) !== descriptor.sha256) throw new AgentError("RESULT_INVALID", `${relativePath} 哈希不匹配`, { status: 500 });
}

async function verifyResultPackageImpl(outputPath, expectedJob) {
  const outputInfo = await lstat(outputPath);
  if (!outputInfo.isDirectory() || outputInfo.isSymbolicLink()) throw new AgentError("RESULT_INVALID", "结果包必须是普通目录且不能是符号链接", { status: 500 });
  const outputRealPath = await realpath(outputPath);
  const manifestPath = path.join(outputRealPath, "manifest.json");
  const manifestInfo = await lstat(manifestPath);
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink()) throw new AgentError("RESULT_INVALID", "manifest.json 不能是符号链接", { status: 500 });
  let manifestValue;
  try {
    manifestValue = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (cause) {
    throw new AgentError("RESULT_INVALID", "manifest.json 格式无效", { status: 500, cause });
  }
  const manifest = validateResultManifest(manifestValue);
  validateResultPackageLimits(manifest, manifestInfo.size);
  validateExpectedIdentity(manifest, expectedJob);
  for (const descriptor of [manifest.report, manifest.todos, ...manifest.assets]) {
    await verifyDeclaredFile(outputRealPath, descriptor);
  }
  let todosValue;
  try {
    todosValue = JSON.parse(await readFile(path.join(outputRealPath, manifest.todos.path), "utf8"));
  } catch (cause) {
    throw new AgentError("RESULT_INVALID", "todos.json 格式无效", { status: 500, cause });
  }
  const todos = validateTodos(todosValue);
  if (todos.job_id !== manifest.job_id || todos.meeting_id !== manifest.meeting_id || todos.items.length !== manifest.todos.count) {
    throw new AgentError("RESULT_INVALID", "todos 与 manifest 不匹配", { status: 500 });
  }
  const html = await readFile(path.join(outputRealPath, manifest.report.path), "utf8");
  validateReportHTML(html, new Set(manifest.assets.map((asset) => asset.path)));
  const declaredFiles = new Set(["manifest.json", manifest.report.path, manifest.todos.path, ...manifest.assets.map((asset) => asset.path)]);
  await verifyNoUndeclaredEntries(outputRealPath, outputRealPath, declaredFiles);
  return { manifest, todos, manifestSha256: await sha256File(manifestPath) };
}

function validateExpectedIdentity(manifest, expectedJob) {
  if (!expectedJob) return;
  const expectedJobId = expectedJob.job_id ?? expectedJob.jobId;
  const expectedHash = expectedJob.request_hash ?? expectedJob.requestHash;
  const expectedMeetingId = expectedJob.meeting_id ?? expectedJob.meetingId;
  const expectedProvider = expectedJob.provider?.name ?? expectedJob.provider;
  if (manifest.job_id !== expectedJobId || manifest.request_id !== expectedJobId) {
    throw new AgentError("RESULT_INVALID", "manifest job_id/request_id 与作业不匹配", { status: 500 });
  }
  if (manifest.request_hash !== expectedHash) throw new AgentError("RESULT_INVALID", "manifest request_hash 与作业不匹配", { status: 500 });
  if (manifest.meeting_id !== expectedMeetingId) throw new AgentError("RESULT_INVALID", "manifest meeting_id 与作业不匹配", { status: 500 });
  if (manifest.provider.name !== expectedProvider) throw new AgentError("RESULT_INVALID", "manifest provider 与作业不匹配", { status: 500 });
}

export async function verifyResultPackage(outputPath, expectedJob) {
  try {
    return await verifyResultPackageImpl(outputPath, expectedJob);
  } catch (error) {
    if (error instanceof AgentError) throw error;
    throw new AgentError("RESULT_INVALID", "结果包校验失败", { status: 500, cause: error });
  }
}

async function verifyNoUndeclaredEntries(outputRealPath, directoryPath, declaredFiles) {
  for (const entry of await readdir(directoryPath, { withFileTypes: true })) {
    const entryPath = path.join(directoryPath, entry.name);
    const relativePath = path.relative(outputRealPath, entryPath).split(path.sep).join("/");
    if (entry.isSymbolicLink()) {
      throw new AgentError("RESULT_INVALID", `结果包包含符号链接：${relativePath}`, { status: 500 });
    }
    if (entry.isDirectory()) {
      await verifyNoUndeclaredEntries(outputRealPath, entryPath, declaredFiles);
      continue;
    }
    if (!entry.isFile()) {
      throw new AgentError("RESULT_INVALID", `结果包包含非普通文件：${relativePath}`, { status: 500 });
    }
    if (!declaredFiles.has(relativePath)) {
      throw new AgentError("RESULT_INVALID", `文件未在 manifest 声明：${relativePath}`, { status: 500 });
    }
  }
}

export async function removeStaleResultStaging(jobRoot) {
  const stagingRoot = path.join(jobRoot, "staging");
  for (const entry of await readdir(stagingRoot, { withFileTypes: true }).catch(() => [])) {
    if (!entry.name.startsWith("result-")) continue;
    const entryPath = path.join(stagingRoot, entry.name);
    if (entry.isDirectory()) {
      await rm(entryPath, { recursive: true, force: true });
    } else if (entry.isSymbolicLink()) {
      await rm(entryPath, { force: true });
    }
  }
}
