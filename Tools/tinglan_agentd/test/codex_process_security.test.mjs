import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  CODEX_PERMISSION_PROFILE,
  buildCodexConfigOverrides,
  buildCodexLaunch,
  createCodexHomeOverlay,
  sanitizedCodexEnvironment,
} from "../src/codex_process_security.mjs";

test("Codex 安全：子进程环境不暴露会小纪数据库或 Agent 配置", () => {
  const env = sanitizedCodexEnvironment({
    HOME: "/tmp/home",
    CODEX_HOME: "/tmp/codex",
    OPENAI_API_KEY: "key",
    TINGLAN_DB_PATH: "/secret/app.sqlite",
    TINGLAN_DATABASE_URL: "/secret/other.sqlite",
    TINGLAN_AGENT_PORT: "18765",
    TINGLAN_AGENT_FORBIDDEN_PATHS: "/secret/app.sqlite",
  });
  assert.deepEqual(env, {
    HOME: "/tmp/home",
    CODEX_HOME: "/tmp/codex",
  });
});

test("Codex 安全：配置覆盖只加隔离策略并复用当前 Provider", () => {
  const overrides = buildCodexConfigOverrides({
    workspaceRoot: "/tmp/agent/jobs/job-1/work/run-1",
    codexHome: "/Users/test/.codex",
    home: "/Users/test",
    forbiddenPaths: ["/Users/test/Library/Application Support/会小纪/ai-tingji.sqlite"],
  });
  const rendered = overrides.join("\n");
  assert.doesNotMatch(rendered, /model_provider=/);
  assert.match(rendered, /projects\."\/tmp\/agent\/jobs\/job-1\/work\/run-1"\.trust_level="trusted"/);
  assert.match(rendered, /default_permissions="tinglan_agent"/);
  assert.match(rendered, /permissions\.tinglan_agent\.workspace_roots=\{"\/tmp\/agent\/jobs\/job-1\/work\/run-1"=true\}/);
  assert.match(rendered, /permissions\.tinglan_agent\.filesystem=/);
  assert.match(rendered, /":workspace_roots"=\{"\."="write"/);
  assert.match(rendered, /"\/tmp\/agent\/jobs\/job-1\/work\/run-1"="write"/);
  assert.match(rendered, /"\/tmp\/agent\/jobs\/job-1\/work\/run-1\/\*\*\/\.env\*"="deny"/);
  assert.match(rendered, /\/Users\/test\/\.codex\/skills"="read"/);
  assert.match(rendered, /会小纪\/ai-tingji\.sqlite"="deny"/);
  assert.match(rendered, /permissions\.tinglan_agent\.network\.allow_local_binding=false/);
  assert.match(rendered, /history\.persistence="none"/);
  assert.match(rendered, /features\.hooks=false/);
  assert.match(rendered, /mcp_servers=\{\}/);
  assert.equal(CODEX_PERMISSION_PROFILE, "tinglan_agent");
});

test("Codex 安全：运行副本复用配置和认证但不让 App Server 写回原 CODEX_HOME", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "tinglan-codex-home-overlay-"));
  const source = path.join(root, "source-codex-home");
  const workspace = path.join(root, "workspace");
  await mkdir(path.join(source, "skills", "demo"), { recursive: true });
  await mkdir(workspace, { recursive: true });
  await writeFile(path.join(source, "config.toml"), 'model_provider = "OpenAI"\n');
  await writeFile(path.join(source, "auth.json"), '{"OPENAI_API_KEY":"redacted-fixture"}\n', { mode: 0o600 });
  await writeFile(path.join(source, "skills", "demo", "SKILL.md"), "demo");
  const overlay = await createCodexHomeOverlay({ sourceCodexHome: source, workspaceRoot: workspace });
  t.after(() => rm(root, { recursive: true, force: true }));
  assert.equal(await readFile(path.join(overlay, "config.toml"), "utf8"), 'model_provider = "OpenAI"\n');
  assert.equal(await readFile(path.join(overlay, "auth.json"), "utf8"), '{"OPENAI_API_KEY":"redacted-fixture"}\n');
  assert.equal((await lstat(path.join(overlay, "skills"))).isSymbolicLink(), true);
  assert.equal((await lstat(path.join(overlay, "auth.json"))).mode & 0o777, 0o600);
  assert.equal(await readFile(path.join(source, "config.toml"), "utf8"), 'model_provider = "OpenAI"\n');
});

test("Codex 安全：真实 launch 无 shell 启动并使用命名权限配置", () => {
  const launch = buildCodexLaunch({
    codexBin: "/Applications/ChatGPT.app/Contents/Resources/codex",
    forbiddenPaths: ["/tmp/会小纪/ai-tingji.sqlite"],
    environment: { HOME: "/tmp/home", TINGLAN_DB_PATH: "/tmp/会小纪/ai-tingji.sqlite" },
    workspaceRoot: "/tmp/workspace",
    codexHome: "/tmp/home/.codex",
  });
  assert.equal(launch.command, "/Applications/ChatGPT.app/Contents/Resources/codex");
  assert.ok(launch.args.includes('default_permissions="tinglan_agent"'));
  assert.ok(launch.args.some((argument) => /会小纪\/ai-tingji\.sqlite.*deny/.test(argument)));
  assert.deepEqual(launch.args.slice(-3), ["app-server", "--listen", "stdio://"]);
  assert.equal(launch.env.TINGLAN_DB_PATH, undefined);
});
