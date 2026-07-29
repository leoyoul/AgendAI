import Foundation
import Testing
@testable import AItingjiCore

@Suite("Transcript import persistence")
struct AppPersistenceStoreTranscriptImportTests {
    @Test("batch import rolls back meeting and segments when a segment write fails")
    func batchImportRollsBackOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-import-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TranscriptImportPersistenceTestAPIKeyStore()
        )
        let meeting = Meeting(
            id: "import-rollback-meeting",
            title: "事务回滚测试",
            status: .done,
            captureSource: .imported,
            createdAt: Date()
        )
        let duplicateID = "duplicate-import-segment"
        let segments = [
            TranscriptSegment(
                id: duplicateID,
                meetingID: meeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "张三",
                rawText: "第一条"
            ),
            TranscriptSegment(
                id: duplicateID,
                meetingID: meeting.id,
                startMs: 1_000,
                endMs: 2_000,
                speakerLabel: "李四",
                rawText: "第二条"
            )
        ]

        #expect(throws: (any Error).self) {
            try store.importTranscriptMeeting(meeting, segments: segments)
        }
        let snapshot = try store.loadSnapshot()
        #expect(!snapshot.meetings.contains(where: { $0.id == meeting.id }))
        #expect(snapshot.segmentsByMeeting[meeting.id] == nil)
    }
}

private final class TranscriptImportPersistenceTestAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { nil }
    func setAPIKey(_ apiKey: String, for reference: String) throws {}
    func removeAPIKey(for reference: String) throws {}
}
