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
        #expect(artifact.displayMarkdown.contains("图片附件：预算.png"))
        #expect(artifact.displayMarkdown.contains("data:image") == false)
        #expect(artifact.html.contains("data:image/png;base64,AQID"))
        #expect(artifact.html.contains("图片识别：预算金额待确认"))
        #expect(artifact.html.contains("src=\"http") == false)
        #expect(try generator.load(meetingID: meeting.id) == artifact)
    }

    @Test("multimodal generation enriches notes but sends final minutes request without images")
    func multimodalGeneratorUsesVisionAndFinalTextOnly() async throws {
        let probe = NoteMultimodalProbe()
        let generator = MeetingMinutesGenerator(
            modelResponseGenerator: { _, _, _ in
                """
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
            },
            multimodalModelResponseGenerator: { _, systemPrompt, userText, images in
                await probe.record(systemPrompt: systemPrompt, userText: userText, imageCount: images.count)
                if systemPrompt.contains("图片识别助手") {
                    return "识别到预算表，金额待确认。"
                }
                return "{}"
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
        #expect(await probe.imageCounts == [1])
        #expect(await probe.userTexts == ["请识别这张会议笔记图片：table.png"])
        #expect(artifact.markdown.contains("请结合图片复核"))
    }

    @Test("failed image recognition keeps image notes and generates text minutes")
    func failedImageRecognitionFallsBackToTextMinutes() async throws {
        let probe = NoteMultimodalProbe()
        let generator = MeetingMinutesGenerator(
            modelResponseGenerator: { _, _, _ in
                """
                {"meeting_title":"图片笔记会议","subtitle":"纪要","summary":"图片附件已保留。","conclusions":[],"actions":[],"risks":[],"milestones":[],"archive_items":[]}
                """
            },
            multimodalModelResponseGenerator: { _, systemPrompt, userText, images in
                await probe.record(systemPrompt: systemPrompt, userText: userText, imageCount: images.count)
                throw PostprocessClientError.invalidResponseStatus(502, "Upstream request failed")
            }
        )
        let meeting = Meeting(id: "vision-fallback", title: "图片笔记会议", status: .done, createdAt: Date())
        let note = MeetingNote(id: "note", meetingID: meeting.id, body: "图片内容很重要。")
        let image = MeetingNoteImage(id: "image", noteID: note.id, filename: "important.jpg", mimeType: "image/jpeg", originalData: Data([1, 2, 3]), thumbnailData: Data(), sha256: String(repeating: "d", count: 64))
        let source = ModelSource(id: "vision-source", type: .agent, name: "视觉模型", baseURL: "https://example.test/v1", selectedModel: "vision-model", supportsVision: true)

        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论方案")],
            source: source,
            notes: [MeetingNoteContent(note: note, images: [image])]
        )

        #expect(artifact.noteVisionResults.isEmpty)
        #expect(artifact.noteVisionFailures.map(\.imageID) == [image.id])
        #expect(artifact.noteVisionFailures.first?.reason.contains("502") == true)
        #expect(artifact.noteVisionFailures.first?.reason.contains("Upstream request failed") == true)
        #expect(artifact.markdown.contains("图片：important.jpg"))
        #expect(artifact.html.contains("data:image/jpeg;base64,AQID"))
        #expect(await probe.imageCounts == [1])
    }

    @Test("multiple images retain successful OCR and report individual failures")
    func partialImageRecognitionFailure() async throws {
        let probe = NoteMultimodalProbe()
        let generator = MeetingMinutesGenerator(
            modelResponseGenerator: { _, _, _ in
                "{\"subtitle\":\"纪要\",\"summary\":\"继续生成\",\"conclusions\":[],\"actions\":[],\"risks\":[],\"milestones\":[],\"archive_items\":[]}"
            },
            multimodalModelResponseGenerator: { _, systemPrompt, userText, images in
                await probe.record(systemPrompt: systemPrompt, userText: userText, imageCount: images.count)
                if userText.contains("失败图.png") {
                    throw PostprocessClientError.invalidResponseStatus(503, "vision unavailable")
                }
                return "识别成功"
            }
        )
        let meeting = Meeting(id: "partial-vision", title: "部分失败", status: .done, createdAt: Date())
        let note = MeetingNote(id: "note", meetingID: meeting.id, body: "图文笔记")
        let success = MeetingNoteImage(id: "success", noteID: note.id, filename: "成功图.png", mimeType: "image/png", originalData: Data([1]), thumbnailData: Data(), sha256: String(repeating: "1", count: 64))
        let failure = MeetingNoteImage(id: "failure", noteID: note.id, filename: "失败图.png", mimeType: "image/png", originalData: Data([2]), thumbnailData: Data(), sha256: String(repeating: "2", count: 64))
        let source = ModelSource(id: "vision", type: .agent, name: "视觉模型", baseURL: "https://example.test/v1", selectedModel: "vision", supportsVision: true)

        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论")],
            source: source,
            notes: [MeetingNoteContent(note: note, images: [success, failure])]
        )

        #expect(artifact.noteVisionResults.map(\.imageID) == [success.id])
        #expect(artifact.noteVisionFailures.map(\.imageID) == [failure.id])
        #expect(await probe.userTexts == ["请识别这张会议笔记图片：成功图.png", "请识别这张会议笔记图片：失败图.png"])
    }

    @Test("cancelled image recognition propagates cancellation")
    func cancelledImageRecognition() async throws {
        let started = VisionStartProbe()
        let generator = MeetingMinutesGenerator(
            modelResponseGenerator: { _, _, _ in "{}" },
            multimodalModelResponseGenerator: { _, _, _, _ in
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                return "不应返回"
            }
        )
        let meeting = Meeting(id: "cancel-vision", title: "取消识别", status: .done, createdAt: Date())
        let note = MeetingNote(id: "note", meetingID: meeting.id, body: "取消")
        let image = MeetingNoteImage(id: "image", noteID: note.id, filename: "取消.png", mimeType: "image/png", originalData: Data([1]), thumbnailData: Data(), sha256: String(repeating: "3", count: 64))
        let source = ModelSource(id: "vision", type: .agent, name: "视觉模型", baseURL: "https://example.test/v1", selectedModel: "vision", supportsVision: true)
        let task = Task {
            try await generator.generate(
                meeting: meeting,
                segments: [TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论")],
                source: source,
                notes: [MeetingNoteContent(note: note, images: [image])]
            )
        }
        await started.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("included note body is passed to the minutes model as the participant source")
    func includedNoteBodyReachesMinutesModelPrompt() async throws {
        let probe = NotePromptProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-note-participants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let meeting = Meeting(
            id: "note-participants-meeting",
            title: "参会人员核对",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let participantNote = "参会人员：由磊、刘瑜总、高原主任、高世博、谢倩"
        let source = ModelSource(
            id: "note-participants-source",
            type: .agent,
            name: "纪要模型",
            baseURL: "https://example.test/v1",
            selectedModel: "minutes-model"
        )
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, _, userText in
                await probe.record(userText: userText)
                return """
                {
                  "meeting_title": "参会人员核对",
                  "subtitle": "参会人员确认",
                  "summary": "以人工笔记中的参会人员为准。",
                  "participants": [
                    {"name":"转写误识别人员","role":"待确认","evidence":"转写","status":"待确认"}
                  ],
                  "conclusions": [],
                  "actions": [],
                  "risks": [],
                  "milestones": [],
                  "archive_items": []
                }
                """
            }
        )

        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(
                id: "segment",
                meetingID: meeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "讨论方案"
            )],
            source: source,
            notes: [MeetingNoteContent(note: MeetingNote(
                id: "participant-note",
                meetingID: meeting.id,
                body: participantNote
            ))]
        )

        #expect(await probe.userText?.contains(participantNote) == true)
        #expect(await probe.userText?.contains("participants 必须以该名单为准") == true)
        #expect(artifact.document.participants == ["由磊", "刘瑜总", "高原主任", "高世博", "谢倩"])
        #expect(artifact.document.participantDetails?.map(\.name) == artifact.document.participants)
        #expect(artifact.document.participantDetails?.allSatisfy { $0.role == "待确认" } == true)
    }

    @Test("participant prose is ignored and explicit duplicate names are deduplicated")
    func participantListRequiresColonAndDeduplicates() async throws {
        let generator = MeetingMinutesGenerator(modelResponseGenerator: { _, _, _ in
            "{\"subtitle\":\"纪要\",\"summary\":\"参会人员需要确认\",\"participants\":[{\"name\":\" 张三 \",\"role\":\"\"},{\"name\":\"模型人员\",\"role\":\"观察员\"}],\"conclusions\":[],\"actions\":[],\"risks\":[],\"milestones\":[],\"archive_items\":[]}"
        })
        let meeting = Meeting(id: "participants", title: "人员", status: .done, createdAt: Date())
        let source = ModelSource(id: "agent", type: .agent, name: "模型", baseURL: "https://example.test/v1", selectedModel: "model")
        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论")],
            source: source,
            notes: [MeetingNoteContent(note: MeetingNote(id: "note", meetingID: meeting.id, body: "参会人员需要确认\n参会人员：张三、李四、张三"))]
        )
        #expect(artifact.document.participants == ["张三", "李四"])
        #expect(artifact.document.participantDetails?.map(\.role) == ["待确认", "待确认"])
    }

    @MainActor
    @Test("AppState persists completed and failed image statuses without blocking minutes")
    func appStatePersistsPartialVisionStatuses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-note-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        let meeting = Meeting(id: "state-vision", title: "状态测试", status: .done, createdAt: Date())
        let segment = TranscriptSegment(id: "segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "讨论")
        let note = MeetingNote(id: "note", meetingID: meeting.id, body: "图片状态")
        let success = MeetingNoteImage(id: "success", noteID: note.id, filename: "成功.png", mimeType: "image/png", originalData: Data([1]), thumbnailData: Data(), sha256: String(repeating: "4", count: 64))
        let failure = MeetingNoteImage(id: "failure", noteID: note.id, filename: "失败.png", mimeType: "image/png", originalData: Data([2]), thumbnailData: Data(), sha256: String(repeating: "5", count: 64))
        let source = ModelSource(id: "agent", type: .agent, name: "视觉模型", baseURL: "https://example.test/v1", selectedModel: "vision", isDefault: true, enabled: true, supportsVision: true)
        try store.upsertMeeting(meeting)
        try store.upsertSegment(segment)
        try store.upsertMeetingNote(note)
        try store.upsertMeetingNoteImage(success)
        try store.upsertMeetingNoteImage(failure)
        try store.upsertModelSource(source)
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true),
            modelResponseGenerator: { _, _, _ in
                "{\"subtitle\":\"纪要\",\"summary\":\"图片失败未阻塞\",\"conclusions\":[],\"actions\":[],\"risks\":[],\"milestones\":[],\"archive_items\":[]}"
            },
            multimodalModelResponseGenerator: { _, _, userText, _ in
                if userText.contains("失败.png") {
                    throw PostprocessClientError.invalidResponseStatus(503, "图片服务暂不可用")
                }
                return "识别完成"
            }
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: generator
        )
        appState.selectedMeetingID = meeting.id
        appState.generateSelectedMeetingMinutes()
        for _ in 0..<200 where appState.generatingMeetingMinutesIDs.contains(meeting.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let (_, images) = try store.loadMeetingNotes(meetingID: meeting.id)
        let byID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        #expect(appState.selectedMeetingMinutesArtifact?.document.summary == "图片失败未阻塞")
        #expect(byID[success.id]?.visionStatus == .completed)
        #expect(byID[failure.id]?.visionStatus == .failed)
        #expect(byID[failure.id]?.visionError?.contains("图片服务暂不可用") == true)
        #expect(appState.statusMessage.contains("未影响纪要生成"))
    }
}

private actor NoteMultimodalProbe {
    private(set) var imageCounts: [Int] = []
    private(set) var userTexts: [String] = []

    func record(systemPrompt: String, userText: String, imageCount: Int) {
        imageCounts.append(imageCount)
        userTexts.append(userText)
    }
}

private actor VisionStartProbe {
    private var started = false

    func markStarted() { started = true }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private actor NotePromptProbe {
    private(set) var userText: String?

    func record(userText: String) {
        self.userText = userText
    }
}
