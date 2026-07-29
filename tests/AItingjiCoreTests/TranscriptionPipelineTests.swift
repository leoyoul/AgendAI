import AItingjiCore
import Foundation
import Testing

@Test
func transcriptionPipelineStoresSegmentWithSpeakerLabel() async throws {
    let path = temporaryDatabasePath("pipeline")
    let database = try Database(path: path)
    try database.migrate()
    let meeting = Meeting(id: "m1", title: "管线测试", createdAt: Date(timeIntervalSince1970: 0))
    try MeetingRepository(database: database).create(meeting)

    let chunk = AudioChunk(
        sequence: 0,
        startMs: 0,
        endMs: 1000,
        samples: [0.1, 0.2],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )
    var pipeline = TranscriptionPipeline(
        asrClient: MockASRClient(text: "我们开始吧"),
        voiceprintClient: MockVoiceprintClient(embedding: [1, 0, 0], confidence: 0.87),
        postprocessClient: MockPostprocessClient(),
        segmentRepository: SegmentRepository(database: database)
    )

    let result = try await pipeline.process(chunk: chunk, meetingID: "m1")
    let stored = try SegmentRepository(database: database).list(meetingID: "m1")

    #expect(result.segment.speakerLabel == "未知发言人 1")
    #expect(result.segment.finalText == "我们开始吧。")
    #expect(result.embedding == [1, 0, 0])
    #expect(stored.count == 1)
    #expect(stored.first?.speakerLabel == "未知发言人 1")
    #expect(stored.first?.finalText == "我们开始吧。")
}

private func temporaryDatabasePath(_ name: String) -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-\(UUID().uuidString)-\(name)")
        .appendingPathExtension("sqlite")
    return url.path
}
