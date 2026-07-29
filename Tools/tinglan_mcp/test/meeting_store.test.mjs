import assert from "node:assert/strict";
import test from "node:test";
import { contentHash, finalSegmentText, normalizeSegments } from "../src/content_hash.mjs";
import {
  MeetingStore,
  openGuardedDatabaseForTest,
} from "../src/meeting_store.mjs";
import {
  createFixture,
  insertMeeting,
  insertSegment,
  openFixture,
  readMeeting,
} from "./fixtures.mjs";

test("内容哈希稳定排序，并按 final/processed/raw 回退", () => {
  const meeting = { id: "m1", title: "周会", started_at: 1, ended_at: 2 };
  const earlier = {
    id: "b",
    start_ms: 1,
    end_ms: 2,
    final_text: "",
    processed_text: "处理",
    raw_text: "原始",
    speaker_label: "A",
  };
  const later = {
    id: "a",
    start_ms: 3,
    end_ms: 4,
    final_text: "最终",
    processed_text: "",
    raw_text: "",
    speaker_label: "B",
  };
  assert.equal(finalSegmentText(earlier), "处理");
  assert.deepEqual(
    normalizeSegments([later, earlier]).map((segment) => segment.segment_id),
    ["b", "a"],
  );
  assert.equal(contentHash(meeting, [later, earlier]), contentHash(meeting, [earlier, later]));
  assert.notEqual(
    contentHash(meeting, [later, earlier]),
    contentHash({ ...meeting, title: "改名周会" }, [later, earlier]),
  );
});

test("schema guard 明确拒绝未迁移数据库", (t) => {
  const fixture = createFixture({ migrated: false });
  t.after(() => fixture.cleanup());
  const store = new MeetingStore(fixture.config);
  assert.throws(() => store.validateSchema(), /尚未完成交接字段迁移.*handoff_status/);
});

test("只列可处理、失败和超时 processing，按结束时间排序且最多十场", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  const now = 20_000;
  const states = [
    ["pending", "done", 100, null, 0],
    ["failed", "done", 200, null, 0],
    ["stale", "done", 300, now - 7201, 0],
    ["fresh", "done", 400, now - 10, 0],
    ["ignored", "done", 500, null, 0],
    ["archived", "done", 600, null, 1],
    ["recording", "recording", 700, null, 0],
    ["app-failed", "failed", 150, null, 0],
  ];
  for (const [id, status, ended, handoffStarted, archived] of states) {
    insertMeeting(fixture, {
      id,
      status,
      ended_at: ended,
      is_archived: archived,
      handoff_status:
        id === "stale" || id === "fresh"
          ? "processing"
          : id === "pending"
            ? "pending"
            : id === "failed"
              ? "failed"
              : "ignored",
      handoff_started_at: handoffStarted,
    });
  }
  const store = new MeetingStore(fixture.config);
  const rows = store.listPending({ nowSeconds: now, limit: 10 });
  assert.deepEqual(
    rows.map((row) => row.meeting_id),
    ["pending", "app-failed", "failed", "stale"],
  );
  assert.equal(rows.find((row) => row.meeting_id === "app-failed").attention_type, "recording_failed");

  for (let index = 0; index < 12; index += 1) {
    insertMeeting(fixture, {
      id: `extra-${index}`,
      ended_at: 1000 + index,
      handoff_status: "pending",
    });
  }
  assert.equal(store.listPending({ nowSeconds: now, limit: 10 }).length, 10);
});

test("会议包不泄漏音频和模型配置，并排除已合并片段", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  insertMeeting(fixture);
  insertSegment(fixture, { id: "live", final_text: "保留" });
  insertSegment(fixture, { id: "merged", merged_into_id: "live", final_text: "重复" });
  const packet = new MeetingStore(fixture.config).getMeetingPacket("meeting-0001");
  assert.deepEqual(packet.segments.map((segment) => segment.text), ["保留"]);
  const serialized = JSON.stringify(packet);
  assert.doesNotMatch(serialized, /audio\.wav|api_key|secret/);
});

test("会议包携带启用的词库和禅道人员映射", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  insertMeeting(fixture);
  insertSegment(fixture);
  const db = openFixture(fixture);
  db.prepare(
    `INSERT INTO people (
       id, display_name, aliases, job_title, role_tags,
       zentao_account, zentao_user_id, is_active
     ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)`,
  ).run("person-liming", "李明", '["李总"]', "产品负责人", '["产品"]', "liming", "12");
  db.prepare(
    `INSERT INTO terminology_entries (
       id, canonical_name, aliases, category, is_active
     ) VALUES (?, ?, ?, ?, 1)`,
  ).run("term-example", "示例科技", '["示例"]', "公司");
  db.close();

  const packet = new MeetingStore(fixture.config).getMeetingPacket("meeting-0001");

  assert.deepEqual(packet.directory.people[0], {
    person_id: "person-liming",
    name: "李明",
    aliases: ["李总"],
    job_title: "产品负责人",
    role_tags: ["产品"],
    zentao_account: "liming",
    zentao_user_id: "12",
  });
  assert.deepEqual(packet.directory.terminology[0], {
    entry_id: "term-example",
    canonical_name: "示例科技",
    aliases: ["示例"],
    category: "公司",
  });
});

test("只读连接不能写，交接写连接的 authorizer 拒绝标题和转写修改", (t) => {
  const fixture = createFixture();
  t.after(() => fixture.cleanup());
  insertMeeting(fixture);
  insertSegment(fixture);

  const readOnly = openGuardedDatabaseForTest(fixture.config.databasePath, true);
  assert.throws(
    () => readOnly.prepare("UPDATE meetings SET title = '越权'").run(),
    /readonly|not authorized/i,
  );
  readOnly.close();

  const guardedWrite = openGuardedDatabaseForTest(fixture.config.databasePath, false);
  assert.throws(
    () => guardedWrite.prepare("UPDATE meetings SET title = '越权'").run(),
    /not authorized/i,
  );
  assert.throws(
    () => guardedWrite.prepare("DELETE FROM transcript_segments").run(),
    /not authorized/i,
  );
  guardedWrite.close();
  assert.equal(readMeeting(fixture).title, "产品周会");
});
