import {
  constants,
  link,
  lstat,
  mkdir,
  open,
  realpath,
  rename,
  unlink,
} from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { sha256 } from "./content_hash.mjs";

const ZENTAO_START = "<!-- tinglan:zentao:start -->";
const ZENTAO_END = "<!-- tinglan:zentao:end -->";
const REVIEW_START = "<!-- tinglan:review:start -->";
const REVIEW_END = "<!-- tinglan:review:end -->";

function yamlString(value) {
  return JSON.stringify(String(value ?? ""));
}

function safeTitle(value) {
  const normalized = String(value ?? "未命名会议")
    .normalize("NFKC")
    .replace(/[\u0000-\u001f\u007f/\\:*?"<>|#^[\]]/g, "-")
    .replace(/\s+/g, " ")
    .replace(/^\.+|\.+$/g, "")
    .trim();
  return (normalized || "未命名会议").slice(0, 72).trim();
}

function shanghaiDate(seconds) {
  const milliseconds = Number(seconds) * 1000;
  const date = new Date(Number.isFinite(milliseconds) ? milliseconds : Date.now());
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function clock(milliseconds) {
  const totalSeconds = Math.max(0, Math.floor(Number(milliseconds || 0) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return [hours, minutes, seconds].map((value) => String(value).padStart(2, "0")).join(":");
}

function frontmatterMatches(text, meetingId, contentHash) {
  const block = text.match(/^---\n([\s\S]*?)\n---(?:\n|$)/)?.[1] ?? "";
  return (
    block.includes(`meeting_id: ${yamlString(meetingId)}`) &&
    block.includes(`content_hash: ${yamlString(contentHash)}`)
  );
}

function machineBlock(candidates) {
  const lines = [ZENTAO_START, "## 禅道任务状态", ""];
  if (!candidates.length) {
    lines.push("暂无待确认任务。");
  } else {
    for (const candidate of candidates) {
      const status = {
        awaiting_approval: "待确认",
        creating: "创建中，待对账",
        created: "已创建",
        skipped: "已跳过",
      }[candidate.status] ?? candidate.status;
      const reference = candidate.zentao_url
        ? ` [${candidate.zentao_task_id ?? "查看"}](${candidate.zentao_url})`
        : candidate.zentao_task_id
          ? ` #${candidate.zentao_task_id}`
          : "";
      lines.push(`- [${status}] ${candidate.title}${reference} <!-- ${candidate.candidate_id} -->`);
    }
  }
  lines.push(ZENTAO_END);
  return lines.join("\n");
}

function reviewLine(value) {
  return String(value ?? "")
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .replace(/<!--\s*tinglan:(?:review|zentao):(start|end)\s*-->/gi, "")
    .trim();
}

function reviewBlock(review = null) {
  const status = review?.status === "confirmed" ? "已确认" : review?.status === "changes_requested" ? "已提出修改" : "待确认";
  const lines = [REVIEW_START, "## 人工确认区", "", `- 确认状态：${status}`, "- 参会人员："];
  const attendees = Array.isArray(review?.attendees) ? review.attendees : [];
  if (!attendees.length) {
    lines.push("  - 待确认");
  } else {
    for (const attendee of attendees) {
      const role = reviewLine(attendee.role);
      lines.push(`  - ${reviewLine(attendee.name)}${role ? `（${role}）` : ""}`);
    }
  }
  lines.push("- 会议地点/形式：");
  const context = review?.context && typeof review.context === "object" ? review.context : {};
  const contextEntries = Object.entries(context).filter(([, value]) => reviewLine(value));
  if (!contextEntries.length) {
    lines.push("  - 待确认");
  } else {
    for (const [key, value] of contextEntries) {
      lines.push(`  - ${reviewLine(key)}：${reviewLine(value)}`);
    }
  }
  lines.push(`- 用户修订：${reviewLine(review?.corrections) || "暂无"}`, REVIEW_END);
  return lines.join("\n");
}

function replaceFrontmatterValue(text, key, value) {
  const line = `${key}: ${yamlString(value)}`;
  const pattern = new RegExp(`^${key}:.*$`, "m");
  if (!pattern.test(text)) throw new Error(`Obsidian 文件缺少 ${key} 元数据`);
  return text.replace(pattern, line);
}

function replaceFirstHeading(text, heading) {
  const frontmatter = text.match(/^---\n[\s\S]*?\n---\n/)?.[0];
  if (!frontmatter) throw new Error("Obsidian 文件缺少合法 frontmatter");
  const body = text.slice(frontmatter.length);
  if (!/^#\s+.+$/m.test(body)) throw new Error("Obsidian 文件缺少会议标题");
  return `${frontmatter}${body.replace(/^#\s+.+$/m, `# ${heading}`)}`;
}

function replaceMinutesTitle(text, title) {
  const sectionPattern = /(##\s+一、会议基本信息\s*\n)([\s\S]*?)(?=\n##\s+|$)/;
  const match = text.match(sectionPattern);
  if (!match) throw new Error("会议纪要缺少“会议基本信息”章节");
  const titlePattern = /^-\s*(?:会议)?标题\s*[：:].*$/m;
  const details = titlePattern.test(match[2])
    ? match[2].replace(titlePattern, `- 标题：${title}`)
    : `- 标题：${title}\n${match[2]}`;
  return text.replace(sectionPattern, `${match[1]}${details}`);
}

export class ObsidianWriter {
  constructor({ root, hooks = {} }) {
    this.root = path.resolve(root);
    this.realRoot = null;
    this.hooks = hooks;
  }

  #withinRoot(candidate) {
    const resolved = path.resolve(candidate);
    if (resolved !== this.root && !resolved.startsWith(`${this.root}${path.sep}`)) {
      throw new Error("拒绝写入 Obsidian 根目录之外的路径");
    }
    return resolved;
  }

  #withinRealRoot(candidate) {
    if (!this.realRoot) throw new Error("Obsidian 根目录尚未初始化");
    const resolved = path.resolve(candidate);
    if (resolved !== this.realRoot && !resolved.startsWith(`${this.realRoot}${path.sep}`)) {
      throw new Error("拒绝通过符号链接写入 Obsidian 根目录之外");
    }
    return resolved;
  }

  async #ensureRoot() {
    await mkdir(this.root, { recursive: true, mode: 0o755 });
    const rootStat = await lstat(this.root);
    if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
      throw new Error("Obsidian 根目录不能是符号链接，且必须是目录");
    }
    const resolved = await realpath(this.root);
    if (this.realRoot && this.realRoot !== resolved) {
      throw new Error("Obsidian 根目录在运行期间发生变化");
    }
    this.realRoot = resolved;
  }

  async #ensureSafeDirectory(directory) {
    const safeDirectory = this.#withinRoot(directory);
    await this.#ensureRoot();
    const relative = path.relative(this.root, safeDirectory);
    let current = this.root;
    for (const component of relative.split(path.sep).filter(Boolean)) {
      current = path.join(current, component);
      try {
        const currentStat = await lstat(current);
        if (currentStat.isSymbolicLink() || !currentStat.isDirectory()) {
          throw new Error(`Obsidian 路径包含符号链接或非目录节点：${current}`);
        }
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
        await mkdir(current, { mode: 0o755 });
        const createdStat = await lstat(current);
        if (createdStat.isSymbolicLink() || !createdStat.isDirectory()) {
          throw new Error(`Obsidian 路径创建后不是安全目录：${current}`);
        }
      }
    }
    this.#withinRealRoot(await realpath(safeDirectory));
    return safeDirectory;
  }

  async #readSafeFile(filePath) {
    const safePath = this.#withinRoot(filePath);
    await this.#ensureSafeDirectory(path.dirname(safePath));
    const fileStat = await lstat(safePath);
    if (fileStat.isSymbolicLink() || !fileStat.isFile()) {
      throw new Error(`Obsidian 文件不能是符号链接，且必须是普通文件：${safePath}`);
    }
    this.#withinRealRoot(await realpath(safePath));
    const handle = await open(
      safePath,
      constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0),
    );
    try {
      const content = await handle.readFile({ encoding: "utf8" });
      const handleStat = await handle.stat({ bigint: true });
      this.#withinRealRoot(await realpath(safePath));
      return {
        content,
        fingerprint: [
          handleStat.dev,
          handleStat.ino,
          handleStat.size,
          handleStat.mtimeNs,
          handleStat.ctimeNs,
        ].join(":"),
      };
    } finally {
      await handle.close();
    }
  }

  async #readSafeFileIfExists(filePath) {
    try {
      return await this.#readSafeFile(filePath);
    } catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    }
  }

  async #existingMatch(filePath, meetingId, contentHash) {
    const result = await this.#readSafeFileIfExists(filePath);
    return result && frontmatterMatches(result.content, meetingId, contentHash)
      ? result.content
      : null;
  }

  async #choosePath(directory, basename, meetingId, contentHash) {
    await this.#ensureSafeDirectory(directory);
    const plain = this.#withinRoot(path.join(directory, `${basename}.md`));
    const plainContent = await this.#readSafeFileIfExists(plain);
    if (!plainContent) return plain;
    if (frontmatterMatches(plainContent.content, meetingId, contentHash)) return plain;
    const versioned = this.#withinRoot(
      path.join(directory, `${basename}-${contentHash.slice(0, 12)}.md`),
    );
    const versionedContent = await this.#readSafeFileIfExists(versioned);
    if (!versionedContent) return versioned;
    if (frontmatterMatches(versionedContent.content, meetingId, contentHash)) return versioned;
    throw new Error(`目标文件名冲突，且不属于当前会议版本：${versioned}`);
  }

  async #publishNoReplace(filePath, content, meetingId, contentHash) {
    const existing = await this.#existingMatch(filePath, meetingId, contentHash);
    if (existing) return { reused: true, checksum: sha256(existing) };

    await this.#ensureSafeDirectory(path.dirname(filePath));
    const temporary = this.#withinRoot(
      path.join(path.dirname(filePath), `.${path.basename(filePath)}.${randomUUID()}.tmp`),
    );
    let handle;
    try {
      handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
      this.#withinRealRoot(await realpath(temporary));
      await handle.writeFile(content, "utf8");
      await handle.sync();
      await handle.close();
      handle = null;
      try {
        await this.#ensureSafeDirectory(path.dirname(filePath));
        await link(temporary, filePath);
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
        const published = await this.#readSafeFile(filePath);
        if (!frontmatterMatches(published.content, meetingId, contentHash)) {
          throw new Error(`拒绝覆盖已存在的 Obsidian 文件：${filePath}`);
        }
        return { reused: true, checksum: sha256(published.content) };
      }
      this.#withinRealRoot(await realpath(filePath));
      return { reused: false, checksum: sha256(content) };
    } finally {
      if (handle) await handle.close().catch(() => {});
      await unlink(temporary).catch(() => {});
    }
  }

  async #replaceMatchingFile(filePath, snapshot, content, meetingId, contentHash) {
    const safePath = this.#withinRoot(filePath);
    if (!frontmatterMatches(snapshot.content, meetingId, contentHash)) {
      throw new Error("Obsidian 文件与当前会议版本不匹配");
    }
    if (snapshot.content === content) {
      return { path: safePath, checksum: sha256(content), fingerprint: snapshot.fingerprint };
    }
    const temporary = this.#withinRoot(
      path.join(path.dirname(safePath), `.${path.basename(safePath)}.${randomUUID()}.title.tmp`),
    );
    let handle;
    try {
      await this.#ensureSafeDirectory(path.dirname(safePath));
      handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
      this.#withinRealRoot(await realpath(temporary));
      await handle.writeFile(content, "utf8");
      await handle.sync();
      await handle.close();
      handle = null;
      const current = await this.#readSafeFile(safePath);
      if (
        current.content !== snapshot.content ||
        current.fingerprint !== snapshot.fingerprint
      ) {
        throw new Error("Obsidian 文件在更新会议标题期间发生变化，请重试");
      }
      await rename(temporary, safePath);
      this.#withinRealRoot(await realpath(safePath));
      return { path: safePath, checksum: sha256(content) };
    } finally {
      if (handle) await handle.close().catch(() => {});
      await unlink(temporary).catch(() => {});
    }
  }

  #frontmatter(packet, contentHash, sourceName = null) {
    const meeting = packet.meeting;
    const lines = [
      "---",
      `meeting_id: ${yamlString(meeting.meeting_id)}`,
      `content_hash: ${yamlString(contentHash)}`,
      `meeting_title: ${yamlString(meeting.title)}`,
      `started_at: ${meeting.started_at ?? "null"}`,
      `ended_at: ${meeting.ended_at ?? "null"}`,
      `handoff_at: ${yamlString(new Date().toISOString())}`,
    ];
    if (sourceName) {
      lines.push(`source_note: ${yamlString(`[[${sourceName}]]`)}`);
      lines.push('zentao_status: "awaiting_approval"');
    }
    lines.push("---", "");
    return lines.join("\n");
  }

  #sourceMarkdown(packet, contentHash) {
    const lines = [
      this.#frontmatter(packet, contentHash),
      `# ${packet.meeting.title} - 原始转写`,
      "",
    ];
    for (const segment of packet.segments) {
      lines.push(
        `- **${clock(segment.start_ms)}-${clock(segment.end_ms)} ${segment.speaker || "未知发言人"}**：${segment.text}`,
      );
    }
    return `${lines.join("\n").trimEnd()}\n`;
  }

  #draftMarkdown(packet, contentHash, summary, sourceName, candidates) {
    return `${[
      this.#frontmatter(packet, contentHash, sourceName),
      `# ${packet.meeting.title}`,
      "",
      `原始转写：[[${sourceName}]]`,
      "",
      String(summary).trim(),
      "",
      reviewBlock(),
      "",
      machineBlock(candidates),
      "",
    ].join("\n")}`;
  }

  async writeMeeting(packet, contentHash, summary, candidates = []) {
    const meeting = packet.meeting;
    const date = shanghaiDate(meeting.started_at ?? meeting.created_at);
    const year = date.slice(0, 4);
    const idPrefix = safeTitle(meeting.meeting_id).slice(0, 8);
    const basename = `${date}-${safeTitle(meeting.title)}-${idPrefix}`;
    const sourceDirectory = this.#withinRoot(
      path.join(this.root, "30_Sources/会小纪会议", year),
    );
    const draftDirectory = this.#withinRoot(
      path.join(this.root, "01_AI_Drafts/会小纪会议", year),
    );
    const sourcePath = await this.#choosePath(
      sourceDirectory,
      `${basename}-原始转写`,
      meeting.meeting_id,
      contentHash,
    );
    const draftPath = await this.#choosePath(
      draftDirectory,
      basename,
      meeting.meeting_id,
      contentHash,
    );
    const sourceName = path.basename(sourcePath, ".md");
    const sourceContent = this.#sourceMarkdown(packet, contentHash);
    const draftContent = this.#draftMarkdown(
      packet,
      contentHash,
      summary,
      sourceName,
      candidates,
    );
    const source = await this.#publishNoReplace(
      sourcePath,
      sourceContent,
      meeting.meeting_id,
      contentHash,
    );
    await this.hooks.afterSourcePublish?.({ sourcePath, draftPath });
    const draft = await this.#publishNoReplace(
      draftPath,
      draftContent,
      meeting.meeting_id,
      contentHash,
    );
    await this.hooks.afterDraftPublish?.({ sourcePath, draftPath });
    return {
      source: { path: sourcePath, checksum: source.checksum },
      draft: { path: draftPath, checksum: draft.checksum },
    };
  }

  async relabelMeeting({
    packet,
    contentHash,
    sourcePath,
    draftPath,
    title,
  }) {
    const normalizedTitle = String(title ?? "").normalize("NFC").trim();
    if (!normalizedTitle) throw new Error("会议标题不能为空");
    const safeSourcePath = this.#withinRoot(sourcePath);
    const safeDraftPath = this.#withinRoot(draftPath);
    const sourceSnapshot = await this.#readSafeFile(safeSourcePath);
    const draftSnapshot = await this.#readSafeFile(safeDraftPath);
    const meetingId = packet.meeting.meeting_id;
    for (const snapshot of [sourceSnapshot, draftSnapshot]) {
      if (!frontmatterMatches(snapshot.content, meetingId, contentHash)) {
        throw new Error("Obsidian 文件与当前会议版本不匹配");
      }
    }

    const date = shanghaiDate(packet.meeting.started_at ?? packet.meeting.created_at);
    const year = date.slice(0, 4);
    const idPrefix = safeTitle(meetingId).slice(0, 8);
    const basename = `${date}-${safeTitle(normalizedTitle)}-${idPrefix}`;
    const sourceDirectory = this.#withinRoot(path.join(this.root, "30_Sources/会小纪会议", year));
    const draftDirectory = this.#withinRoot(path.join(this.root, "01_AI_Drafts/会小纪会议", year));
    const nextSourcePath = await this.#choosePath(
      sourceDirectory,
      `${basename}-原始转写`,
      meetingId,
      contentHash,
    );
    const nextDraftPath = await this.#choosePath(
      draftDirectory,
      basename,
      meetingId,
      contentHash,
    );
    const sourceName = path.basename(nextSourcePath, ".md");

    let sourceContent = replaceFrontmatterValue(sourceSnapshot.content, "meeting_title", normalizedTitle);
    sourceContent = replaceFirstHeading(sourceContent, `${normalizedTitle} - 原始转写`);
    let draftContent = replaceFrontmatterValue(draftSnapshot.content, "meeting_title", normalizedTitle);
    draftContent = replaceFrontmatterValue(draftContent, "source_note", `[[${sourceName}]]`);
    draftContent = replaceFirstHeading(draftContent, normalizedTitle);
    draftContent = draftContent.replace(/^原始转写：\[\[.*\]\]$/m, `原始转写：[[${sourceName}]]`);
    draftContent = replaceMinutesTitle(draftContent, normalizedTitle);

    const writeTarget = async (currentPath, nextPath, snapshot, content) => {
      if (currentPath === nextPath) {
        return this.#replaceMatchingFile(currentPath, snapshot, content, meetingId, contentHash);
      }
      const published = await this.#publishNoReplace(nextPath, content, meetingId, contentHash);
      const actual = await this.#readSafeFile(nextPath);
      if (actual.content !== content) {
        throw new Error(`目标标题文件已存在不同内容：${nextPath}`);
      }
      return { path: nextPath, checksum: published.checksum };
    };

    const source = await writeTarget(
      safeSourcePath,
      nextSourcePath,
      sourceSnapshot,
      sourceContent,
    );
    const draft = await writeTarget(
      safeDraftPath,
      nextDraftPath,
      draftSnapshot,
      draftContent,
    );
    return {
      source,
      draft,
      superseded: [
        { path: safeSourcePath, replacement: nextSourcePath, fingerprint: sourceSnapshot.fingerprint },
        { path: safeDraftPath, replacement: nextDraftPath, fingerprint: draftSnapshot.fingerprint },
      ],
    };
  }

  async removeSupersededArtifacts(entries, meetingId, contentHash) {
    const retained = [];
    for (const entry of entries ?? []) {
      if (!entry?.path || entry.path === entry.replacement) continue;
      const snapshot = await this.#readSafeFileIfExists(entry.path);
      if (!snapshot) continue;
      if (
        !frontmatterMatches(snapshot.content, meetingId, contentHash) ||
        snapshot.fingerprint !== entry.fingerprint
      ) {
        retained.push(entry.path);
        continue;
      }
      await unlink(this.#withinRoot(entry.path));
    }
    return retained;
  }

  async updateZentaoBlock(draftPath, meetingId, contentHash, candidates) {
    const safePath = this.#withinRoot(draftPath);
    const firstSnapshot = await this.#readSafeFile(safePath);
    const firstRead = firstSnapshot.content;
    if (!frontmatterMatches(firstRead, meetingId, contentHash)) {
      throw new Error("Obsidian 草稿与当前会议版本不匹配");
    }
    const start = firstRead.indexOf(ZENTAO_START);
    const end = firstRead.indexOf(ZENTAO_END);
    if (start < 0 || end < start || firstRead.indexOf(ZENTAO_START, start + 1) >= 0) {
      throw new Error("Obsidian 草稿的禅道机器管理区不完整");
    }
    const replacement = machineBlock(candidates);
    const next = `${firstRead.slice(0, start)}${replacement}${firstRead.slice(end + ZENTAO_END.length)}`;
    if (next === firstRead) return { path: safePath, checksum: sha256(firstRead) };

    const temporary = this.#withinRoot(
      path.join(path.dirname(safePath), `.${path.basename(safePath)}.${randomUUID()}.tmp`),
    );
    let handle;
    try {
      await this.#ensureSafeDirectory(path.dirname(safePath));
      handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
      this.#withinRealRoot(await realpath(temporary));
      await handle.writeFile(next, "utf8");
      await handle.sync();
      await handle.close();
      handle = null;
      await this.hooks.beforeManagedReplace?.({ draftPath: safePath });
      const secondSnapshot = await this.#readSafeFile(safePath);
      if (
        secondSnapshot.content !== firstRead ||
        secondSnapshot.fingerprint !== firstSnapshot.fingerprint
      ) {
        throw new Error("Obsidian 草稿在更新期间发生变化，请重试");
      }
      await this.#ensureSafeDirectory(path.dirname(safePath));
      await rename(temporary, safePath);
      this.#withinRealRoot(await realpath(safePath));
      return { path: safePath, checksum: sha256(next) };
    } finally {
      if (handle) await handle.close().catch(() => {});
      await unlink(temporary).catch(() => {});
    }
  }

  async updateReviewBlock(draftPath, meetingId, contentHash, review) {
    const safePath = this.#withinRoot(draftPath);
    const firstSnapshot = await this.#readSafeFile(safePath);
    const firstRead = firstSnapshot.content;
    if (!frontmatterMatches(firstRead, meetingId, contentHash)) {
      throw new Error("Obsidian 草稿与当前会议版本不匹配");
    }
    const start = firstRead.indexOf(REVIEW_START);
    const end = firstRead.indexOf(REVIEW_END);
    if (start < 0 || end < start || firstRead.indexOf(REVIEW_START, start + 1) >= 0) {
      throw new Error("Obsidian 草稿的人工确认区不完整");
    }
    const replacement = reviewBlock(review);
    const next = `${firstRead.slice(0, start)}${replacement}${firstRead.slice(end + REVIEW_END.length)}`;
    if (next === firstRead) return { path: safePath, checksum: sha256(firstRead) };

    const temporary = this.#withinRoot(
      path.join(path.dirname(safePath), `.${path.basename(safePath)}.${randomUUID()}.review.tmp`),
    );
    let handle;
    try {
      await this.#ensureSafeDirectory(path.dirname(safePath));
      handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
      this.#withinRealRoot(await realpath(temporary));
      await handle.writeFile(next, "utf8");
      await handle.sync();
      await handle.close();
      handle = null;
      await this.hooks.beforeReviewReplace?.({ draftPath: safePath });
      const secondSnapshot = await this.#readSafeFile(safePath);
      if (
        secondSnapshot.content !== firstRead ||
        secondSnapshot.fingerprint !== firstSnapshot.fingerprint
      ) {
        throw new Error("Obsidian 草稿在更新人工确认区期间发生变化，请重试");
      }
      await this.#ensureSafeDirectory(path.dirname(safePath));
      await rename(temporary, safePath);
      this.#withinRealRoot(await realpath(safePath));
      return { path: safePath, checksum: sha256(next) };
    } finally {
      if (handle) await handle.close().catch(() => {});
      await unlink(temporary).catch(() => {});
    }
  }

  async verifyArtifacts(meetingId, contentHash, sourcePath, draftPath) {
    for (const candidate of [sourcePath, draftPath]) {
      const safePath = this.#withinRoot(candidate);
      const { content } = await this.#readSafeFile(safePath);
      if (!frontmatterMatches(content, meetingId, contentHash)) {
        throw new Error(`Obsidian 文件与当前会议版本不匹配：${safePath}`);
      }
    }
    return true;
  }
}
