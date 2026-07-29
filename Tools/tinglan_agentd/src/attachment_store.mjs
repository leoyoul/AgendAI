import { copyFile, lstat, mkdir, realpath, rm, stat } from "node:fs/promises";
import path from "node:path";

import {
  MAX_ATTACHMENTS,
  MAX_ATTACHMENT_BYTES,
  MAX_TOTAL_ATTACHMENT_BYTES,
} from "./config.mjs";
import { AgentError } from "./errors.mjs";
import { sha256File } from "./hash.mjs";

function isWithin(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

function safeFileName(value) {
  const base = path.basename(value).normalize("NFC").replace(/[\0/\\]/g, "_").trim();
  if (!base || base === "." || base === "..") throw new AgentError("INVALID_REQUEST", "附件文件名无效");
  return base;
}

function uniqueFileName(fileName, usedNames) {
  if (!usedNames.has(fileName)) {
    usedNames.add(fileName);
    return fileName;
  }
  const extension = path.extname(fileName);
  const stem = fileName.slice(0, fileName.length - extension.length);
  for (let index = 2; ; index += 1) {
    const candidate = `${stem}-${index}${extension}`;
    if (!usedNames.has(candidate)) {
      usedNames.add(candidate);
      return candidate;
    }
  }
}

export function validateAttachmentLimits(attachments) {
  if (attachments.length > MAX_ATTACHMENTS) {
    throw new AgentError("INVALID_REQUEST", `附件最多 ${MAX_ATTACHMENTS} 个`);
  }
  let total = 0;
  for (const attachment of attachments) {
    if (!Number.isSafeInteger(attachment.size_bytes) || attachment.size_bytes < 0) {
      throw new AgentError("INVALID_REQUEST", "附件大小必须是非负整数");
    }
    if (attachment.size_bytes > MAX_ATTACHMENT_BYTES) {
      throw new AgentError("INVALID_REQUEST", "单个附件不能超过 100 MiB");
    }
    total += attachment.size_bytes;
  }
  if (total > MAX_TOTAL_ATTACHMENT_BYTES) {
    throw new AgentError("INVALID_REQUEST", "附件总大小不能超过 500 MiB");
  }
  return total;
}

async function verifySource(attachment, roots) {
  if (!/^[a-f0-9]{64}$/.test(attachment.sha256)) {
    throw new AgentError("ATTACHMENT_MISMATCH", "附件 SHA-256 必须是小写十六进制");
  }
  const sourceLstat = await lstat(attachment.source_path).catch((cause) => {
    throw new AgentError("ATTACHMENT_NOT_ALLOWED", "附件不存在或不可读取", { cause });
  });
  if (sourceLstat.isSymbolicLink()) throw new AgentError("ATTACHMENT_NOT_ALLOWED", "附件不能是符号链接");
  if (!sourceLstat.isFile()) throw new AgentError("ATTACHMENT_NOT_ALLOWED", "附件必须是普通文件");
  const sourceRealPath = await realpath(attachment.source_path);
  const allowed = roots.some((root) => isWithin(sourceRealPath, root));
  if (!allowed) throw new AgentError("ATTACHMENT_NOT_ALLOWED", "附件不在允许的白名单目录内");
  const sourceStat = await stat(sourceRealPath);
  if (sourceStat.size !== attachment.size_bytes) throw new AgentError("ATTACHMENT_MISMATCH", "附件大小不一致");
  if ((await sha256File(sourceRealPath)) !== attachment.sha256) {
    throw new AgentError("ATTACHMENT_MISMATCH", "附件 SHA-256 不一致");
  }
  return { sourceRealPath, sourceStat };
}

export async function copyAttachments({ attachments, destinationDir, inputRoots }) {
  validateAttachmentLimits(attachments);
  if (attachments.length === 0) return [];
  if (inputRoots.length === 0) throw new AgentError("ATTACHMENT_NOT_ALLOWED", "未配置附件白名单，不允许接收附件");
  const roots = await Promise.all(inputRoots.map(async (root) => realpath(root)));
  await mkdir(destinationDir, { recursive: true, mode: 0o700 });
  const usedNames = new Set();
  const copiedPaths = [];
  const sanitized = [];
  try {
    for (const attachment of attachments) {
      const { sourceRealPath, sourceStat } = await verifySource(attachment, roots);
      const destinationName = uniqueFileName(safeFileName(attachment.file_name), usedNames);
      const destinationPath = path.join(destinationDir, destinationName);
      await copyFile(sourceRealPath, destinationPath);
      copiedPaths.push(destinationPath);
      const sourceAfter = await lstat(attachment.source_path);
      if (sourceAfter.isSymbolicLink() || sourceAfter.dev !== sourceStat.dev || sourceAfter.ino !== sourceStat.ino) {
        throw new AgentError("ATTACHMENT_MISMATCH", "附件在复制期间发生变化");
      }
      const destinationStat = await lstat(destinationPath);
      if (!destinationStat.isFile() || destinationStat.isSymbolicLink() || destinationStat.size !== attachment.size_bytes) {
        throw new AgentError("ATTACHMENT_MISMATCH", "附件复制后大小不一致");
      }
      if ((await sha256File(destinationPath)) !== attachment.sha256) {
        throw new AgentError("ATTACHMENT_MISMATCH", "附件复制后 SHA-256 不一致");
      }
      sanitized.push({ ...attachment, source_path: `attachments/${destinationName}` });
    }
    return sanitized;
  } catch (error) {
    await Promise.all(copiedPaths.map((filePath) => rm(filePath, { force: true })));
    throw error;
  }
}
