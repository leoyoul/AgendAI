#!/usr/bin/env sh
set -eu

SOURCE_ROOT="$HOME/Library/Application Support/会小纪"
SOURCE_DB="$SOURCE_ROOT/ai-tingji.sqlite"
TARGET_ROOT="$HOME/Library/Application Support/会小纪测试版"
TARGET_DB="$TARGET_ROOT/ai-tingji.sqlite"
TMP_ROOT="$(mktemp -d "$HOME/Library/Application Support/.会小纪测试版.XXXXXX")"
TEST_EXECUTABLE="/Applications/AgendAI 会小纪 测试版.app/Contents/MacOS/AgendAI 会小纪 测试版"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if [ ! -f "$SOURCE_DB" ]; then
    echo "找不到正式数据库：$SOURCE_DB"
    exit 1
fi
if pgrep -f "$TEST_EXECUTABLE" >/dev/null 2>&1; then
    echo "请先退出 AgendAI 会小纪 测试版，再重新制作数据副本。"
    exit 1
fi
if [ -e "$TARGET_ROOT" ] && [ "${TINGLAN_REFRESH_TEST_DATA:-0}" != "1" ]; then
    echo "测试数据已存在；如需重新制作副本，请设置 TINGLAN_REFRESH_TEST_DATA=1。"
    exit 1
fi

chmod 700 "$TMP_ROOT"
sqlite3 "$SOURCE_DB" ".backup '$TMP_ROOT/ai-tingji.sqlite'"
sqlite3 "$TMP_ROOT/ai-tingji.sqlite" <<'SQL'
BEGIN IMMEDIATE;
UPDATE meetings
SET audio_file_path = NULL,
    microphone_audio_file_path = NULL,
    computer_audio_file_path = NULL;
UPDATE diarization_runs SET audio_file_path = '';
UPDATE voiceprint_samples SET audio_ref = '';
INSERT INTO app_settings(key, value)
VALUES ('pending_postprocess_meeting_ids', '[]')
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL

for directory in MeetingMinutes MeetingAnalysis; do
    if [ -d "$SOURCE_ROOT/$directory" ]; then
        ditto "$SOURCE_ROOT/$directory" "$TMP_ROOT/$directory"
    fi
done

find "$TMP_ROOT" -type d -exec chmod 700 {} +
find "$TMP_ROOT" -type f -exec chmod 600 {} +
if [ -e "$TARGET_ROOT" ]; then
    rm -rf "$TARGET_ROOT"
fi
mv "$TMP_ROOT" "$TARGET_ROOT"
trap - EXIT
echo "已创建隔离数据副本：$TARGET_ROOT"
