import { createHash } from "node:crypto";

function normalizedString(value) {
  return String(value ?? "")
    .normalize("NFC")
    .replace(/\r\n?/g, "\n")
    .trim();
}

function integer(value) {
  const result = Number(value ?? 0);
  return Number.isFinite(result) ? Math.trunc(result) : 0;
}

export function finalSegmentText(segment) {
  for (const value of [segment.final_text, segment.processed_text, segment.raw_text]) {
    const text = normalizedString(value);
    if (text) return text;
  }
  return "";
}

export function finalSpeakerName(segment) {
  return normalizedString(segment.person_name) || normalizedString(segment.speaker_label);
}

export function normalizeSegments(segments) {
  return segments
    .map((segment) => ({
      segment_id: normalizedString(segment.id ?? segment.segment_id),
      start_ms: integer(segment.start_ms),
      end_ms: integer(segment.end_ms),
      speaker: finalSpeakerName(segment),
      text: finalSegmentText(segment),
    }))
    .sort(
      (left, right) =>
        left.start_ms - right.start_ms ||
        left.end_ms - right.end_ms ||
        left.segment_id.localeCompare(right.segment_id, "en"),
    );
}

export function normalizeMeetingContent(meeting, segments) {
  return {
    meeting_id: normalizedString(meeting.id ?? meeting.meeting_id),
    title: normalizedString(meeting.title),
    started_at: meeting.started_at == null ? null : Number(meeting.started_at),
    ended_at: meeting.ended_at == null ? null : Number(meeting.ended_at),
    segments: normalizeSegments(segments),
  };
}

export function contentHash(meeting, segments) {
  const normalized = normalizeMeetingContent(meeting, segments);
  return createHash("sha256").update(JSON.stringify(normalized), "utf8").digest("hex");
}

export function sha256(value) {
  return createHash("sha256").update(String(value), "utf8").digest("hex");
}
