import AItingjiCore
import Foundation
import Testing

@Test
func loadSnapshotFetchesSegmentsRunsAndMappingsGroupedByMeeting() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-snapshot-\(UUID().uuidString).sqlite")
        .path
    let store = try AppPersistenceStore(path: path)
    defer {
        store.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    for meetingIndex in 0..<3 {
        let meetingID = "m-\(meetingIndex)"
        try store.upsertMeeting(
            Meeting(id: meetingID, title: "会议 \(meetingIndex)", createdAt: Date(timeIntervalSince1970: 100 + Double(meetingIndex)))
        )
        for segIndex in 0..<4 {
            try store.upsertSegment(
                TranscriptSegment(
                    id: "s-\(meetingIndex)-\(segIndex)",
                    meetingID: meetingID,
                    startMs: segIndex * 1_000,
                    endMs: segIndex * 1_000 + 500,
                    speakerLabel: "临时",
                    rawText: "hello-\(meetingIndex)-\(segIndex)"
                )
            )
        }
        try store.upsertDiarizationRun(
            DiarizationRun(
                id: "run-\(meetingIndex)",
                meetingID: meetingID,
                scope: .full,
                status: .succeeded,
                audioFilePath: "",
                turns: []
            )
        )
        try store.upsertDiarizationSpeakerMapping(
            DiarizationSpeakerMapping(
                meetingID: meetingID,
                speakerKey: "SPEAKER_00",
                speakerLabel: "未知发言人 1"
            )
        )
    }

    let snap = try store.loadSnapshot()
    #expect(snap.meetings.count == 3)
    #expect(snap.segmentsByMeeting["m-0"]?.count == 4)
    #expect(snap.segmentsByMeeting["m-1"]?.count == 4)
    #expect(snap.segmentsByMeeting["m-2"]?.count == 4)
    #expect(snap.diarizationRunsByMeeting.keys.count == 3)
    #expect(snap.diarizationMappingsByMeeting["m-1"]?.first?.speakerKey == "SPEAKER_00")
    // 段内按 start_ms 升序
    let firstMeetingStarts = snap.segmentsByMeeting["m-0"]?.map(\.startMs) ?? []
    #expect(firstMeetingStarts == [0, 1_000, 2_000, 3_000])
}
