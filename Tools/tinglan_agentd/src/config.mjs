import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync } from "node:fs";
import { chmod, link, lstat, mkdir, open, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export const MAX_JSON_BYTES = 20 * 1024 * 1024;
export const MAX_ATTACHMENTS = 20;
export const MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;
export const MAX_TOTAL_ATTACHMENT_BYTES = 500 * 1024 * 1024;
export const DEFAULT_RECEIVE_LOCK_TIMEOUT_MS = 10 * 60 * 1000;
export const DEFAULT_PROVIDER_TIMEOUT_MS = 10 * 60 * 1000;
export const DEFAULT_SHUTDOWN_TIMEOUT_MS = 5 * 1000;
export const DEFAULT_HTTP_REQUEST_TIMEOUT_MS = 30 * 1000;
export const DEFAULT_HTTP_HEADERS_TIMEOUT_MS = 10 * 1000;
export const DEFAULT_CODEX_HANDSHAKE_TIMEOUT_MS = 30 * 1000;
export const BUNDLED_CODEX_BINARY = "/Applications/ChatGPT.app/Contents/Resources/codex";

const PROVIDERS = new Set(["mock", "codex-app-server"]);
const CODEX_EFFORTS = new Set(["low", "medium", "high", "xhigh", "max", "ultra"]);

function positiveInteger(value, fallback, name) {
  if (value === undefined || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${name} 必须是正安全整数`);
  return parsed;
}

export function parseInputRoots(value = "") {
  if (value.trim() === "") return [];
  return value.split(path.delimiter).filter(Boolean).map((root) => {
    if (!path.isAbsolute(root)) throw new Error(`附件白名单必须是绝对路径：${root}`);
    return path.resolve(root);
  });
}

function optionalTrimmed(value) {
  const trimmed = String(value ?? "").trim();
  return trimmed || null;
}

function parseAbsolutePaths(value = "") {
  if (value.trim() === "") return [];
  return value.split(path.delimiter).filter(Boolean).map((entry) => {
    if (!path.isAbsolute(entry)) throw new Error(`禁止访问路径必须是绝对路径：${entry}`);
    return path.resolve(entry);
  });
}

export function loadConfig(env = process.env) {
  const home = env.HOME || os.homedir();
  const dataRoot = path.resolve(env.TINGLAN_AGENT_DATA_ROOT || path.join(home, "Library/Application Support/会小纪 Agent"));
  const host = env.TINGLAN_AGENT_HOST || "127.0.0.1";
  if (host !== "127.0.0.1") throw new Error("tinglan-agentd 只允许监听 127.0.0.1");
  const port = Number(env.TINGLAN_AGENT_PORT || 18765);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("TINGLAN_AGENT_PORT 必须是 0-65535 的整数");
  const requestTimeoutMs = positiveInteger(env.TINGLAN_AGENT_HTTP_REQUEST_TIMEOUT_MS, DEFAULT_HTTP_REQUEST_TIMEOUT_MS, "TINGLAN_AGENT_HTTP_REQUEST_TIMEOUT_MS");
  const headersTimeoutMs = positiveInteger(env.TINGLAN_AGENT_HTTP_HEADERS_TIMEOUT_MS, DEFAULT_HTTP_HEADERS_TIMEOUT_MS, "TINGLAN_AGENT_HTTP_HEADERS_TIMEOUT_MS");
  if (headersTimeoutMs > requestTimeoutMs) throw new Error("HTTP headers timeout 不能大于 request timeout");
  const provider = env.TINGLAN_AGENT_PROVIDER || "mock";
  if (!PROVIDERS.has(provider)) throw new Error(`不支持 Provider：${provider}`);
  const configuredCodexBin = optionalTrimmed(env.TINGLAN_CODEX_BIN);
  if (configuredCodexBin && !path.isAbsolute(configuredCodexBin)) {
    throw new Error("TINGLAN_CODEX_BIN 必须是绝对路径");
  }
  const codexEffort = optionalTrimmed(env.TINGLAN_CODEX_EFFORT);
  if (codexEffort && !CODEX_EFFORTS.has(codexEffort)) {
    throw new Error("TINGLAN_CODEX_EFFORT 不是支持的推理强度");
  }
  const configuredCodexHome = optionalTrimmed(env.CODEX_HOME);
  if (configuredCodexHome && !path.isAbsolute(configuredCodexHome)) {
    throw new Error("CODEX_HOME 必须是绝对路径");
  }
  const codexHome = path.resolve(configuredCodexHome || path.join(home, ".codex"));
  const defaultDatabasePath = path.join(home, "Library/Application Support/会小纪/ai-tingji.sqlite");
  const forbiddenPaths = new Set([
    defaultDatabasePath,
    `${defaultDatabasePath}-wal`,
    `${defaultDatabasePath}-shm`,
    ...parseAbsolutePaths(env.TINGLAN_AGENT_FORBIDDEN_PATHS || ""),
  ]);
  return Object.freeze({
    host,
    port,
    dataRoot,
    tokenPath: path.join(dataRoot, "api-token"),
    databasePath: path.join(dataRoot, "agent.sqlite"),
    jobsRoot: path.join(dataRoot, "jobs"),
    inputRoots: parseInputRoots(env.TINGLAN_AGENT_INPUT_ROOTS || ""),
    provider,
    maxJsonBytes: MAX_JSON_BYTES,
    receiveLockTimeoutMs: positiveInteger(env.TINGLAN_AGENT_RECEIVE_LOCK_TIMEOUT_MS, DEFAULT_RECEIVE_LOCK_TIMEOUT_MS, "TINGLAN_AGENT_RECEIVE_LOCK_TIMEOUT_MS"),
    providerTimeoutMs: positiveInteger(env.TINGLAN_AGENT_PROVIDER_TIMEOUT_MS, DEFAULT_PROVIDER_TIMEOUT_MS, "TINGLAN_AGENT_PROVIDER_TIMEOUT_MS"),
    shutdownTimeoutMs: positiveInteger(env.TINGLAN_AGENT_SHUTDOWN_TIMEOUT_MS, DEFAULT_SHUTDOWN_TIMEOUT_MS, "TINGLAN_AGENT_SHUTDOWN_TIMEOUT_MS"),
    requestTimeoutMs,
    headersTimeoutMs,
    codexBin: configuredCodexBin || (existsSync(BUNDLED_CODEX_BINARY) ? BUNDLED_CODEX_BINARY : "codex"),
    codexHome,
    codexModel: optionalTrimmed(env.TINGLAN_CODEX_MODEL),
    codexEffort,
    codexHandshakeTimeoutMs: positiveInteger(
      env.TINGLAN_CODEX_HANDSHAKE_TIMEOUT_MS,
      DEFAULT_CODEX_HANDSHAKE_TIMEOUT_MS,
      "TINGLAN_CODEX_HANDSHAKE_TIMEOUT_MS",
    ),
    codexForbiddenPaths: Object.freeze([...forbiddenPaths]),
  });
}

async function readToken(tokenPath) {
  const info = await lstat(tokenPath);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error("API token 必须是普通文件且不能是符号链接");
  const token = (await readFile(tokenPath, "utf8")).trim();
  if (Buffer.byteLength(token, "utf8") < 32) throw new Error("现有 API token 长度不足 32 字节");
  await chmod(tokenPath, 0o600);
  return token;
}

export async function ensureApiToken(tokenPath) {
  await mkdir(path.dirname(tokenPath), { recursive: true, mode: 0o700 });
  try {
    return await readToken(tokenPath);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const token = randomBytes(32).toString("base64url");
  const temporaryPath = `${tokenPath}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`;
  const handle = await open(temporaryPath, "wx", 0o600);
  try {
    await handle.writeFile(`${token}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await link(temporaryPath, tokenPath);
    const directory = await open(path.dirname(tokenPath), "r");
    try {
      await directory.sync();
    } finally {
      await directory.close();
    }
  } catch (error) {
    if (error.code !== "EEXIST") {
      await rm(temporaryPath, { force: true });
      throw error;
    }
  } finally {
    await rm(temporaryPath, { force: true });
  }
  return readToken(tokenPath);
}

export function verifyBearerToken(authorization, expectedToken) {
  const supplied = typeof authorization === "string" && authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : "";
  const suppliedDigest = createHash("sha256").update(supplied, "utf8").digest();
  const expectedDigest = createHash("sha256").update(String(expectedToken), "utf8").digest();
  return timingSafeEqual(suppliedDigest, expectedDigest) && supplied.length === String(expectedToken).length;
}
