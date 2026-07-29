import { createHash } from "node:crypto";
import { open } from "node:fs/promises";

function normalizeString(value) {
  return value.normalize("NFC").replace(/\r\n?/g, "\n");
}

function compareUtf8(left, right) {
  return Buffer.compare(Buffer.from(String(left), "utf8"), Buffer.from(String(right), "utf8"));
}

function normalizeValue(value, key = "") {
  if (typeof value === "string") return normalizeString(value);
  if (Array.isArray(value)) {
    const normalized = value.map((item) => normalizeValue(item));
    if (key === "segments") {
      normalized.sort((left, right) => left.start_ms - right.start_ms || left.end_ms - right.end_ms || compareUtf8(left.id, right.id));
    } else if (key === "attachments") {
      normalized.sort((left, right) => compareUtf8(left.id, right.id));
    }
    return normalized;
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).filter((childKey) => childKey !== "source_path").sort().map((childKey) => [
      normalizeString(childKey),
      normalizeValue(value[childKey], childKey),
    ]));
  }
  return value;
}

export function canonicalizeRequest(request) {
  return JSON.stringify(normalizeValue(request));
}

export function computeRequestHash(request) {
  return createHash("sha256").update(canonicalizeRequest(request), "utf8").digest("hex");
}

export function sha256Buffer(value) {
  return createHash("sha256").update(value).digest("hex");
}

export async function sha256File(filePath) {
  const handle = await open(filePath, "r");
  const hash = createHash("sha256");
  try {
    for await (const chunk of handle.readableWebStream()) hash.update(chunk);
  } finally {
    await handle.close();
  }
  return hash.digest("hex");
}
