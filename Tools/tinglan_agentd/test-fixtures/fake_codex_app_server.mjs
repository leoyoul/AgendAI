import { appendFile } from "node:fs/promises";
import readline from "node:readline";

const mode = process.env.FAKE_CODEX_MODE || "success";
const capturePath = process.env.FAKE_CODEX_CAPTURE_PATH || "";
const input = readline.createInterface({ input: process.stdin });
let phase = "initialize";

async function capture(message) {
  if (capturePath) await appendFile(capturePath, `${JSON.stringify(message)}\n`);
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function failRequest(message, reason) {
  send({ id: message.id, error: { code: -32000, message: reason } });
}

async function handleLine(line) {
  const message = JSON.parse(line);
  await capture(message);

  if (mode === "timeout") return;
  if (mode === "bad-json") {
    process.stdout.write("{bad json\n");
    return;
  }
  if (mode === "exit") {
    process.exit(23);
  }
  if (mode === "stderr-exit") {
    process.stderr.write("x".repeat(256 * 1024), () => process.exit(24));
    return;
  }

  if (phase === "initialize") {
    if (message.method !== "initialize" || message.id === undefined) {
      failRequest(message, "expected initialize");
      return;
    }
    if (mode === "rpc-error") {
      send({ id: message.id, error: { code: 4100, message: "fake initialize rejected" } });
      return;
    }
    phase = "initialized";
    send({
      id: message.id,
      result: {
        userAgent: "fake-codex",
        codexHome: "/tmp/fake-codex-home",
        platformFamily: "unix",
        platformOs: "macos",
      },
    });
    return;
  }

  if (phase === "initialized") {
    if (message.method !== "initialized" || message.id !== undefined) {
      failRequest(message, "expected initialized notification");
      return;
    }
    phase = "ready";
    return;
  }

  if (phase === "ready" && message.method === "config/read") {
    phase = "permission-profile-list";
    send({ id: message.id, result: { config: { sandbox_mode: null }, origins: {} } });
    return;
  }

  if (phase === "permission-profile-list") {
    if (message.method !== "permissionProfile/list" || message.id === undefined) {
      failRequest(message, "expected permissionProfile/list");
      return;
    }
    phase = "ready";
    send({
      id: message.id,
      result: { data: [{ id: "tinglan_agent", allowed: true, description: "fake" }], nextCursor: null },
    });
    return;
  }

  if (phase === "ready") {
    if (message.method !== "thread/start" || message.id === undefined) {
      failRequest(message, "expected thread/start");
      return;
    }
    phase = "turn-start";
    send({
      id: message.id,
      result: {
        thread: { id: "thread-fake-1", ephemeral: true },
        approvalPolicy: "never",
        approvalsReviewer: "user",
        cwd: message.params.cwd,
        model: message.params.model || "fake-model",
        modelProvider: "fake",
        sandbox: { type: "workspaceWrite", writableRoots: message.params.runtimeWorkspaceRoots },
        activePermissionProfile: { id: "tinglan_agent", extends: null },
      },
    });
    return;
  }

  if (phase === "turn-start") {
    if (message.method !== "turn/start" || message.id === undefined) {
      failRequest(message, "expected turn/start");
      return;
    }
    phase = "completed";
    send({ id: message.id, result: { turn: { id: "turn-fake-1", status: "inProgress", items: [] } } });
    if (mode === "server-request") {
      phase = "server-request";
      queueMicrotask(() => send({
        id: "server-request-1",
        method: "item/commandExecution/requestApproval",
        params: { threadId: "thread-fake-1", turnId: "turn-fake-1", itemId: "item-1" },
      }));
      return;
    }
    if (mode === "turn-timeout") return;
    queueMicrotask(() => {
      if (mode === "notifications-only") {
        send({
          method: "item/agentMessage/delta",
          params: {
            threadId: "thread-fake-1",
            turnId: "turn-fake-1",
            itemId: "message-1",
            delta: "{\"completed\":",
          },
        });
        send({
          method: "item/completed",
          params: {
            threadId: "thread-fake-1",
            turnId: "turn-fake-1",
            completedAtMs: Date.now(),
            item: {
              id: "message-1",
              type: "agentMessage",
              phase: "final_answer",
              text: JSON.stringify({ completed: true }),
            },
          },
        });
      }
      send({
        method: "turn/completed",
        params: {
          threadId: "thread-fake-1",
          turn: {
            id: "turn-fake-1",
            status: mode === "turn-failed" ? "failed" : "completed",
            itemsView: mode === "notifications-only" ? "notLoaded" : "full",
            error: mode === "turn-failed" ? { message: "fake turn failed" } : null,
            items: mode === "turn-failed" || mode === "notifications-only" ? [] : [
              { id: "message-1", type: "agentMessage", text: JSON.stringify({ completed: true }) },
            ],
          },
        },
      });
    });
    return;
  }
}

let processing = Promise.resolve();
input.on("line", (line) => {
  processing = processing.then(() => handleLine(line));
});
