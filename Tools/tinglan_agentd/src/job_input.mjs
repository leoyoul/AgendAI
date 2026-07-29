import { randomBytes } from "node:crypto";
import { access, lstat, mkdir, open, readFile, readdir, realpath, rename, rm } from "node:fs/promises";
import path from "node:path";

import { copyAttachments } from "./attachment_store.mjs";
import { DEFAULT_RECEIVE_LOCK_TIMEOUT_MS as CONFIGURED_RECEIVE_LOCK_TIMEOUT_MS } from "./config.mjs";
import { AgentError } from "./errors.mjs";
import { computeRequestHash } from "./hash.mjs";
import { validateJobRequest } from "./schemas.mjs";

export const DEFAULT_RECEIVE_LOCK_TIMEOUT_MS = CONFIGURED_RECEIVE_LOCK_TIMEOUT_MS;

async function fsyncPath(targetPath) {
  const handle = await open(targetPath, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function writeJsonDurably(filePath, value) {
  const handle = await open(filePath, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
}

function existingResult(jobStore, requestId, requestHash) {
  const existing = jobStore.get(requestId);
  if (!existing) return null;
  if (existing.request_hash !== requestHash) {
    throw new AgentError("IDEMPOTENCY_CONFLICT", "request_id 已对应不同内容", { status: 409 });
  }
  return { job: existing, created: false };
}

async function acquireReceiveLock(lockPath, jobStore, requestId, requestHash, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (true) {
    try {
      await mkdir(lockPath, { mode: 0o700 });
      return null;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const existing = existingResult(jobStore, requestId, requestHash);
      if (existing) return existing;
      if (Date.now() >= deadline) throw new AgentError("INTERNAL_ERROR", "等待同一 request_id 接收完成超时", { status: 500 });
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
}

async function ensureSafeJobRoot(jobsRoot, requestId) {
  await mkdir(jobsRoot, { recursive: true, mode: 0o700 });
  const jobsRootInfo = await lstat(jobsRoot);
  if (!jobsRootInfo.isDirectory() || jobsRootInfo.isSymbolicLink()) {
    throw new AgentError("INVALID_REQUEST", "jobsRoot 必须是普通目录且不能是符号链接");
  }
  const jobsRootRealPath = await realpath(jobsRoot);
  const jobRoot = path.join(jobsRoot, requestId);
  try {
    await mkdir(jobRoot, { mode: 0o700 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  const jobRootInfo = await lstat(jobRoot);
  if (!jobRootInfo.isDirectory() || jobRootInfo.isSymbolicLink()) {
    throw new AgentError("INVALID_REQUEST", "jobRoot 必须是普通目录且不能是符号链接");
  }
  const jobRootRealPath = await realpath(jobRoot);
  const relative = path.relative(jobsRootRealPath, jobRootRealPath);
  if (relative !== requestId || path.isAbsolute(relative)) {
    throw new AgentError("INVALID_REQUEST", "jobRoot 越出 jobsRoot");
  }
  return jobRoot;
}

async function receiveJobInputUnsafe({
  request: untrustedRequest,
  jobsRoot,
  jobStore,
  inputRoots,
  provider = "mock",
  hooks = {},
  receiveLockTimeoutMs = DEFAULT_RECEIVE_LOCK_TIMEOUT_MS,
}) {
  let request;
  try {
    request = validateJobRequest(untrustedRequest);
  } catch (cause) {
    throw new AgentError("INVALID_REQUEST", "请求格式无效", { status: 400, cause });
  }
  const requestHash = computeRequestHash(request);
  const alreadyAccepted = existingResult(jobStore, request.request_id, requestHash);
  if (alreadyAccepted) return alreadyAccepted;

  const jobRoot = await ensureSafeJobRoot(jobsRoot, request.request_id);
  const lockPath = path.join(jobRoot, ".receive-lock");
  const lockResult = await acquireReceiveLock(lockPath, jobStore, request.request_id, requestHash, receiveLockTimeoutMs);
  if (lockResult) return lockResult;

  const stagingPath = path.join(jobRoot, `.input-staging-${process.pid}-${randomBytes(6).toString("hex")}`);
  const inputPath = path.join(jobRoot, "input");
  let inputPublished = false;
  try {
    const afterLockExisting = existingResult(jobStore, request.request_id, requestHash);
    if (afterLockExisting) return afterLockExisting;
    try {
      await access(inputPath);
      throw new AgentError("INTERNAL_ERROR", "检测到未登记的完整 input 目录，请先执行启动清理", { status: 500 });
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }

    await mkdir(stagingPath, { mode: 0o700 });
    let sanitizedAttachments = [];
    if (request.attachments.length > 0) {
      const attachmentPath = path.join(stagingPath, "attachments");
      await mkdir(attachmentPath, { mode: 0o700 });
      sanitizedAttachments = await copyAttachments({ attachments: request.attachments, destinationDir: attachmentPath, inputRoots });
      for (const attachment of sanitizedAttachments) {
        await fsyncPath(path.join(stagingPath, attachment.source_path));
      }
      await fsyncPath(attachmentPath);
    }
    const sanitizedRequest = { ...request, attachments: sanitizedAttachments };
    await writeJsonDurably(path.join(stagingPath, "request.json"), sanitizedRequest);
    await fsyncPath(stagingPath);
    await rename(stagingPath, inputPath);
    inputPublished = true;
    await fsyncPath(jobRoot);
    await hooks.afterInputPublished?.({ jobRoot, inputPath, request: sanitizedRequest });
    return jobStore.createOrGet({
      requestId: request.request_id,
      requestHash,
      meetingId: request.meeting.id,
      provider,
      inputPath,
    });
  } finally {
    if (!inputPublished) await rm(stagingPath, { recursive: true, force: true });
    await rm(lockPath, { recursive: true, force: true });
    if (!inputPublished) {
      const entries = await readdir(jobRoot).catch(() => []);
      if (entries.length === 0) await rm(jobRoot, { recursive: true, force: true });
    }
  }
}

export async function receiveJobInput(options) {
  try {
    return await receiveJobInputUnsafe(options);
  } catch (error) {
    if (error instanceof AgentError) throw error;
    throw new AgentError("INTERNAL_ERROR", "接收作业输入失败", { status: 500, cause: error });
  }
}

async function safeRemoveInside(rootRealPath, candidatePath) {
  const candidateLstat = await lstat(candidatePath);
  if (candidateLstat.isSymbolicLink()) {
    await rm(candidatePath, { force: true });
    return;
  }
  const candidateRealPath = await realpath(candidatePath);
  const relative = path.relative(rootRealPath, candidateRealPath);
  if (relative === "" || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error("拒绝清理 jobs 根目录之外的路径");
  }
  await rm(candidatePath, { recursive: true, force: true });
}

export async function cleanOrphanJobs({ jobsRoot, jobStore }) {
  await mkdir(jobsRoot, { recursive: true, mode: 0o700 });
  const rootRealPath = await realpath(jobsRoot);
  const knownJobs = new Set(jobStore.listJobIds());
  const removed = [];
  for (const entry of await readdir(jobsRoot, { withFileTypes: true })) {
    const entryPath = path.join(jobsRoot, entry.name);
    if (entry.isSymbolicLink()) {
      await rm(entryPath, { force: true });
      removed.push(entry.name);
      continue;
    }
    if (!entry.isDirectory()) continue;
    if (!knownJobs.has(entry.name)) {
      await safeRemoveInside(rootRealPath, entryPath);
      removed.push(entry.name);
      continue;
    }
    for (const child of await readdir(entryPath, { withFileTypes: true })) {
      if (!child.name.startsWith(".input-staging-") && child.name !== ".receive-lock") continue;
      const childPath = path.join(entryPath, child.name);
      if (child.isSymbolicLink()) await rm(childPath, { force: true });
      else if (child.isDirectory()) await safeRemoveInside(rootRealPath, childPath);
    }
  }
  return removed;
}

export async function readSanitizedJobRequest(inputPath) {
  return JSON.parse(await readFile(path.join(inputPath, "request.json"), "utf8"));
}
