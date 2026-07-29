import AItingjiCore
import Testing

@Test
func diarizationTurnsAssignDifferentUnknownSpeakersByTimelineOverlap() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 1_000, speakerLabel: "未知发言人 1"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 1_000, endMs: 2_000, speakerLabel: "未知发言人 1"),
        TranscriptSegment(id: "s3", meetingID: "m1", startMs: 2_000, endMs: 3_000, speakerLabel: "未知发言人 1")
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "SPEAKER_A", confidence: 0.92),
        DiarizationTurn(startMs: 1_000, endMs: 2_000, speakerKey: "SPEAKER_B", confidence: 0.9),
        DiarizationTurn(startMs: 2_000, endMs: 3_000, speakerKey: "SPEAKER_A", confidence: 0.91)
    ]

    let updated = DiarizationApplication.apply(turns: turns, to: segments).segments

    #expect(updated.map(\.speakerLabel) == ["未知发言人 1", "未知发言人 2", "未知发言人 1"])
    #expect(updated.map(\.autoSpeakerLabel) == ["未知发言人 1", "未知发言人 2", "未知发言人 1"])
}

@Test
func diarizationApplicationDoesNotOverwriteManualSpeakerNames() {
    let manual = applyManualSpeakerName(
        to: TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 1_000, speakerLabel: "未知发言人 1"),
        personID: "person-zhang",
        personName: "张三"
    )
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "SPEAKER_B", confidence: 0.9)
    ]

    let updated = DiarizationApplication.apply(turns: turns, to: [manual]).segments[0]

    #expect(updated.speakerLabel == "张三")
    #expect(updated.personID == "person-zhang")
    #expect(updated.personName == "张三")
    #expect(updated.autoSpeakerLabel == "未知发言人 1")
    #expect(updated.isManual)
}

@Test
func diarizationApplicationMapsKnownSpeakerClustersToPersonNames() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 1_000, speakerLabel: "未知发言人 1")
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "SPEAKER_A", confidence: 0.94)
    ]
    let mapping = [
        DiarizationSpeakerMapping(
            meetingID: "m1",
            speakerKey: "SPEAKER_A",
            speakerLabel: "未知发言人 1",
            personID: "person-li",
            personName: "李四",
            confidence: 0.96
        )
    ]

    let updated = DiarizationApplication.apply(turns: turns, to: segments, mappings: mapping).segments[0]

    #expect(updated.speakerLabel == "李四")
    #expect(updated.autoSpeakerLabel == "李四")
    #expect(updated.personID == "person-li")
    #expect(updated.personName == "李四")
}

@Test
func diarizationApplicationKeepsASRTextIntactWhenSegmentOverlapsMultipleSpeakers() {
    let segments = [
        TranscriptSegment(
            id: "s1",
            meetingID: "m1",
            startMs: 33_000,
            endMs: 36_000,
            speakerLabel: "未知发言人 1",
            rawText: "这是一整段实时转写不能被复制或截断",
            processedText: "这是一整段实时转写不能被复制或截断",
            finalText: "这是一整段实时转写不能被复制或截断"
        )
    ]
    let turns = [
        DiarizationTurn(startMs: 29_000, endMs: 35_000, speakerKey: "SPEAKER_A", confidence: 0.9),
        DiarizationTurn(startMs: 35_097, endMs: 36_278, speakerKey: "SPEAKER_B", confidence: 0.9)
    ]

    let updated = DiarizationApplication.apply(turns: turns, to: segments).segments

    #expect(updated.count == 1)
    #expect(updated[0].id == "s1")
    #expect(updated[0].startMs == 33_000)
    #expect(updated[0].endMs == 36_000)
    #expect(updated[0].rawText == "这是一整段实时转写不能被复制或截断")
    #expect(updated[0].finalText == "这是一整段实时转写不能被复制或截断")
    #expect(updated[0].speakerLabel == "未知发言人 1")
}

@Test
func diarizationApplicationKeepsSegmentWhenNoTurnOverlaps() {
    let segments = [
        TranscriptSegment(
            id: "s1",
            meetingID: "m1",
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "未知发言人 1",
            autoSpeakerLabel: "未知发言人 1"
        )
    ]
    let turns = [
        DiarizationTurn(startMs: 2_000, endMs: 3_000, speakerKey: "SPEAKER_A", confidence: 0.9)
    ]

    let result = DiarizationApplication.apply(turns: turns, to: segments)

    #expect(result.segments == segments)
    #expect(result.mappings.isEmpty)
}

@Test
func diarizationTurnsCanBeShiftedToTranscriptTimeline() {
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "SPEAKER_A", confidence: 0.9),
        DiarizationTurn(startMs: 1_000, endMs: 2_000, speakerKey: "SPEAKER_B", confidence: 0.8)
    ]

    let shifted = DiarizationApplication.shift(turns: turns, by: 18_400)

    #expect(shifted == [
        DiarizationTurn(startMs: 18_400, endMs: 19_400, speakerKey: "SPEAKER_A", confidence: 0.9),
        DiarizationTurn(startMs: 19_400, endMs: 20_400, speakerKey: "SPEAKER_B", confidence: 0.8)
    ])
}

@Test
func finalTrackDiarizationUsesSourceScopedAnonymousLabels() {
    let segments = [
        TranscriptSegment(id: "mic", meetingID: "m1", startMs: 0, endMs: 1_000, speakerLabel: "未分配发言人"),
        TranscriptSegment(id: "computer", meetingID: "m1", startMs: 1_000, endMs: 2_000, speakerLabel: "未分配发言人")
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "microphone:SPEAKER_00"),
        DiarizationTurn(startMs: 1_000, endMs: 2_000, speakerKey: "computer:SPEAKER_01")
    ]

    let result = DiarizationApplication.apply(turns: turns, to: segments)

    #expect(result.segments.map(\.speakerLabel) == ["麦克风 · 发言人 A", "电脑音频 · 发言人 B"])
    #expect(result.mappings.map(\.speakerKey).sorted() == ["computer:SPEAKER_01", "microphone:SPEAKER_00"])
}

@Test
func finalTrackDiarizationMarksCrossTrackOverlapInsteadOfInventingSpeaker() {
    let segment = TranscriptSegment(
        id: "overlap",
        meetingID: "m1",
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "未分配发言人",
        rawText: "两人重叠时不能编造归属"
    )
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "microphone:SPEAKER_00"),
        DiarizationTurn(startMs: 300, endMs: 900, speakerKey: "computer:SPEAKER_00")
    ]

    let result = DiarizationApplication.apply(turns: turns, to: [segment])

    #expect(result.segments.count == 1)
    #expect(result.segments[0].speakerLabel == DiarizationApplication.multiTrackOverlapLabel)
    #expect(result.segments[0].autoSpeakerLabel == DiarizationApplication.multiTrackOverlapLabel)
    #expect(result.segments[0].rawText == "两人重叠时不能编造归属")
    #expect(result.mappings.isEmpty)
}

@Test
func finalTrackDiarizationUsesTranscriptionSourceInsteadOfMarkingOverlap() {
    let segment = TranscriptSegment(
        id: "microphone-source",
        meetingID: "m1",
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "未分配发言人",
        sourceTrack: .microphone
    )
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "microphone:SPEAKER_00"),
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "computer:SPEAKER_00")
    ]

    let result = DiarizationApplication.apply(turns: turns, to: [segment])

    #expect(result.segments[0].speakerLabel == "麦克风 · 发言人 A")
    #expect(result.segments[0].sourceTrack == .microphone)
    #expect(result.mappings.map(\.speakerKey) == ["microphone:SPEAKER_00"])
}

@Test
func finalTrackDiarizationPreservesMeetingOnlyManualMappingOnRerun() {
    let mapping = DiarizationSpeakerMapping(
        meetingID: "m1",
        speakerKey: "computer:SPEAKER_00",
        speakerLabel: "王五",
        isManual: true
    )
    let segment = TranscriptSegment(
        id: "s1",
        meetingID: "m1",
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "电脑音频 · 发言人 A"
    )

    let result = DiarizationApplication.apply(
        turns: [DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "computer:SPEAKER_00")],
        to: [segment],
        mappings: [mapping]
    )

    #expect(result.segments[0].speakerLabel == "王五")
    #expect(result.segments[0].personID == nil)
    #expect(result.segments[0].isManual)
    #expect(result.mappings[0].isManual)
}
