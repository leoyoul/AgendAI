import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import test from "node:test";

import { computeRequestHash } from "../src/hash.mjs";
import { startAgentd } from "../src/index.mjs";
import { JobStore } from "../src/job_store.mjs";
import { makeRequest, makeTempDir, waitFor } from "./helpers.mjs";

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

test("进程：真实启动只绑定 loopback，恢复 running，且不读取会小纪 SQLite", async (t) => {
  const isolatedHome = await makeTempDir("tinglan-agentd-home-");
  const dataRoot = path.join(isolatedHome, "agent-data");
  const jobsRoot = path.join(dataRoot, "jobs");
  const request = makeRequest();
  const inputPath = path.join(jobsRoot, request.request_id, "input");
  await mkdir(inputPath, { recursive: true });
  await writeFile(path.join(inputPath, "request.json"), JSON.stringify(request));
  const store = new JobStore(path.join(dataRoot, "agent.sqlite"));
  store.createOrGet({
    requestId: request.request_id,
    requestHash: computeRequestHash(request),
    meetingId: request.meeting.id,
    provider: "mock",
    inputPath,
  });
  assert.equal(store.claimNext().status, "running");
  store.close();

  const port = await freePort();
  const invalidTinglanDB = path.join(isolatedHome, "must-not-exist", "ai-tingji.sqlite");
  const child = spawn(process.execPath, ["src/index.mjs"], {
    cwd: path.resolve(import.meta.dirname, ".."),
    env: {
      ...process.env,
      HOME: isolatedHome,
      TINGLAN_AGENT_DATA_ROOT: dataRoot,
      TINGLAN_AGENT_PORT: String(port),
      TINGLAN_DB_PATH: invalidTinglanDB,
      TINGLAN_AGENT_INPUT_ROOTS: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { output += chunk; });
  t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });

  const baseURL = `http://127.0.0.1:${port}`;
  await waitFor(async () => {
    try { return (await fetch(`${baseURL}/healthz`)).ok; } catch { return false; }
  }, 8000);
  assert.match(output, new RegExp(`127\\.0\\.0\\.1:${port}`));
  const token = (await readFile(path.join(dataRoot, "api-token"), "utf8")).trim();
  const finalStatus = await waitFor(async () => {
    const response = await fetch(`${baseURL}/v1/jobs/${request.request_id}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    const payload = await response.json();
    return payload.status === "succeeded" ? payload : null;
  }, 8000);
  assert.equal(finalStatus.status, "succeeded");
  child.kill("SIGTERM");
  const exitCode = await new Promise((resolve, reject) => {
    child.once("exit", resolve);
    child.once("error", reject);
  });
  assert.equal(exitCode, 0);
  await access(path.join(dataRoot, "agent.sqlite"));
  await assert.rejects(() => access(invalidTinglanDB));
  await assert.rejects(() => access(path.join(isolatedHome, "Library/Application Support/会小纪/ai-tingji.sqlite")));
});

test("进程：codex-app-server 配置接入真实 Runner 而非启动期占位失败", async (t) => {
  const isolatedHome = await makeTempDir("tinglan-agentd-codex-home-");
  const agentd = await startAgentd({
    ...process.env,
    HOME: isolatedHome,
    TINGLAN_AGENT_DATA_ROOT: path.join(isolatedHome, "agent-data"),
    TINGLAN_AGENT_PORT: "0",
    TINGLAN_AGENT_PROVIDER: "codex-app-server",
    TINGLAN_CODEX_BIN: "/bin/false",
  });
  t.after(() => agentd.stop());
  assert.equal(agentd.config.provider, "codex-app-server");
  assert.equal(agentd.runner.provider.name, "executeCodexAppServerProvider");
  assert.equal(agentd.server.address().address, "127.0.0.1");
  await agentd.stop();
});
