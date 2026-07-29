import { lstat } from "node:fs/promises";
import path from "node:path";

import { DEFAULT_PROVIDER_TIMEOUT_MS, DEFAULT_SHUTDOWN_TIMEOUT_MS } from "./config.mjs";
import { AgentError } from "./errors.mjs";
import { executeMockProvider } from "./providers/mock_provider.mjs";
import { removeStaleResultStaging, verifyResultPackage } from "./result_package.mjs";

const STABLE_PROVIDER_ERROR_CODES = new Set([
  "PROVIDER_FAILED",
  "PROVIDER_PROTOCOL_UNSUPPORTED",
  "RESULT_INVALID",
  "RESULT_CONFLICT",
]);

class RunnerStoppedError extends Error {
  constructor() {
    super("Runner 正在停止");
    this.name = "RunnerStoppedError";
  }
}

function waitForAbort(promise, signal) {
  if (signal.aborted) return Promise.reject(signal.reason);
  let onAbort;
  const aborted = new Promise((_resolve, reject) => {
    onAbort = () => reject(signal.reason);
    signal.addEventListener("abort", onAbort, { once: true });
  });
  return Promise.race([promise, aborted]).finally(() => signal.removeEventListener("abort", onAbort));
}

export class Runner {
  #activePromise = null;
  #currentAbortController = null;
  #started = false;
  #timer = null;

  constructor({
    jobStore,
    jobsRoot,
    provider,
    pollIntervalMs = 100,
    executionTimeoutMs = DEFAULT_PROVIDER_TIMEOUT_MS,
    shutdownTimeoutMs = DEFAULT_SHUTDOWN_TIMEOUT_MS,
    onInfrastructureError,
  }) {
    this.jobStore = jobStore;
    this.jobsRoot = jobsRoot;
    this.provider = provider ?? executeMockProvider;
    this.pollIntervalMs = pollIntervalMs;
    this.executionTimeoutMs = executionTimeoutMs;
    this.shutdownTimeoutMs = shutdownTimeoutMs;
    this.onInfrastructureError = onInfrastructureError ?? ((error) => {
      process.stderr.write(`tinglan-agentd Runner 基础设施错误：${error.stack || error}\n`);
    });
  }

  start() {
    if (this.#started) return;
    this.#started = true;
    this.#timer = setInterval(() => this.poke(), this.pollIntervalMs);
    this.#timer.unref();
    this.poke();
  }

  poke() {
    if (!this.#started || this.#activePromise) return;
    const active = this.#drain().catch((error) => this.#reportInfrastructureError(error));
    this.#activePromise = active.finally(() => {
      this.#activePromise = null;
    });
  }

  #reportInfrastructureError(error) {
    try {
      this.onInfrastructureError(error);
    } catch (callbackError) {
      process.stderr.write(`tinglan-agentd 基础设施错误回调失败：${callbackError.stack || callbackError}\n`);
    }
  }

  async #drain() {
    while (this.#started) {
      let job;
      try {
        job = this.jobStore.claimNext();
      } catch (error) {
        this.#reportInfrastructureError(error);
        return;
      }
      if (!job) return;
      await this.#runJob(job);
    }
  }

  async #runJob(job) {
    const jobRoot = path.join(this.jobsRoot, job.job_id);
    const outputPath = path.join(jobRoot, "output");
    let outputExists = false;
    try {
      await lstat(outputPath);
      outputExists = true;
    } catch (error) {
      if (error.code !== "ENOENT") {
        this.#reportInfrastructureError(error);
        return;
      }
    }

    if (outputExists) {
      try {
        await verifyResultPackage(outputPath, job);
        this.#markSucceeded(job, outputPath);
      } catch (error) {
        this.#markFailed(job, error instanceof AgentError ? error : new AgentError("RESULT_INVALID", "已有结果包无效", { status: 500, cause: error }));
      }
      return;
    }

    try {
      await removeStaleResultStaging(jobRoot);
    } catch (error) {
      this.#reportInfrastructureError(error);
      return;
    }

    const controller = new AbortController();
    this.#currentAbortController = controller;
    const timeout = setTimeout(() => {
      controller.abort(new AgentError("PROVIDER_FAILED", "Provider 执行超时", { status: 500 }));
    }, this.executionTimeoutMs);
    timeout.unref();
    try {
      const providerPromise = Promise.resolve().then(() => this.provider({ job, jobRoot, signal: controller.signal }));
      const result = await waitForAbort(providerPromise, controller.signal);
      if (!result?.outputPath || path.resolve(result.outputPath) !== outputPath) {
        throw new AgentError("RESULT_INVALID", "Provider 返回的 output 路径无效", { status: 500 });
      }
      await verifyResultPackage(result.outputPath, job);
      this.#markSucceeded(job, result.outputPath);
    } catch (error) {
      if (error instanceof RunnerStoppedError) return;
      this.#markFailed(job, error);
    } finally {
      clearTimeout(timeout);
      if (this.#currentAbortController === controller) this.#currentAbortController = null;
    }
  }

  #markSucceeded(job, outputPath) {
    try {
      this.jobStore.markSucceeded(job.job_id, outputPath);
    } catch (error) {
      this.#reportInfrastructureError(error);
    }
  }

  #markFailed(job, error) {
    const code = error instanceof AgentError && STABLE_PROVIDER_ERROR_CODES.has(error.code)
      ? error.code
      : "PROVIDER_FAILED";
    const message = error?.message || "Provider 执行失败";
    try {
      this.jobStore.markFailed(job.job_id, code, message);
    } catch (markError) {
      this.#reportInfrastructureError(markError);
    }
  }

  async stop() {
    this.#started = false;
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = null;
    this.#currentAbortController?.abort(new RunnerStoppedError());
    if (!this.#activePromise) return;
    let deadline;
    try {
      await Promise.race([
        this.#activePromise,
        new Promise((resolve) => { deadline = setTimeout(resolve, this.shutdownTimeoutMs); }),
      ]);
    } finally {
      if (deadline) clearTimeout(deadline);
    }
  }
}
