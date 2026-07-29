import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { ensureApiToken, loadConfig } from "./config.mjs";
import { createAgentHttpServer } from "./http_server.mjs";
import { cleanOrphanJobs } from "./job_input.mjs";
import { JobStore } from "./job_store.mjs";
import { createCodexAppServerProvider } from "./providers/codex_app_server_provider.mjs";
import { Runner } from "./runner.mjs";

export async function startAgentd(env = process.env) {
  const config = loadConfig(env);
  await mkdir(config.jobsRoot, { recursive: true, mode: 0o700 });
  const token = await ensureApiToken(config.tokenPath);
  const jobStore = new JobStore(config.databasePath);
  jobStore.recoverInterrupted();
  await cleanOrphanJobs({ jobsRoot: config.jobsRoot, jobStore });
  const provider = config.provider === "codex-app-server"
    ? createCodexAppServerProvider({
      codexBin: config.codexBin,
      codexHome: config.codexHome,
      model: config.codexModel,
      effort: config.codexEffort,
      handshakeTimeoutMs: config.codexHandshakeTimeoutMs,
      turnTimeoutMs: config.providerTimeoutMs,
      forbiddenPaths: config.codexForbiddenPaths,
      env,
    })
    : undefined;
  const runner = new Runner({
    jobStore,
    jobsRoot: config.jobsRoot,
    executionTimeoutMs: config.providerTimeoutMs,
    shutdownTimeoutMs: config.shutdownTimeoutMs,
    provider,
  });
  const server = createAgentHttpServer({ config, token, jobStore, runner });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.host, resolve);
  });
  const address = server.address();
  process.stdout.write(`tinglan-agentd listening on http://${config.host}:${address.port}\n`);
  runner.start();

  let stopped = false;
  return {
    config,
    server,
    runner,
    jobStore,
    async stop() {
      if (stopped) return;
      stopped = true;
      const serverClosed = new Promise((resolve) => server.close(() => resolve()));
      server.closeIdleConnections?.();
      await runner.stop();
      let deadline;
      await Promise.race([
        serverClosed,
        new Promise((resolve) => {
          deadline = setTimeout(() => {
            server.closeAllConnections?.();
            resolve();
          }, config.shutdownTimeoutMs);
        }),
      ]);
      if (deadline) clearTimeout(deadline);
      jobStore.close();
    },
  };
}

async function main() {
  const agentd = await startAgentd();
  const shutdown = async () => {
    try {
      await agentd.stop();
      process.exitCode = 0;
    } catch (error) {
      process.stderr.write(`${error.stack || error}\n`);
      process.exitCode = 1;
    }
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === fileURLToPath(new URL(`file://${process.argv[1]}`))) {
  main().catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  });
}
