import AItingjiCore
import Testing
@testable import AItingjiApp

@Suite("Meeting text postprocess batch")
struct MeetingTextPostprocessBatchTests {
    @Test("batches preserve every segment in order")
    func batchesPreserveOrder() {
        let segments = (0..<5).map { index in
            TranscriptSegment(
                id: "segment-\(index)",
                meetingID: "meeting",
                startMs: index * 1_000,
                endMs: index * 1_000 + 900,
                speakerLabel: "未分配发言人",
                rawText: "第 \(index) 段会议文字",
                processedText: "第 \(index) 段会议文字",
                finalText: "第 \(index) 段会议文字"
            )
        }

        let batches = MeetingTextPostprocessBatch.batches(
            segments: segments,
            maximumCharacterCount: 70
        )

        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 }.map(\.id) == segments.map(\.id))
    }

    @Test("response must preserve the exact segment IDs")
    func validatesIDs() throws {
        let expected = [
            MeetingTextPostprocessItem(id: "one", text: "嗯，开始。"),
            MeetingTextPostprocessItem(id: "two", text: "然后讨论。")
        ]
        let response = """
        ```json
        [{"id":"one","text":"开始。"},{"id":"two","text":"讨论。"}]
        ```
        """

        let decoded = try MeetingTextPostprocessBatch.decode(response, expectedItems: expected)

        #expect(decoded == ["one": "开始。", "two": "讨论。"])
        #expect(throws: MeetingTextPostprocessBatchError.mismatchedSegmentIDs) {
            try MeetingTextPostprocessBatch.decode(
                #"[{"id":"one","text":"开始。"}]"#,
                expectedItems: expected
            )
        }
    }
}
