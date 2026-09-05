import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Isolated test-copy recovery", .serialized)
struct TestCopyMinutesRecoveryTests {
    @Test("regenerates the two historical failures only in the isolated copy")
    func regeneratesHistoricalFailures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TINGLAN_RUN_TEST_COPY_RECOVERY"] == "1" else { return }
        let databasePath = try #require(environment["TINGLAN_TEST_COPY_DB_PATH"])
        let evidencePath = try #require(environment["TINGLAN_TEST_COPY_EVIDENCE_PATH"])
        let databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL
        #expect(databaseURL.deletingLastPathComponent().lastPathComponent == "会小纪测试版")
        guard databaseURL.deletingLastPathComponent().lastPathComponent == "会小纪测试版" else {
            throw TestCopyRecoveryError.refusedNonTestDatabase(databasePath)
        }

        let store = try AppPersistenceStore(path: databasePath)
        defer { store.close() }
        let snapshot = try store.loadSnapshot()
        let source = try #require(snapshot.modelSources.first {
            $0.type == .agent && $0.isDefault && $0.enabled
        })
        let targetIDs = [
            "A06CC268-BC71-4F75-A067-3607D5026FD3",
            "01A0EDF8-DA37-4093-9CED-92A25C08511D"
        ]
        let minutesDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("MeetingMinutes", isDirectory: true)
        let generator = MeetingMinutesGenerator(storageDirectory: minutesDirectory)
        var evidence: [[String: Any]] = []

        for meetingID in targetIDs {
            var meeting = try #require(snapshot.meetings.first { $0.id == meetingID })
            let segments = try #require(snapshot.segmentsByMeeting[meetingID])
            let (notes, images) = try store.loadMeetingNotes(meetingID: meetingID, includeOriginalData: true)
            let imagesByNote = Dictionary(grouping: images, by: \.noteID)
            let contents = notes.map { MeetingNoteContent(note: $0, images: imagesByNote[$0.id, default: []]) }
            let previousError = meeting.minutesGenerationError ?? ""
            var lastError = ""
            var artifact: MeetingMinutesArtifact?
            for _ in 1...3 {
                do {
                    artifact = try await generator.generate(
                        meeting: meeting,
                        segments: segments,
                        source: source,
                        notes: contents
                    )
                    break
                } catch {
                    lastError = error.localizedDescription
                }
            }

            if let artifact {
                meeting.status = .done
                meeting.minutesGenerationError = nil
                if MeetingTitleGeneration.shouldReplace(title: meeting.title) {
                    meeting.title = artifact.document.meetingName
                }
                try store.upsertMeeting(meeting)
                evidence.append([
                    "meetingID": meetingID,
                    "titleBefore": snapshot.meetings.first { $0.id == meetingID }?.title ?? "",
                    "titleAfter": meeting.title,
                    "errorBefore": previousError,
                    "errorAfter": "",
                    "participants": artifact.document.participants,
                    "mainTopics": artifact.document.mainTopics?.map(\.topic) ?? [],
                    "conclusions": artifact.document.conclusions.map(\.conclusion),
                    "actions": artifact.document.actions.map(\.action),
                    "markdownReadable": !artifact.markdown.isEmpty,
                    "htmlReadable": !artifact.html.isEmpty,
                    "transcriptSegmentCount": segments.count
                ])
            } else {
                meeting.status = .failed
                meeting.minutesGenerationError = lastError
                try store.upsertMeeting(meeting)
                evidence.append([
                    "meetingID": meetingID,
                    "titleBefore": meeting.title,
                    "titleAfter": meeting.title,
                    "errorBefore": previousError,
                    "errorAfter": lastError,
                    "transcriptSegmentCount": segments.count
                ])
            }
        }

        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let evidenceURL = URL(fileURLWithPath: evidencePath)
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: evidenceURL, options: .atomic)
        #expect(evidence.count == 2)
        #expect(evidence.allSatisfy { ($0["errorAfter"] as? String) == "" })
    }
}

private enum TestCopyRecoveryError: Error, LocalizedError {
    case refusedNonTestDatabase(String)

    var errorDescription: String? {
        switch self {
        case let .refusedNonTestDatabase(path):
            "拒绝操作非测试版数据库：\(path)"
        }
    }
}
