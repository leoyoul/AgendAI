import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Meeting note generation")
struct MeetingNotesTests {
    @Test("included note text and image are rendered into a self-contained artifact")
    func includedNotesRenderIntoHTML() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-note-minutes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let generator = MeetingMinutesGenerator(storageDirectory: directory, now: { now })
        let meeting = Meeting(id: "note-meeting", title: "笔记纪要", status: .done, createdAt: now)
        let note = MeetingNote(id: "note", meetingID: meeting.id, body: "人工补充：需要复核预算。")
        let image = MeetingNoteImage(
            id: "image",
            noteID: note.id,
            filename: "预算.png",
            mimeType: "image/png",
            originalData: Data([1, 2, 3]),
            thumbnailData: Data([1]),
            sha256: String(repeating: "b", count: 64),
            visionStatus: .completed,
            visionText: "图片识别：预算金额待确认。"
        )
        let excludedNote = MeetingNote(id: "excluded", meetingID: meeting.id, body: "不应进入纪要。", includeInMinutes: false)
        let source = ModelSource(
            id: "mock-note-minutes",
            type: .agent,
            name: "Mock 纪要",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock"
        )

        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论预算")],
            source: source,
            notes: [
                MeetingNoteContent(note: note, images: [image]),
                MeetingNoteContent(note: excludedNote)
            ]
        )

        #expect(artifact.markdown.contains("人工补充：需要复核预算"))
        #expect(artifact.markdown.contains("不应进入纪要") == false)
        #expect(artifact.html.contains("data:image/png;base64,AQID"))
        #expect(artifact.html.contains("图片识别：预算金额待确认"))
        #expect(artifact.html.contains("src=\"http") == false)
        #expect(try generator.load(meetingID: meeting.id) == artifact)
    }

    @Test("multimodal generation performs vision enrichment and sends original image")
    func multimodalGeneratorUsesVisionAndFinalImage() async throws {
        let probe = NoteMultimodalProbe()
        let generator = MeetingMinutesGenerator(
            modelResponseGenerator: { _, _, _ in "{}" },
            multimodalModelResponseGenerator: { _, systemPrompt, _, images in
                await probe.record(systemPrompt: systemPrompt, imageCount: images.count)
                if systemPrompt.contains("图片识别助手") {
                    return "识别到预算表，金额待确认。"
                }
                return """
                {
                  "meeting_title": "图文会议",
                  "subtitle": "图文资料",
                  "summary": "会议包含人工笔记和图片资料。",
                  "conclusions": [],
                  "actions": [],
                  "risks": [],
                  "milestones": [],
                  "archive_items": []
                }
                """
            }
        )
        let meeting = Meeting(id: "multimodal-meeting", title: "图文会议", status: .done, createdAt: Date())
        let note = MeetingNote(id: "note", meetingID: meeting.id, body: "请结合图片复核。")
        let image = MeetingNoteImage(
            id: "image",
            noteID: note.id,
            filename: "table.png",
            mimeType: "image/png",
            originalData: Data([7, 8, 9]),
            thumbnailData: Data([7]),
            sha256: String(repeating: "c", count: 64)
        )
        let source = ModelSource(
            id: "multimodal-source",
            type: .agent,
            name: "视觉模型",
            baseURL: "https://example.test/v1",
            selectedModel: "vision-model",
            supportsVision: true
        )

        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论预算")],
            source: source,
            notes: [MeetingNoteContent(note: note, images: [image])]
        )

        #expect(artifact.noteVisionResults.first?.text == "识别到预算表，金额待确认。")
        #expect(await probe.imageCounts == [1, 1])
        #expect(artifact.markdown.contains("请结合图片复核"))
    }
}

private actor NoteMultimodalProbe {
    private(set) var imageCounts: [Int] = []

    func record(systemPrompt: String, imageCount: Int) {
        imageCounts.append(imageCount)
    }
}
