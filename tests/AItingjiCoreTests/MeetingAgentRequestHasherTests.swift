import AItingjiCore
import Foundation
import Testing

@Suite("Meeting Agent request hash")
struct MeetingAgentRequestHasherTests {
    @Test("hash matches the Node canonical request algorithm")
    func matchesNodeCanonicalHash() throws {
        let request = fixtureRequest(sourcePath: "/tmp/one.txt")

        #expect(try MeetingAgentRequestHasher.hash(request) == "32fdc073705f0a12f133da28428b0199a44900889e9c7b7041042122bdad4a63")
    }

    @Test("source path and input ordering do not change the hash")
    func ignoresSourcePathAndStableSortsArrays() throws {
        var first = fixtureRequest(sourcePath: "/tmp/one.txt")
        let second = fixtureRequest(sourcePath: "/another/location/one.txt")
        first.transcript.segments.reverse()
        first.attachments.reverse()

        #expect(try MeetingAgentRequestHasher.hash(first) == MeetingAgentRequestHasher.hash(second))
    }

    @Test("Unicode ids use the same NFC UTF-8 ordering as Node")
    func unicodeOrderingMatchesNode() throws {
        var request = fixtureRequest(sourcePath: "/tmp/one.txt")
        request.transcript.segments = [
            MeetingAgentTranscriptSegmentInput(id: "ä", startMs: 0, endMs: 900, speaker: "待确认", text: "讨论范围"),
            MeetingAgentTranscriptSegmentInput(id: "z", startMs: 0, endMs: 900, speaker: "张三", text: "确认计划")
        ]
        request.attachments[0].id = "ä"
        request.attachments[1].id = "z"

        #expect(try MeetingAgentRequestHasher.hash(request) == "9905670cfad7ae9ca0ebd554d4cc8a34e70c0062aa02e9d6675fd792c7534856")
    }

    private func fixtureRequest(sourcePath: String) -> MeetingAgentJobRequest {
        MeetingAgentJobRequest(
            requestID: "job-1",
            meeting: MeetingAgentMeetingInput(
                id: "meeting-1",
                title: "项目周例会\r\n第二行",
                startedAt: "2026-07-18T01:00:00Z",
                endedAt: "2026-07-18T02:00:00Z",
                timezone: "Asia/Shanghai",
                captureSource: "mixed",
                participants: [MeetingAgentParticipantInput(name: "张三", role: "负责人")]
            ),
            transcript: MeetingAgentTranscriptInput(
                language: "zh-CN",
                plainText: "先讨论范围。\r然后确认计划。",
                segments: [
                    MeetingAgentTranscriptSegmentInput(id: "segment-2", startMs: 1000, endMs: 2000, speaker: "张三", text: "确认计划"),
                    MeetingAgentTranscriptSegmentInput(id: "segment-1", startMs: 0, endMs: 900, speaker: "待确认", text: "讨论范围")
                ]
            ),
            attachments: [
                MeetingAgentAttachmentInput(
                    id: "attachment-2",
                    fileName: "附件2.txt",
                    mediaType: "text/plain",
                    sizeBytes: 2,
                    sha256: String(repeating: "b", count: 64),
                    sourcePath: "/tmp/two.txt"
                ),
                MeetingAgentAttachmentInput(
                    id: "attachment-1",
                    fileName: "附件1.txt",
                    mediaType: "text/plain",
                    sizeBytes: 1,
                    sha256: String(repeating: "a", count: 64),
                    sourcePath: sourcePath
                )
            ],
            analysis: MeetingAgentAnalysisInput(goal: "核对风险", language: "zh-CN")
        )
    }
}
