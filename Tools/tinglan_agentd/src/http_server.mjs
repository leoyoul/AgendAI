import { createServer } from "node:http";

import { verifyBearerToken } from "./config.mjs";
import { AgentError } from "./errors.mjs";
import { receiveJobInput } from "./job_input.mjs";
import { verifyResultPackage } from "./result_package.mjs";

function sendJson(response, status, value, headers = {}) {
  const body = `${JSON.stringify(value)}\n`;
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    ...headers,
  });
  response.end(body);
}

function sendError(response, error) {
  const known = error instanceof AgentError;
  const status = known ? error.status : 500;
  const code = known ? error.code : "INTERNAL_ERROR";
  const message = known ? error.message : "Agent 内部错误";
  const headers = status === 401 ? { "www-authenticate": "Bearer" } : {};
  sendJson(response, status, { error: { code, message, details: known ? error.details : [] } }, headers);
}

async function readJsonBody(request, limit) {
  const contentLength = Number(request.headers["content-length"] ?? 0);
  if (Number.isFinite(contentLength) && contentLength > limit) {
    request.resume();
    throw new AgentError("PAYLOAD_TOO_LARGE", "JSON 请求体超过 20 MiB 限制", { status: 413 });
  }
  const chunks = [];
  let total = 0;
  let tooLarge = false;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > limit) {
      tooLarge = true;
      continue;
    }
    chunks.push(chunk);
  }
  if (tooLarge) throw new AgentError("PAYLOAD_TOO_LARGE", "JSON 请求体超过 20 MiB 限制", { status: 413 });
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch (cause) {
    throw new AgentError("INVALID_REQUEST", "请求 JSON 格式无效", { cause });
  }
}

function jobStatusResponse(job) {
  return {
    schema_version: "1.0",
    job_id: job.job_id,
    request_id: job.job_id,
    meeting_id: job.meeting_id,
    provider: job.provider,
    status: job.status,
    created_at: job.created_at,
    updated_at: job.updated_at,
    started_at: job.started_at,
    completed_at: job.completed_at,
    error: job.error_code ? { code: job.error_code, message: job.error_message ?? "" } : null,
  };
}

function parseJobRoute(pathname) {
  const match = pathname.match(/^\/v1\/jobs\/([^/]+)(\/result)?$/);
  if (!match) return null;
  try {
    return { jobId: decodeURIComponent(match[1]), result: Boolean(match[2]) };
  } catch {
    throw new AgentError("INVALID_REQUEST", "作业 ID 编码无效");
  }
}

export function createAgentHttpServer({ config, token, jobStore, runner, receiveJob = receiveJobInput }) {
  if (config.host !== "127.0.0.1") throw new Error("HTTP 服务只允许监听 127.0.0.1");
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://127.0.0.1");
      if (request.method === "GET" && url.pathname === "/healthz") {
        sendJson(response, 200, { status: "ok", service: "tinglan-agentd", protocol_version: "1.0" });
        return;
      }
      if (!verifyBearerToken(request.headers.authorization, token)) {
        throw new AgentError("AUTH_REQUIRED", "需要有效的本机 Bearer token", { status: 401 });
      }

      if (request.method === "POST" && url.pathname === "/v1/jobs") {
        const contentType = request.headers["content-type"] ?? "";
        if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
          request.resume();
          throw new AgentError("UNSUPPORTED_MEDIA_TYPE", "Content-Type 必须是 application/json", { status: 415 });
        }
        const requestBody = await readJsonBody(request, config.maxJsonBytes);
        const idempotencyKey = request.headers["idempotency-key"];
        if (typeof idempotencyKey !== "string" || idempotencyKey.length === 0 || idempotencyKey !== requestBody.request_id) {
          throw new AgentError("INVALID_REQUEST", "Idempotency-Key 必须存在且与 request_id 一致");
        }
        let accepted;
        try {
          accepted = await receiveJob({
            request: requestBody,
            jobsRoot: config.jobsRoot,
            jobStore,
            inputRoots: config.inputRoots,
            provider: config.provider,
            receiveLockTimeoutMs: config.receiveLockTimeoutMs,
          });
        } catch (error) {
          if (error instanceof AgentError) throw error;
          throw new AgentError("INTERNAL_ERROR", "接收作业输入失败", { status: 500, cause: error });
        }
        runner.poke();
        sendJson(response, 202, {
          schema_version: "1.0",
          job_id: accepted.job.job_id,
          request_id: accepted.job.job_id,
          status: accepted.job.status,
        });
        return;
      }

      const route = parseJobRoute(url.pathname);
      if (request.method === "GET" && route) {
        const job = jobStore.get(route.jobId);
        if (!job) throw new AgentError("JOB_NOT_FOUND", "作业不存在", { status: 404 });
        if (!route.result) {
          sendJson(response, 200, jobStatusResponse(job));
          return;
        }
        if (job.status !== "succeeded") {
          throw new AgentError("JOB_NOT_SUCCEEDED", "作业尚未成功完成", { status: 409 });
        }
        const verified = await verifyResultPackage(job.result_path, job);
        sendJson(response, 200, {
          schema_version: "1.0",
          job_id: job.job_id,
          request_id: job.job_id,
          meeting_id: job.meeting_id,
          request_hash: job.request_hash,
          provider: verified.manifest.provider,
          result_path: job.result_path,
          manifest_path: "manifest.json",
          manifest_sha256: verified.manifestSha256,
        });
        return;
      }
      throw new AgentError("JOB_NOT_FOUND", "接口或作业不存在", { status: 404 });
    } catch (error) {
      sendError(response, error);
    }
  });
  server.requestTimeout = config.requestTimeoutMs ?? 30_000;
  server.headersTimeout = config.headersTimeoutMs ?? 10_000;
  return server;
}
