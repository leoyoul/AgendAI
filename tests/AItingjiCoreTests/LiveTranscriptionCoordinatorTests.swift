import AItingjiCore
import Foundation
import Testing

@Test func liveTranscriptionCoordinatorProcessesCapturedChunks() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-live-\(UUID().uuidString).sqlite")
        .path
    let database = try Database(path: path)
    try database.migrate()
    let meeting = Meeting(id: "live-meeting", title: "实时测试", createdAt: Date(timeIntervalSince1970: 0))
    try MeetingRepository(database: database).create(meeting)

    var coordinator = LiveTranscriptionCoordinator(
        meetingID: meeting.id,
        asrClient: MockASRClient(text: "实时转写"),
        voiceprintClient: MockVoiceprintClient(embedding: [1, 0, 0], confidence: 0.8),
        postprocessClient: MockPostprocessClient(),
        segmentRepository: SegmentRepository(database: database)
    )
    let chunk = AudioChunk(
        sequence: 0,
        startMs: 0,
        endMs: 1_000,
        samples: [0.1, -0.1],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let result = try await coordinator.process(chunk: chunk)
    let stored = try SegmentRepository(database: database).list(meetingID: meeting.id)

    #expect(result.segment.finalText == "实时转写。")
    #expect(result.segment.speakerLabel == "未知发言人 1")
    #expect(stored.count == 1)
    #expect(stored[0].rawText == "实时转写")

    database.close()
    try? FileManager.default.removeItem(atPath: path)
}
