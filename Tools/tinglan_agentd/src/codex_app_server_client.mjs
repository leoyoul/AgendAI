import { spawn } from "node:child_process";
import path from "node:path";
import readline from "node:readline";

import { AgentError } from "./errors.mjs";

const DEFAULT_HANDSHAKE_TIMEOUT_MS = 15_000;
const DEFAULT_TURN_TIMEOUT_MS = 10 * 60 * 1_000;
const DEFAULT_STDERR_LIMIT_BYTES = 64 * 1_024;

function providerError(message, { cause, details = [] } = {}) {
  return new AgentError("PROVIDER_FAILED", message, { status: 500, cause, details });
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function positiveTimeout(value, fallback, name) {
  const timeout = value ?? fallback;
  if (!Number.isSafeInteger(timeout) || timeout <= 0) {
    throw providerError(`${name} 必须是正安全整数`);
  }
  return timeout;
}

function validateOptions(options) {
  if (!options || typeof options !== "object") throw providerError("App Server 客户端参数无效");
  if (typeof options.codexBin !== "string" || options.codexBin.length === 0) {
    throw providerError("Codex 二进制路径不能为空");
  }
  if (typeof options.cwd !== "string" || !path.isAbsolute(options.cwd)) {
    throw providerError("Codex 工作目录必须是绝对路径");
  }
  if (typeof options.prompt !== "string" || options.prompt.length === 0) {
    throw providerError("Codex turn prompt 不能为空");
  }
  if (!options.outputSchema || typeof options.outputSchema !== "object" || Array.isArray(options.outputSchema)) {
    throw providerError("Codex turn outputSchema 必须是 JSON Schema 对象");
  }
  const roots = options.runtimeWorkspaceRoots ?? [options.cwd];
  if (!Array.isArray(roots) || roots.length === 0 || roots.some((root) => typeof root !== "string" || !path.isAbsolute(root))) {
    throw providerError("Codex runtimeWorkspaceRoots 必须是非空绝对路径数组");
  }
  if (options.permissionsProfile !== undefined
    && (typeof options.permissionsProfile !== "string" || !/^[a-z][a-z0-9_]*$/.test(options.permissionsProfile))) {
    throw providerError("Codex permissionsProfile 名称无效");
  }
  return {
    runtimeWorkspaceRoots: roots.map((root) => path.resolve(root)),
    permissionsProfile: options.permissionsProfile ?? null,
  };
}

function lastAgentMessage(turn) {
  if (!Array.isArray(turn?.items)) return null;
  for (let index = turn.items.length - 1; index >= 0; index -= 1) {
    const item = turn.items[index];
    if (item?.type === "agentMessage" && typeof item.text === "string") return item.text;
  }
  return null;
}

function safeTurnFailureDetails(turn, turnStatus) {
  const details = [`turn_status=${turnStatus}`];
  const message = typeof turn?.error?.message === "string" ? turn.error.message : "";
  const statusMatch = message.match(/(?:unexpected status|status)\s+(\d{3})\b/i);
  if (statusMatch) details.push(`upstream_http_status=${statusMatch[1]}`);
  const errorCodeMatch = message.match(/(?:auth error code|error code)[:=]\s*([a-z][a-z0-9_-]{0,63})/i);
  if (errorCodeMatch) details.push(`upstream_error_code=${errorCodeMatch[1].toLowerCase()}`);
  if (/invalid[_ ]api[_ ]key/i.test(message) && !details.includes("upstream_error_code=invalid_api_key")) {
    details.push("upstream_error_code=invalid_api_key");
  }
  return details;
}

/**
 * Runs one isolated Codex App Server thread and turn over JSONL stdio.
 */
export async function runCodexAppServerTurn(options) {
  const { runtimeWorkspaceRoots, permissionsProfile } = validateOptions(options);
  const cwd = path.resolve(options.cwd);
  const handshakeTimeoutMs = positiveTimeout(
    options.handshakeTimeoutMs,
    DEFAULT_HANDSHAKE_TIMEOUT_MS,
    "handshakeTimeoutMs",
  );
  const turnTimeoutMs = positiveTimeout(options.turnTimeoutMs, DEFAULT_TURN_TIMEOUT_MS, "turnTimeoutMs");
  const stderrLimitBytes = positiveTimeout(
    options.stderrLimitBytes,
    DEFAULT_STDERR_LIMIT_BYTES,
    "stderrLimitBytes",
  );
  if (options.signal?.aborted) throw providerError("Codex App Server 执行已取消");

  let child;
  try {
    child = spawn(options.codexBin, options.appServerArgs ?? ["app-server"], {
      cwd,
      env: options.env === undefined ? process.env : { ...options.env },
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (error) {
    throw providerError("Codex App Server 启动失败", { cause: error });
  }

  let intentionalShutdown = false;
  let fatalError = null;
  let nextId = 1;
  let stderr = Buffer.alloc(0);
  let stderrTruncated = false;
  const pending = new Map();
  const completion = deferred();
  // This promise may be rejected before a completion waiter is installed.
  completion.promise.catch(() => {});
  const queuedCompletions = [];
  const agentMessageDeltas = new Map();
  const completedAgentMessages = [];
  let expectedCompletion = null;
  let activeThreadId = null;
  let activeTurnId = null;
  let turnCompleted = false;
  let latestThreadSettings = null;

  const exitState = deferred();
  child.once("exit", (code, signal) => exitState.resolve({ code, signal }));

  function stderrDetails() {
    const details = [];
    if (stderr.length > 0) details.push(`stderr=${stderr.toString("utf8")}`);
    if (stderrTruncated) details.push("stderr_truncated=true");
    return details;
  }

  function sendRaw(message, { ignoreErrors = false } = {}) {
    if (child.stdin.destroyed || child.exitCode !== null || child.signalCode !== null) return;
    child.stdin.write(`${JSON.stringify(message)}\n`, (error) => {
      if (error && !ignoreErrors) fail(providerError("Codex App Server stdin 写入失败", { cause: error }));
    });
  }

  function interruptActiveTurn() {
    if (!activeThreadId || !activeTurnId || turnCompleted) return;
    const id = nextId;
    nextId += 1;
    sendRaw({
      method: "turn/interrupt",
      id,
      params: { threadId: activeThreadId, turnId: activeTurnId },
    }, { ignoreErrors: true });
    activeTurnId = null;
  }

  function fail(error) {
    if (fatalError) return;
    interruptActiveTurn();
    fatalError = error instanceof AgentError
      ? error
      : providerError("Codex App Server 执行失败", { cause: error });
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(fatalError);
    }
    pending.clear();
    completion.reject(fatalError);
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  }

  child.stderr.on("data", (chunk) => {
    const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const remaining = stderrLimitBytes - stderr.length;
    if (remaining > 0) stderr = Buffer.concat([stderr, data.subarray(0, remaining)]);
    if (data.length > remaining) stderrTruncated = true;
  });

  child.once("error", (error) => {
    fail(providerError("Codex App Server 启动失败", { cause: error }));
  });

  child.on("close", (code, signal) => {
    if (intentionalShutdown || fatalError) return;
    fail(providerError("Codex App Server 进程提前退出", {
      details: [`exit_code=${code ?? "null"}`, `signal=${signal ?? "null"}`, ...stderrDetails()],
    }));
  });

  function handleCompletion(params) {
    if (!params || typeof params.threadId !== "string" || typeof params.turn?.id !== "string") {
      fail(providerError("Codex App Server turn/completed 通知无效"));
      return;
    }
    if (!expectedCompletion) {
      queuedCompletions.push(params);
      return;
    }
    if (params.threadId === expectedCompletion.threadId && params.turn.id === expectedCompletion.turnId) {
      completion.resolve(params.turn);
    }
  }

  function agentMessageKey(params) {
    return `${params.threadId}\u0000${params.turnId}\u0000${params.itemId}`;
  }

  function recordAgentMessageDelta(params) {
    if (!params
      || typeof params.threadId !== "string"
      || typeof params.turnId !== "string"
      || typeof params.itemId !== "string"
      || typeof params.delta !== "string") return;
    const key = agentMessageKey(params);
    agentMessageDeltas.set(key, `${agentMessageDeltas.get(key) ?? ""}${params.delta}`);
  }

  function recordCompletedItem(params) {
    const item = params?.item;
    if (typeof params?.threadId !== "string"
      || typeof params?.turnId !== "string"
      || item?.type !== "agentMessage"
      || typeof item.id !== "string"
      || typeof item.text !== "string") return;
    completedAgentMessages.push({
      threadId: params.threadId,
      turnId: params.turnId,
      itemId: item.id,
      phase: item.phase ?? null,
      text: item.text,
    });
  }

  function finalAgentMessageFromNotifications(threadId, turnId) {
    const completed = completedAgentMessages.filter(
      (message) => message.threadId === threadId && message.turnId === turnId,
    );
    const finalAnswer = completed.findLast((message) => message.phase === "final_answer");
    if (finalAnswer) return finalAnswer.text;
    const compatibleAnswer = completed.findLast((message) => message.phase !== "commentary");
    if (compatibleAnswer) return compatibleAnswer.text;
    if (completed.length > 0) return completed.at(-1).text;

    const prefix = `${threadId}\u0000${turnId}\u0000`;
    const streamed = [...agentMessageDeltas.entries()].filter(([key]) => key.startsWith(prefix));
    return streamed.length > 0 ? streamed.at(-1)[1] : null;
  }

  const lines = readline.createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      fail(providerError("Codex App Server 返回了无效 JSON", { cause: error }));
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      fail(providerError("Codex App Server 返回了无效 JSON-RPC 消息"));
      return;
    }

    if (Object.hasOwn(message, "id") && typeof message.method === "string") {
      const cancellationResults = {
        "item/commandExecution/requestApproval": { decision: "cancel" },
        "item/fileChange/requestApproval": { decision: "cancel" },
        "mcpServer/elicitation/request": { action: "cancel" },
        applyPatchApproval: { decision: "abort" },
        execCommandApproval: { decision: "abort" },
      };
      const result = cancellationResults[message.method];
      if (result) sendRaw({ id: message.id, result }, { ignoreErrors: true });
      else sendRaw({
        id: message.id,
        error: { code: -32000, message: "tinglan_agentd does not service interactive server requests" },
      }, { ignoreErrors: true });
      fail(providerError(`Codex App Server 请求了不允许的交互：${message.method}`));
      return;
    }

    if (Object.hasOwn(message, "id")) {
      const request = pending.get(message.id);
      if (!request) {
        fail(providerError("Codex App Server 返回了未知 JSON-RPC id"));
        return;
      }
      pending.delete(message.id);
      clearTimeout(request.timer);
      if (message.error) {
        const rpcCode = message.error.code ?? "unknown";
        const rpcMessage = typeof message.error.message === "string" ? message.error.message : "unknown";
        request.reject(providerError(`Codex JSON-RPC ${request.method} 失败：${rpcMessage}`, {
          details: [`rpc_code=${rpcCode}`],
        }));
      } else if (Object.hasOwn(message, "result")) {
        request.resolve(message.result);
      } else {
        request.reject(providerError(`Codex JSON-RPC ${request.method} 响应无效`));
      }
      return;
    }

    options.onNotification?.({ method: message.method, params: message.params });

    if (message.method === "turn/completed") {
      handleCompletion(message.params);
      return;
    }
    if (message.method === "item/agentMessage/delta") {
      recordAgentMessageDelta(message.params);
      return;
    }
    if (message.method === "item/completed") {
      recordCompletedItem(message.params);
      return;
    }
    if (message.method === "thread/settings/updated") {
      latestThreadSettings = message.params?.settings ?? null;
      return;
    }
    if (typeof message.method !== "string") {
      fail(providerError("Codex App Server 返回了无效 JSON-RPC 消息"));
    }
  });

  function send(message) {
    if (fatalError) throw fatalError;
    sendRaw(message);
  }

  function request(method, params, timeoutMessage) {
    if (fatalError) return Promise.reject(fatalError);
    const id = nextId;
    nextId += 1;
    const pendingRequest = deferred();
    pendingRequest.promise.catch(() => {});
    const timer = setTimeout(() => {
      const error = providerError(timeoutMessage);
      fail(error);
    }, handshakeTimeoutMs);
    pending.set(id, { ...pendingRequest, method, timer });
    try {
      send({ method, id, params });
    } catch (error) {
      clearTimeout(timer);
      pending.delete(id);
      pendingRequest.reject(error);
    }
    return pendingRequest.promise;
  }

  const onAbort = () => fail(providerError("Codex App Server 执行已取消"));
  options.signal?.addEventListener("abort", onAbort, { once: true });

  async function shutdown() {
    intentionalShutdown = true;
    options.signal?.removeEventListener("abort", onAbort);
    interruptActiveTurn();
    lines.close();
    if (!child.stdin.destroyed) child.stdin.end();
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    await Promise.race([
      exitState.promise,
      new Promise((resolve) => setTimeout(resolve, 250)),
    ]);
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  }

  try {
    const initializeResult = await request("initialize", {
      capabilities: {
        experimentalApi: false,
        mcpServerOpenaiFormElicitation: false,
        requestAttestation: false,
      },
      clientInfo: {
        name: "agendai_agentd",
        title: "AgendAI Meeting Agent",
        version: "0.1.0",
      },
    }, "Codex App Server 初始化握手超时");

    if (typeof initializeResult?.codexHome !== "string" || !path.isAbsolute(initializeResult.codexHome)
      || typeof initializeResult?.platformFamily !== "string" || initializeResult.platformFamily.length === 0
      || typeof initializeResult?.platformOs !== "string" || initializeResult.platformOs.length === 0
      || typeof initializeResult?.userAgent !== "string" || initializeResult.userAgent.length === 0) {
      throw providerError("Codex App Server initialize 响应字段无效");
    }

    send({ method: "initialized", params: {} });

    if (permissionsProfile) {
      const configResult = await request(
        "config/read",
        { cwd, includeLayers: false },
        "Codex App Server config/read 握手超时",
      );
      if (configResult?.config?.sandbox_mode !== null && configResult?.config?.sandbox_mode !== undefined) {
        throw providerError("Codex 仍启用了旧 sandbox_mode，命名权限配置未生效");
      }
      const profiles = await request(
        "permissionProfile/list",
        { cwd },
        "Codex App Server permissionProfile/list 握手超时",
      );
      const selected = profiles?.data?.find((profile) => profile?.id === permissionsProfile);
      if (!selected || selected.allowed !== true) {
        throw providerError(`Codex 命名权限配置不可用：${permissionsProfile}`);
      }
    }

    const threadParams = {
      approvalPolicy: "never",
      cwd,
      ephemeral: true,
    };
    if (!permissionsProfile) {
      threadParams.runtimeWorkspaceRoots = runtimeWorkspaceRoots;
      threadParams.sandbox = "workspace-write";
    }
    if (typeof options.developerInstructions === "string") {
      threadParams.developerInstructions = options.developerInstructions;
    }
    if (typeof options.model === "string" && options.model.length > 0) threadParams.model = options.model;

    const threadResult = await request(
      "thread/start",
      threadParams,
      "Codex App Server thread/start 握手超时",
    );
    const threadId = threadResult?.thread?.id;
    if (typeof threadId !== "string" || threadId.length === 0) {
      throw providerError("Codex App Server thread/start 响应缺少 thread id");
    }
    if (threadResult.thread.ephemeral !== true) {
      throw providerError("Codex App Server 未创建 ephemeral thread");
    }
    if (typeof threadResult.cwd !== "string" || !path.isAbsolute(threadResult.cwd)
      || path.resolve(threadResult.cwd) !== cwd) {
      throw providerError("Codex App Server thread cwd 与隔离工作区不一致");
    }
    const activePermissionProfile = threadResult.activePermissionProfile
      ?? latestThreadSettings?.activePermissionProfile
      ?? null;
    if (permissionsProfile && activePermissionProfile && activePermissionProfile.id !== permissionsProfile) {
      throw providerError(`Codex 实际权限配置不匹配：${activePermissionProfile.id ?? "unknown"}`);
    }
    options.onThreadStarted?.({
      threadId,
      initializeResult,
      threadResult,
      activePermissionProfile,
    });
    activeThreadId = threadId;

    const turnParams = {
      threadId,
      input: [{ type: "text", text: options.prompt }],
      approvalPolicy: "never",
      cwd,
    };
    if (options.sendOutputSchema !== false) turnParams.outputSchema = options.outputSchema;
    if (!permissionsProfile) {
      turnParams.runtimeWorkspaceRoots = runtimeWorkspaceRoots;
      turnParams.sandboxPolicy = {
        type: "workspaceWrite",
        networkAccess: options.networkAccess ?? true,
        writableRoots: runtimeWorkspaceRoots,
      };
    }
    if (typeof options.model === "string" && options.model.length > 0) turnParams.model = options.model;
    if (typeof options.effort === "string" && options.effort.length > 0) turnParams.effort = options.effort;

    const turnResult = await request(
      "turn/start",
      turnParams,
      "Codex App Server turn/start 握手超时",
    );
    const turnId = turnResult?.turn?.id;
    if (typeof turnId !== "string" || turnId.length === 0) {
      throw providerError("Codex App Server turn/start 响应缺少 turn id");
    }
    activeTurnId = turnId;

    expectedCompletion = { threadId, turnId };
    for (const params of queuedCompletions) handleCompletion(params);
    const turnTimer = setTimeout(() => {
      fail(providerError("Codex App Server turn/completed 等待超时"));
    }, turnTimeoutMs);
    const turn = await completion.promise.finally(() => clearTimeout(turnTimer));
    turnCompleted = true;
    options.onTurnCompleted?.(turn);
    if (turn.status !== "completed") {
      const turnStatus = typeof turn.status === "string" && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(turn.status)
        ? turn.status
        : "unknown";
      throw providerError("Codex turn 未成功完成", { details: safeTurnFailureDetails(turn, turnStatus) });
    }
    const finalMessage = lastAgentMessage(turn) ?? finalAgentMessageFromNotifications(threadId, turnId);
    if (finalMessage === null) throw providerError("Codex turn 缺少最终 Agent 消息");

    return { threadId, turnId, turn, finalMessage, initializeResult };
  } catch (error) {
    throw error instanceof AgentError
      ? error
      : providerError("Codex App Server 执行失败", { cause: error, details: stderrDetails() });
  } finally {
    await shutdown();
  }
}
