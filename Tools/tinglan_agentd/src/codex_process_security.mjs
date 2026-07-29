import { realpathSync } from "node:fs";
import { chmod, copyFile, lstat, mkdir, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export const CODEX_PERMISSION_PROFILE = "tinglan_agent";

const SENSITIVE_ENVIRONMENT_NAME = /(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH)/i;

function schemeString(value) {
  return `"${String(value).replaceAll("\\", "\\\\").replaceAll("\"", "\\\"")}"`;
}

export function sanitizedCodexEnvironment(environment = process.env) {
  return Object.fromEntries(Object.entries(environment).filter(([key]) => {
    if (key === "TINGLAN_AGENT_FORBIDDEN_PATHS") return false;
    if (key.startsWith("TINGLAN_AGENT_")) return false;
    if (/^TINGLAN_(?:DB|DATABASE|SQLITE)(?:_|$)/.test(key)) return false;
    return !SENSITIVE_ENVIRONMENT_NAME.test(key);
  }));
}

function tomlString(value) {
  return JSON.stringify(String(value));
}

function tomlInlineTable(entries) {
  return `{${entries.map(([key, value]) => `${tomlString(key)}=${value}`).join(",")}}`;
}

function canonicalPath(value) {
  try {
    return realpathSync.native(value);
  } catch {
    return path.resolve(value);
  }
}

export async function createCodexHomeOverlay({ sourceCodexHome, workspaceRoot } = {}) {
  if (typeof sourceCodexHome !== "string" || !path.isAbsolute(sourceCodexHome)) {
    throw new Error("Codex 源 CODEX_HOME 必须是绝对路径");
  }
  if (typeof workspaceRoot !== "string" || !path.isAbsolute(workspaceRoot)) {
    throw new Error("Codex workspaceRoot 必须是绝对路径");
  }
  const overlayPath = path.join(workspaceRoot, ".codex-home");
  await mkdir(overlayPath, { recursive: true, mode: 0o700 });

  for (const fileName of ["config.toml", "auth.json"]) {
    const sourcePath = path.join(sourceCodexHome, fileName);
    const destinationPath = path.join(overlayPath, fileName);
    let info;
    try {
      info = await lstat(sourcePath);
    } catch (error) {
      if (error.code === "ENOENT" && fileName === "auth.json") continue;
      throw error;
    }
    if (!info.isFile() || info.isSymbolicLink()) {
      throw new Error(`Codex ${fileName} 必须是普通文件且不能是符号链接`);
    }
    await copyFile(sourcePath, destinationPath);
    await chmod(destinationPath, fileName === "auth.json" ? 0o600 : 0o600);
  }

  for (const directoryName of ["skills", "plugins", "memories", "automations"]) {
    const sourcePath = path.join(sourceCodexHome, directoryName);
    const destinationPath = path.join(overlayPath, directoryName);
    try {
      const info = await lstat(sourcePath);
      if (!info.isDirectory() || info.isSymbolicLink()) continue;
      await symlink(sourcePath, destinationPath, "dir");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  return overlayPath;
}

export function buildCodexConfigOverrides({
  workspaceRoot,
  codexHome,
  forbiddenPaths = [],
  home = os.homedir(),
  permissionProfile = CODEX_PERMISSION_PROFILE,
  sourceCodexHome = null,
} = {}) {
  if (typeof workspaceRoot !== "string" || !path.isAbsolute(workspaceRoot)) {
    throw new Error("Codex workspaceRoot 必须是绝对路径");
  }
  if (typeof codexHome !== "string" || !path.isAbsolute(codexHome)) {
    throw new Error("Codex CODEX_HOME 必须是绝对路径");
  }
  if (!/^[a-z][a-z0-9_]*$/.test(permissionProfile)) {
    throw new Error("Codex permission profile 名称无效");
  }

  const workspacePath = path.resolve(workspaceRoot);
  const trustedWorkspace = canonicalPath(workspaceRoot);
  const workspaceRules = tomlInlineTable([
    [".", tomlString("write")],
    ["**/*.env", tomlString("deny")],
    ["**/.env*", tomlString("deny")],
  ]);
  const filesystemEntries = new Map([
    [":minimal", tomlString("read")],
    [":workspace_roots", workspaceRules],
    [workspacePath, tomlString("write")],
    [path.join(workspacePath, "**/*.env"), tomlString("deny")],
    [path.join(workspacePath, "**/.env*"), tomlString("deny")],
    [codexHome, tomlString("deny")],
    [path.join(codexHome, "skills"), tomlString("read")],
    [path.join(codexHome, "plugins"), tomlString("read")],
    [path.join(codexHome, "memories"), tomlString("read")],
    [path.join(home, ".agents", "skills"), tomlString("read")],
    [path.join(home, ".ssh"), tomlString("deny")],
    [path.join(home, "Library", "Keychains"), tomlString("deny")],
    [path.join(home, "Library", "Application Support", "会小纪"), tomlString("deny")],
    [path.join(home, "Library", "Application Support", "会小纪 Agent"), tomlString("deny")],
  ]);
  if (trustedWorkspace !== workspacePath) {
    filesystemEntries.set(trustedWorkspace, tomlString("write"));
    filesystemEntries.set(path.join(trustedWorkspace, "**/*.env"), tomlString("deny"));
    filesystemEntries.set(path.join(trustedWorkspace, "**/.env*"), tomlString("deny"));
  }
  if (sourceCodexHome && path.isAbsolute(sourceCodexHome) && path.resolve(sourceCodexHome) !== path.resolve(codexHome)) {
    filesystemEntries.set(path.resolve(sourceCodexHome), tomlString("deny"));
    for (const directoryName of ["skills", "plugins", "memories", "automations"]) {
      filesystemEntries.set(path.join(sourceCodexHome, directoryName), tomlString("read"));
    }
  }
  for (const forbiddenPath of forbiddenPaths) {
    if (typeof forbiddenPath !== "string" || !path.isAbsolute(forbiddenPath)) {
      throw new Error("Codex 禁止访问路径必须是绝对路径");
    }
    filesystemEntries.set(path.resolve(forbiddenPath), tomlString("deny"));
  }

  const profileKey = `permissions.${permissionProfile}`;
  return [
    `projects.${tomlString(trustedWorkspace)}.trust_level=${tomlString("trusted")}`,
    "notify=[]",
    `default_permissions=${tomlString(permissionProfile)}`,
    `${profileKey}.workspace_roots=${tomlInlineTable([[trustedWorkspace, "true"]])}`,
    `${profileKey}.filesystem=${tomlInlineTable([...filesystemEntries])}`,
    `${profileKey}.network.enabled=true`,
    `${profileKey}.network.mode=${tomlString("full")}`,
    `${profileKey}.network.allow_local_binding=false`,
    `shell_environment_policy.inherit=${tomlString("core")}`,
    "shell_environment_policy.ignore_default_excludes=false",
    `shell_environment_policy.exclude=${JSON.stringify(["*KEY*", "*TOKEN*", "*SECRET*", "*PASSWORD*", "TINGLAN_*"])}`,
    `history.persistence=${tomlString("none")}`,
    `otel.exporter=${tomlString("none")}`,
    `web_search=${tomlString("live")}`,
    "analytics.enabled=false",
    "feedback.enabled=false",
    "features.hooks=false",
    "features.apps=false",
    "features.multi_agent=false",
    "mcp_servers={}",
  ];
}

export function buildCodexLaunch({
  codexBin,
  forbiddenPaths = [],
  environment = process.env,
  workspaceRoot,
  codexHome = environment.CODEX_HOME || path.join(environment.HOME || os.homedir(), ".codex"),
  permissionProfile = CODEX_PERMISSION_PROFILE,
  sourceCodexHome = null,
  appServerArgs = ["app-server", "--listen", "stdio://"],
}) {
  const configArgs = buildCodexConfigOverrides({
    workspaceRoot,
    codexHome,
    forbiddenPaths,
    home: environment.HOME || os.homedir(),
    permissionProfile,
    sourceCodexHome,
  }).flatMap((entry) => ["-c", entry]);
  const codexArgs = [...configArgs, ...appServerArgs];
  const env = sanitizedCodexEnvironment(environment);
  return { command: codexBin, args: codexArgs, env };
}
