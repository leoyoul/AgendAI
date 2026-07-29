import { readFile } from "node:fs/promises";
import path from "node:path";

import { AgentError } from "../errors.mjs";
import { publishResultPackage } from "../result_package.mjs";

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;");
}

function textWithBreaks(value) {
  return escapeHtml(value).replaceAll("\n", "<br>");
}

export async function executeMockProvider({ job, jobRoot }) {
  const request = JSON.parse(await readFile(path.join(job.input_path, "request.json"), "utf8"));
  if (request.request_id !== job.job_id || request.meeting.id !== job.meeting_id) {
    throw new AgentError("PROVIDER_FAILED", "Mock Provider 输入身份不匹配", { status: 500 });
  }
  const participants = request.meeting.participants.length > 0
    ? request.meeting.participants.map((participant) => escapeHtml(participant.name)).join("、")
    : "待确认";
  const goal = request.analysis.goal.trim()
    ? textWithBreaks(request.analysis.goal)
    : "未指定额外分析目标。";
  const reportHtml = `<!doctype html>
<html lang="${escapeHtml(request.output.locale)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(request.meeting.title || "会议纪要")}</title>
</head>
<body>
  <main>
    <h1>${escapeHtml(request.meeting.title || "会议纪要")}</h1>
    <section id="formal-minutes">
      <h2>正式纪要</h2>
      <dl>
        <dt>会议时间</dt><dd>${escapeHtml(request.meeting.started_at)} - ${escapeHtml(request.meeting.ended_at)}</dd>
        <dt>参会人</dt><dd>${participants}</dd>
      </dl>
      <h3>会议记录</h3>
      <p>${textWithBreaks(request.transcript.plain_text || "无转写内容")}</p>
    </section>
    <section id="intelligent-analysis">
      <h2>智能分析</h2>
      <p>${goal}</p>
      <p>Mock Provider 仅验证会议 Agent 链路，不引入外部事实或推测。</p>
    </section>
  </main>
</body>
</html>
`;
  const todos = {
    schema_version: "1.0",
    job_id: job.job_id,
    meeting_id: job.meeting_id,
    items: [],
  };
  return publishResultPackage({
    jobRoot,
    request,
    requestHash: job.request_hash,
    provider: { name: "mock", run_id: `mock-${job.job_id}` },
    generatedAt: request.meeting.ended_at,
    reportHtml,
    todos,
  });
}
