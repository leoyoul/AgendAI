import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export function createFixture({ migrated = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tinglan-mcp-test-"));
  const databasePath = path.join(root, "tinglan.sqlite");
  const ledgerPath = path.join(root, "bridge", "sync.sqlite");
  const obsidianRoot = path.join(root, "vault");
  const db = new DatabaseSync(databasePath);
  db.exec(`
    CREATE TABLE meetings (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at REAL NOT NULL,
      started_at REAL,
      ended_at REAL,
      is_archived INTEGER NOT NULL DEFAULT 0,
      audio_file_path TEXT,
      model_snapshot TEXT NOT NULL DEFAULT '{}',
      error_message TEXT
      ${
        migrated
          ? `,handoff_status TEXT NOT NULL DEFAULT 'ignored',
             handoff_started_at REAL,
             handoff_completed_at REAL,
             handoff_content_hash TEXT,
             handoff_error TEXT`
          : ""
      }
    );
    CREATE TABLE transcript_segments (
      id TEXT PRIMARY KEY,
      meeting_id TEXT NOT NULL,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      raw_text TEXT NOT NULL DEFAULT '',
      processed_text TEXT NOT NULL DEFAULT '',
      final_text TEXT NOT NULL DEFAULT '',
      speaker_label TEXT NOT NULL DEFAULT '',
      person_name TEXT,
      merged_into_id TEXT,
      FOREIGN KEY(meeting_id) REFERENCES meetings(id)
    );
    CREATE TABLE people (
      id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      aliases TEXT NOT NULL DEFAULT '[]',
      job_title TEXT NOT NULL DEFAULT '',
      role_tags TEXT NOT NULL DEFAULT '[]',
      zentao_account TEXT NOT NULL DEFAULT '',
      zentao_user_id TEXT NOT NULL DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE terminology_entries (
      id TEXT PRIMARY KEY,
      canonical_name TEXT NOT NULL,
      aliases TEXT NOT NULL DEFAULT '[]',
      category TEXT NOT NULL DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1
    );
  `);
  db.close();
  const config = Object.freeze({
    databasePath,
    ledgerPath,
    obsidianRoot,
    notifyutilPath: "/usr/bin/true",
    notifyKey: "io.github.leoyoul.agendai.handoff.changed",
    busyTimeoutMs: 1000,
    staleProcessingSeconds: 7200,
    maxPendingMeetings: 10,
  });
  return {
    root,
    config,
    cleanup() {
      fs.rmSync(root, { recursive: true, force: true });
    },
  };
}

export function openFixture(fixture) {
  return new DatabaseSync(fixture.config.databasePath);
}

export function insertMeeting(fixture, overrides = {}) {
  const meeting = {
    id: "meeting-0001",
    title: "产品周会",
    status: "done",
    created_at: 1_752_614_400,
    started_at: 1_752_614_400,
    ended_at: 1_752_616_200,
    is_archived: 0,
    audio_file_path: "/private/secret/audio.wav",
    model_snapshot: '{"api_key":"secret"}',
    error_message: null,
    handoff_status: "pending",
    handoff_started_at: null,
    handoff_completed_at: null,
    handoff_content_hash: null,
    handoff_error: null,
    ...overrides,
  };
  const db = openFixture(fixture);
  db.prepare(
    `INSERT INTO meetings (
       id, title, status, created_at, started_at, ended_at, is_archived,
       audio_file_path, model_snapshot, error_message, handoff_status,
       handoff_started_at, handoff_completed_at, handoff_content_hash, handoff_error
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(...Object.values(meeting));
  db.close();
  return meeting;
}

export function insertSegment(fixture, overrides = {}) {
  const segment = {
    id: "segment-0001",
    meeting_id: "meeting-0001",
    start_ms: 0,
    end_ms: 1200,
    raw_text: "原始内容",
    processed_text: "处理内容",
    final_text: "最终内容",
    speaker_label: "发言人 1",
    person_name: "张三",
    merged_into_id: null,
    ...overrides,
  };
  const db = openFixture(fixture);
  db.prepare(
    `INSERT INTO transcript_segments (
       id, meeting_id, start_ms, end_ms, raw_text, processed_text,
       final_text, speaker_label, person_name, merged_into_id
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(...Object.values(segment));
  db.close();
  return segment;
}

export function readMeeting(fixture, meetingId = "meeting-0001") {
  const db = openFixture(fixture);
  const row = db.prepare("SELECT * FROM meetings WHERE id = ?").get(meetingId);
  db.close();
  return row;
}
