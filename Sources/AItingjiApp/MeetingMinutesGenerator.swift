import AItingjiCore
import Foundation

private actor MeetingMinutesGenerationQueue {
    private struct Waiter {
        let maximumConcurrency: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeCountsBySource: [String: Int] = [:]
    private var waitersBySource: [String: [Waiter]] = [:]

    func enqueue<Result: Sendable>(
        sourceID: String,
        maximumConcurrency: Int?,
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquire(sourceID: sourceID, maximumConcurrency: maximumConcurrency)
        do {
            let result = try await operation()
            release(sourceID: sourceID)
            return result
        } catch {
            release(sourceID: sourceID)
            throw error
        }
    }

    private func acquire(sourceID: String, maximumConcurrency: Int?) async {
        let limit = maximumConcurrency.map { max(1, $0) }
        let activeCount = activeCountsBySource[sourceID, default: 0]
        if limit == nil || (waitersBySource[sourceID, default: []].isEmpty && activeCount < limit!) {
            activeCountsBySource[sourceID] = activeCount + 1
            return
        }
        await withCheckedContinuation { continuation in
            waitersBySource[sourceID, default: []].append(
                Waiter(maximumConcurrency: limit!, continuation: continuation)
            )
        }
    }

    private func release(sourceID: String) {
        let activeCount = max(0, activeCountsBySource[sourceID, default: 0] - 1)
        activeCountsBySource[sourceID] = activeCount
        guard var waiters = waitersBySource[sourceID], !waiters.isEmpty else {
            activeCountsBySource.removeValue(forKey: sourceID)
            waitersBySource.removeValue(forKey: sourceID)
            return
        }
        while let first = waiters.first,
              activeCountsBySource[sourceID, default: 0] < first.maximumConcurrency {
            waiters.removeFirst()
            activeCountsBySource[sourceID, default: 0] += 1
            first.continuation.resume()
        }
        if waiters.isEmpty {
            waitersBySource.removeValue(forKey: sourceID)
        } else {
            waitersBySource[sourceID] = waiters
        }
    }
}

struct MeetingMinutesArtifact: Equatable, Sendable {
    var document: MeetingMinutesDocument
    var markdown: String
    var html: String
    var noteVisionResults: [MeetingNoteVisionResult] = []
}

struct MeetingNoteVisionResult: Codable, Equatable, Sendable {
    var imageID: MeetingNoteImage.ID
    var sha256: String
    var text: String
    var model: String
    var promptVersion: String
}

struct MeetingMinutesDocument: Codable, Equatable, Sendable {
    var meetingID: String
    var title: String
    var meetingName: String
    var meetingDate: String
    var meetingTime: String
    var duration: String
    var participants: [String]
    var participantDetails: [MeetingMinutesParticipant]? = nil
    var sources: [String]
    var meetingType: String? = nil
    var backgroundAndPurpose: String? = nil
    var expectedProblem: String? = nil
    var subtitle: String
    var summary: String
    var mainTopics: [MeetingMinutesMainTopic]? = nil
    var keyFacts: [MeetingMinutesKeyFact]? = nil
    var conclusions: [MeetingMinutesConclusion]
    var actions: [MeetingMinutesAction]
    var risks: [MeetingMinutesRisk]
    var milestones: [MeetingMinutesMilestone]
    var archiveItems: [String]
    var sensitiveNote: String
    var preparedDate: String
}

extension MeetingMinutesDocument {
    var isLegacyImportedTranscriptFallback: Bool {
        meetingType == "外部转写导入"
            && subtitle == "外部转写基础纪要（待进一步分析）"
            && sources == ["外部导入转写记录"]
    }
}

struct MeetingMinutesParticipant: Codable, Equatable, Sendable {
    var name: String
    var role: String
    var evidence: String
    var status: String
}

struct MeetingMinutesViewpoint: Codable, Equatable, Sendable {
    var speaker: String
    var viewpoint: String
    var basis: String
    var evidence: String? = nil
}

struct MeetingMinutesDiscussionStep: Codable, Equatable, Sendable {
    var kind: String
    var speaker: String
    var content: String
    var timeRange: String
    var evidence: String
}

struct MeetingMinutesKeyFact: Codable, Equatable, Sendable {
    var item: String
    var value: String
    var nature: String
    var context: String
    var evidence: String
}

struct MeetingMinutesConclusion: Codable, Equatable, Sendable {
    var topic: String
    var conclusion: String
    var status: String? = nil
    var rationale: String? = nil
    var scope: String? = nil
    var evidence: String? = nil
}

struct MeetingMinutesMainTopic: Codable, Equatable, Sendable {
    var topic: String
    var details: String
    var timeRange: String? = nil
    var question: String? = nil
    var viewpoints: [MeetingMinutesViewpoint]? = nil
    var discussionSteps: [MeetingMinutesDiscussionStep]? = nil
    var discussionProcess: String? = nil
    var outcome: String? = nil
    var status: String? = nil
    var evidence: String? = nil
}

struct MeetingMinutesAction: Codable, Equatable, Sendable {
    var action: String
    var owners: [String]
    var deadline: String
    var deliverable: String? = nil
    var dependencies: [String]? = nil
    var acceptanceCriteria: String? = nil
    var status: String? = nil
    var evidence: String? = nil
}

struct MeetingMinutesRisk: Codable, Equatable, Sendable {
    var risk: String
    var impact: String
    var mitigation: String
    var category: String? = nil
    var nextStep: String? = nil
    var evidence: String? = nil
}

struct MeetingMinutesMilestone: Codable, Equatable, Sendable {
    var date: String
    var target: String
}

struct MeetingMinutesGenerator: Sendable {
    typealias ModelResponseGenerator = @Sendable (
        _ source: ModelSource,
        _ systemPrompt: String,
        _ userText: String
    ) async throws -> String

    typealias MultimodalModelResponseGenerator = @Sendable (
        _ source: ModelSource,
        _ systemPrompt: String,
        _ userText: String,
        _ images: [PostprocessImageInput]
    ) async throws -> String

    private let storageDirectory: URL
    private let now: @Sendable () -> Date
    private let modelResponseGenerator: ModelResponseGenerator
    private let multimodalModelResponseGenerator: MultimodalModelResponseGenerator
    private let generationQueue: MeetingMinutesGenerationQueue

    init(
        storageDirectory: URL = Self.defaultStorageDirectory(),
        now: @escaping @Sendable () -> Date = Date.init,
        modelResponseGenerator: @escaping ModelResponseGenerator = { source, systemPrompt, userText in
            let client = OpenAICompatiblePostprocessClient(
                source: source,
                uploader: URLSessionDataUploader(
                    session: HTTPSessionFactory.generation(),
                    maximumConcurrencyPerOrigin: source.meetingMinutesMaximumConcurrency
                ),
                maxTokens: 32_768,
                forceJSONObject: true,
                disableThinking: true
            )
            return try await client.generateMeetingMinutes(
                systemPrompt: systemPrompt,
                userText: userText
            )
        },
        multimodalModelResponseGenerator: @escaping MultimodalModelResponseGenerator = { source, systemPrompt, userText, images in
            let client = OpenAICompatiblePostprocessClient(
                source: source,
                uploader: URLSessionDataUploader(
                    session: HTTPSessionFactory.generation(),
                    maximumConcurrencyPerOrigin: source.meetingMinutesMaximumConcurrency
                ),
                maxTokens: 32_768,
                forceJSONObject: true,
                disableThinking: true
            )
            return try await client.generateMeetingMinutes(
                systemPrompt: systemPrompt,
                userText: userText,
                images: images
            )
        }
    ) {
        self.storageDirectory = storageDirectory
        self.now = now
        self.modelResponseGenerator = modelResponseGenerator
        self.multimodalModelResponseGenerator = multimodalModelResponseGenerator
        generationQueue = MeetingMinutesGenerationQueue()
    }

    func generate(
        meeting: Meeting,
        segments: [TranscriptSegment],
        source: ModelSource,
        vocabulary: MeetingMinutesVocabulary = .empty,
        prompt: String = PostprocessPrompt.meetingMinutes,
        additionalPrompt: String = "",
        notes: [MeetingNoteContent] = []
    ) async throws -> MeetingMinutesArtifact {
        try await generationQueue.enqueue(
            sourceID: source.id,
            maximumConcurrency: source.meetingMinutesMaximumConcurrency
        ) {
            try await generateNow(
                meeting: meeting,
                segments: segments,
                source: source,
                vocabulary: vocabulary,
                prompt: prompt,
                additionalPrompt: additionalPrompt,
                notes: notes
            )
        }
    }

    private func generateNow(
        meeting: Meeting,
        segments: [TranscriptSegment],
        source: ModelSource,
        vocabulary: MeetingMinutesVocabulary,
        prompt: String,
        additionalPrompt: String,
        notes: [MeetingNoteContent]
    ) async throws -> MeetingMinutesArtifact {
        let transcript = vocabulary.normalize(
            MarkdownExporter().export(meeting: meeting, segments: segments)
        )
        let includedNotes = notes.filter(\.note.includeInMinutes)
        let selectedImages = includedNotes.flatMap(\.images)
        let visionResults = try await visionResultsFor(
            images: selectedImages,
            source: source
        )
        let noteContext = Self.noteContext(
            notes: includedNotes,
            visionResults: visionResults
        )
        let renderedNotes = Self.notesWithVisionResults(
            notes: includedNotes,
            visionResults: visionResults
        )
        let draft: MeetingMinutesModelDraft
        if source.baseURL.hasPrefix("mock://") {
            draft = vocabulary.normalize(Self.mockDraft(for: meeting))
        } else {
            var normalizedMeeting = meeting
            normalizedMeeting.title = vocabulary.normalize(meeting.title)
            let systemPrompt = PostprocessPrompt.meetingMinutesWithAdditionalInstructions(
                additionalPrompt,
                basePrompt: prompt
            )
            let userText = Self.requestText(
                meeting: normalizedMeeting,
                transcript: transcript,
                manualNotes: noteContext,
                vocabularyContext: vocabulary.promptContext,
                now: now()
            )
            let response = try await requestModel(
                source: source,
                systemPrompt: systemPrompt,
                userText: userText,
                images: selectedImages
            )
            let selectedDraftFromInitialResponse: MeetingMinutesModelDraft
            if let decodedDraft = try? Self.decodeDraft(response) {
                selectedDraftFromInitialResponse = decodedDraft
            } else {
                let repairPrompt = """
                \(systemPrompt)

                结构修复要求：上一版输出被截断或不是完整 JSON。本次必须输出完整、可解析且正确闭合的 JSON 对象；不得输出解释、Markdown 或代码块。在完整覆盖有效内容的前提下压缩措辞，不得删除 main_topics 要点。
                """
                let repairedResponse = try await requestModel(
                    source: source,
                    systemPrompt: repairPrompt,
                    userText: userText,
                    images: selectedImages
                )
                selectedDraftFromInitialResponse = try Self.decodeDraft(repairedResponse)
            }
            draft = vocabulary.normalize(selectedDraftFromInitialResponse)
        }

        let document = vocabulary.normalize(
            Self.makeDocument(
                meeting: meeting,
                segments: segments,
                draft: draft,
                preparedAt: now()
            )
        )
        let artifact = MeetingMinutesArtifact(
            document: document,
            markdown: MeetingMinutesRenderer.markdown(document, notes: renderedNotes),
            html: MeetingMinutesRenderer.html(document, notes: renderedNotes),
            noteVisionResults: visionResults
        )
        try persist(artifact)
        return artifact
    }

    private func requestModel(
        source: ModelSource,
        systemPrompt: String,
        userText: String,
        images: [MeetingNoteImage]
    ) async throws -> String {
        guard !images.isEmpty else {
            return try await modelResponseGenerator(source, systemPrompt, userText)
        }
        let inputs = try Self.imageInputs(images)
        return try await multimodalModelResponseGenerator(source, systemPrompt, userText, inputs)
    }

    private func visionResultsFor(
        images: [MeetingNoteImage],
        source: ModelSource
    ) async throws -> [MeetingNoteVisionResult] {
        guard !images.isEmpty else { return [] }
        guard source.baseURL.hasPrefix("mock://") || source.supportsVision else {
            throw PostprocessClientError.visionModelRequired
        }
        let model = source.selectedModel ?? source.name
        var results: [MeetingNoteVisionResult] = []
        for image in images {
            if image.visionStatus == .completed,
               image.visionModel == model,
               image.visionPromptVersion == PostprocessPrompt.meetingNoteVisionPromptVersion,
               !image.visionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(
                    MeetingNoteVisionResult(
                        imageID: image.id,
                        sha256: image.sha256,
                        text: image.visionText,
                        model: model,
                        promptVersion: PostprocessPrompt.meetingNoteVisionPromptVersion
                    )
                )
                continue
            }

            if source.baseURL.hasPrefix("mock://") {
                results.append(
                    MeetingNoteVisionResult(
                        imageID: image.id,
                        sha256: image.sha256,
                        text: image.visionText.isEmpty ? "图片内容待确认。" : image.visionText,
                        model: model,
                        promptVersion: PostprocessPrompt.meetingNoteVisionPromptVersion
                    )
                )
                continue
            }

            let response = try await multimodalModelResponseGenerator(
                source,
                PostprocessPrompt.meetingNoteVision,
                "请识别这张会议笔记图片：(image.filename)",
                try Self.imageInputs([image])
            )
            results.append(
                MeetingNoteVisionResult(
                    imageID: image.id,
                    sha256: image.sha256,
                    text: response.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model,
                    promptVersion: PostprocessPrompt.meetingNoteVisionPromptVersion
                )
            )
        }
        return results
    }

    private static func imageInputs(_ images: [MeetingNoteImage]) throws -> [PostprocessImageInput] {
        try images.map { image in
            guard let data = image.originalData, !data.isEmpty else {
                throw MeetingMinutesGenerationError.missingNoteImageData(filename: image.filename)
            }
            return PostprocessImageInput(mimeType: image.mimeType, data: data)
        }
    }

    private static func noteContext(
        notes: [MeetingNoteContent],
        visionResults: [MeetingNoteVisionResult]
    ) -> String {
        guard !notes.isEmpty else { return "" }
        let resultsByImageID = Dictionary(uniqueKeysWithValues: visionResults.map { ($0.imageID, $0) })
        var lines = [
            "以下是本场会议中用户明确选择纳入纪要的人工笔记。人工笔记不是录音转写，必须标记其来源并与会议事实区分。"
        ]
        for (index, content) in notes.enumerated() {
            lines.append("人工笔记 " + String(index + 1) + "：")
            let body = content.note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append("文字记录：(body)")
            }
            for image in content.images {
                lines.append("图片资料：(image.filename)")
                if let result = resultsByImageID[image.id], !result.text.isEmpty {
                    lines.append("图片识别信息：(result.text)")
                }
            }
            if body.isEmpty && content.images.isEmpty {
                lines.append("（空白笔记）")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func notesWithVisionResults(
        notes: [MeetingNoteContent],
        visionResults: [MeetingNoteVisionResult]
    ) -> [MeetingNoteContent] {
        let resultsByID = Dictionary(uniqueKeysWithValues: visionResults.map { ($0.imageID, $0) })
        return notes.map { content in
            let images = content.images.map { image in
                guard let result = resultsByID[image.id] else { return image }
                var updated = image
                updated.visionStatus = .completed
                updated.visionText = result.text
                updated.visionModel = result.model
                updated.visionPromptVersion = result.promptVersion
                updated.visionUpdatedAt = nowDate()
                updated.visionError = nil
                return updated
            }
            return MeetingNoteContent(note: content.note, images: images)
        }
    }

    private static func nowDate() -> Date {
        Date()
    }

    func load(meetingID: Meeting.ID) throws -> MeetingMinutesArtifact? {
        let url = cachedURL(meetingID: meetingID, pathExtension: "json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let document = try JSONDecoder().decode(MeetingMinutesDocument.self, from: Data(contentsOf: url))
        let noteVisionResults = (try? JSONDecoder().decode(
            [MeetingNoteVisionResult].self,
            from: Data(contentsOf: cachedURL(meetingID: meetingID, pathExtension: "notes"))
        )) ?? []
        let renderedMarkdown = MeetingMinutesRenderer.markdown(document)
        let renderedHTML = MeetingMinutesRenderer.html(document)
        let artifact = MeetingMinutesArtifact(
            document: document,
            markdown: cachedContent(
                meetingID: meetingID,
                pathExtension: "md",
                fallback: renderedMarkdown
            ),
            html: cachedContent(
                meetingID: meetingID,
                pathExtension: "html",
                fallback: renderedHTML
            ),
            noteVisionResults: noteVisionResults
        )
        try? persistMissingDerivedFiles(artifact)
        return artifact
    }

    func removeCachedArtifact(meetingID: Meeting.ID) {
        for pathExtension in ["json", "md", "html", "notes"] {
            try? FileManager.default.removeItem(at: cachedURL(meetingID: meetingID, pathExtension: pathExtension))
        }
    }

    func cachedHTMLURL(meetingID: Meeting.ID) -> URL? {
        let url = cachedURL(meetingID: meetingID, pathExtension: "html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func exportFileName(document: MeetingMinutesDocument, pathExtension: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "zh_CN")
        parser.dateFormat = "yyyy年M月d日"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd"
        let compactDate = parser.date(from: document.meetingDate).map(formatter.string)
            ?? document.meetingDate.filter(\.isNumber)
        return "\(safeFilename(document.meetingName))-\(compactDate)-会议纪要.\(pathExtension)"
    }

    static func defaultStorageDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("会小纪", isDirectory: true)
            .appendingPathComponent("MeetingMinutes", isDirectory: true)
    }

    static func decodeDraft(_ response: String) throws -> MeetingMinutesModelDraft {
        let normalized = normalizedJSONObject(response)
        guard let data = normalized.data(using: .utf8) else {
            throw MeetingMinutesGenerationError.invalidStructuredOutput(
                details: "响应无法转换为 UTF-8 数据"
            )
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(MeetingMinutesModelDraft.self, from: data)
        } catch let strictDecodingError {
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let normalizedObject = normalizedDraftObject(object) else {
                    throw strictDecodingError
                }
                let normalizedData = try JSONSerialization.data(withJSONObject: normalizedObject)
                let draft = try decoder.decode(MeetingMinutesModelDraft.self, from: normalizedData)
                guard hasMeaningfulContent(draft) else {
                    throw strictDecodingError
                }
                return draft
            } catch let normalizationError {
                let reportedError = normalizationError is DecodingError
                    ? normalizationError
                    : strictDecodingError
                throw MeetingMinutesGenerationError.invalidStructuredOutput(
                    details: "\(decodingIssueDescription(reportedError))；响应长度 \(data.count) 字节"
                )
            }
        }
    }

    private static func normalizedDraftObject(_ object: Any) -> [String: Any]? {
        guard let root = object as? [String: Any] else { return nil }
        var result: [String: Any] = [
            "subtitle": stringValue(value(in: root, keys: ["subtitle"])),
            "summary": stringValue(value(in: root, keys: ["summary"])),
            "conclusions": arrayValue(value(in: root, keys: ["conclusions"]))
                .map(normalizedConclusion),
            "actions": arrayValue(value(in: root, keys: ["actions"]))
                .map(normalizedAction),
            "risks": arrayValue(value(in: root, keys: ["risks"]))
                .map(normalizedRisk),
            "milestones": arrayValue(value(in: root, keys: ["milestones"]))
                .map(normalizedMilestone),
            "archive_items": stringArray(value(in: root, keys: ["archive_items", "archiveItems"]))
        ]
        copyOptionalString(from: root, keys: ["meeting_title", "meetingTitle"], to: "meeting_title", in: &result)
        copyOptionalString(from: root, keys: ["meeting_type", "meetingType"], to: "meeting_type", in: &result)
        copyOptionalString(
            from: root,
            keys: ["background_and_purpose", "backgroundAndPurpose"],
            to: "background_and_purpose",
            in: &result
        )
        copyOptionalString(
            from: root,
            keys: ["expected_problem", "expectedProblem"],
            to: "expected_problem",
            in: &result
        )
        if let participants = value(in: root, keys: ["participants"]) {
            result["participants"] = arrayValue(participants).map(normalizedParticipant)
        }
        if let topics = value(in: root, keys: ["main_topics", "mainTopics"]) {
            result["main_topics"] = arrayValue(topics).map(normalizedMainTopic)
        }
        if let facts = value(in: root, keys: ["key_facts", "keyFacts"]) {
            result["key_facts"] = arrayValue(facts).map(normalizedKeyFact)
        }
        return result
    }

    private static func normalizedParticipant(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        let name = stringValue(value(in: object, keys: ["name", "person", "speaker", "_value"]))
        return [
            "name": name,
            "role": stringValue(value(in: object, keys: ["role"]), fallback: "待确认"),
            "evidence": stringValue(value(in: object, keys: ["evidence"]), fallback: "待确认"),
            "status": stringValue(value(in: object, keys: ["status"]), fallback: "待确认")
        ]
    }

    private static func normalizedMainTopic(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        let topic = stringValue(value(in: object, keys: ["topic", "title", "subject", "_value"]))
        let discussionProcess = stringValue(value(in: object, keys: ["discussion_process", "discussionProcess"]))
        let outcome = stringValue(value(in: object, keys: ["outcome", "result"]))
        let question = stringValue(value(in: object, keys: ["question"]))
        let details = firstNonemptyString([
            value(in: object, keys: ["details", "detail", "content", "description"]),
            discussionProcess,
            outcome,
            question,
            topic
        ])
        var result: [String: Any] = [
            "topic": topic,
            "details": details
        ]
        copyOptionalString(from: object, keys: ["time_range", "timeRange"], to: "time_range", in: &result)
        copyOptionalString(from: object, keys: ["question"], to: "question", in: &result)
        copyOptionalString(
            from: object,
            keys: ["discussion_process", "discussionProcess"],
            to: "discussion_process",
            in: &result
        )
        copyOptionalString(from: object, keys: ["outcome", "result"], to: "outcome", in: &result)
        copyOptionalString(from: object, keys: ["status"], to: "status", in: &result)
        copyOptionalString(from: object, keys: ["evidence"], to: "evidence", in: &result)
        if let viewpoints = value(in: object, keys: ["viewpoints", "view_points", "opinions"]) {
            result["viewpoints"] = arrayValue(viewpoints).map(normalizedViewpoint)
        }
        if let steps = value(in: object, keys: ["discussion_steps", "discussionSteps", "steps"]) {
            result["discussion_steps"] = arrayValue(steps).map(normalizedDiscussionStep)
        }
        return result
    }

    private static func normalizedViewpoint(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        var result: [String: Any] = [
            "speaker": stringValue(
                value(in: object, keys: ["speaker", "name", "owner"]),
                fallback: "待确认"
            ),
            "viewpoint": stringValue(
                value(in: object, keys: ["viewpoint", "opinion", "point", "content", "text", "_value"])
            ),
            "basis": stringValue(
                value(in: object, keys: ["basis", "rationale", "reason"]),
                fallback: "待确认"
            )
        ]
        copyOptionalString(
            from: object,
            keys: ["evidence", "time_range", "timeRange"],
            to: "evidence",
            in: &result
        )
        return result
    }

    private static func normalizedDiscussionStep(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        return [
            "kind": stringValue(value(in: object, keys: ["kind", "type"]), fallback: "讨论"),
            "speaker": stringValue(value(in: object, keys: ["speaker", "name"]), fallback: "待确认"),
            "content": stringValue(value(in: object, keys: ["content", "text", "detail", "_value"])),
            "time_range": stringValue(
                value(in: object, keys: ["time_range", "timeRange", "time"]),
                fallback: "待确认"
            ),
            "evidence": stringValue(value(in: object, keys: ["evidence"]), fallback: "待确认")
        ]
    }

    private static func normalizedKeyFact(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        return [
            "item": stringValue(value(in: object, keys: ["item", "fact", "name", "_value"])),
            "value": stringValue(value(in: object, keys: ["value", "content"]), fallback: "待确认"),
            "nature": stringValue(value(in: object, keys: ["nature", "type"]), fallback: "待确认"),
            "context": stringValue(value(in: object, keys: ["context"]), fallback: "待确认"),
            "evidence": stringValue(value(in: object, keys: ["evidence"]), fallback: "待确认")
        ]
    }

    private static func normalizedConclusion(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        var result: [String: Any] = [
            "topic": stringValue(value(in: object, keys: ["topic", "title"])),
            "conclusion": stringValue(value(in: object, keys: ["conclusion", "content", "result", "_value"]))
        ]
        for (key, aliases) in [
            ("status", ["status"]),
            ("rationale", ["rationale", "reason"]),
            ("scope", ["scope"]),
            ("evidence", ["evidence"])
        ] {
            copyOptionalString(from: object, keys: aliases, to: key, in: &result)
        }
        return result
    }

    private static func normalizedAction(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        var result: [String: Any] = [
            "action": stringValue(value(in: object, keys: ["action", "task", "item", "content", "_value"])),
            "owners": stringArray(value(in: object, keys: ["owners", "owner", "assignees"])),
            "deadline": stringValue(
                value(in: object, keys: ["deadline", "due_date", "dueDate"]),
                fallback: "待确认"
            )
        ]
        copyOptionalString(from: object, keys: ["deliverable"], to: "deliverable", in: &result)
        if let dependencies = value(in: object, keys: ["dependencies", "dependency"]) {
            result["dependencies"] = stringArray(dependencies)
        }
        copyOptionalString(
            from: object,
            keys: ["acceptance_criteria", "acceptanceCriteria"],
            to: "acceptance_criteria",
            in: &result
        )
        copyOptionalString(from: object, keys: ["status"], to: "status", in: &result)
        copyOptionalString(from: object, keys: ["evidence"], to: "evidence", in: &result)
        return result
    }

    private static func normalizedRisk(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        var result: [String: Any] = [
            "risk": stringValue(value(in: object, keys: ["risk", "item", "content", "_value"])),
            "impact": stringValue(value(in: object, keys: ["impact"]), fallback: "待确认"),
            "mitigation": stringValue(
                value(in: object, keys: ["mitigation", "response", "solution"]),
                fallback: "待确认"
            )
        ]
        copyOptionalString(from: object, keys: ["category"], to: "category", in: &result)
        copyOptionalString(from: object, keys: ["next_step", "nextStep"], to: "next_step", in: &result)
        copyOptionalString(from: object, keys: ["evidence"], to: "evidence", in: &result)
        return result
    }

    private static func normalizedMilestone(_ rawValue: Any) -> [String: Any] {
        let object = dictionaryValue(rawValue)
        return [
            "date": stringValue(value(in: object, keys: ["date", "deadline", "time"])),
            "target": stringValue(value(in: object, keys: ["target", "goal", "content", "_value"]))
        ]
    }

    private static func dictionaryValue(_ value: Any) -> [String: Any] {
        (value as? [String: Any]) ?? ["_value": value]
    }

    private static func arrayValue(_ value: Any?) -> [Any] {
        guard let value, !(value is NSNull) else { return [] }
        return (value as? [Any]) ?? [value]
    }

    private static func stringArray(_ value: Any?) -> [String] {
        arrayValue(value)
            .map(stringValue)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func value(in object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            return array.map(stringValue).filter { !$0.isEmpty }.joined(separator: "；")
        }
        if let object = value as? [String: Any] {
            return object.keys.sorted().compactMap { key in
                let text = stringValue(object[key])
                return text.isEmpty ? nil : "\(key)：\(text)"
            }.joined(separator: "；")
        }
        return String(describing: value)
    }

    private static func stringValue(_ value: Any?, fallback: String) -> String {
        let text = stringValue(value)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
    }

    private static func firstNonemptyString(_ values: [Any?]) -> String {
        for value in values {
            let text = stringValue(value)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }

    private static func copyOptionalString(
        from source: [String: Any],
        keys: [String],
        to targetKey: String,
        in target: inout [String: Any]
    ) {
        guard let value = value(in: source, keys: keys) else { return }
        target[targetKey] = stringValue(value)
    }

    private static func hasMeaningfulContent(_ draft: MeetingMinutesModelDraft) -> Bool {
        let values = [draft.meetingTitle, draft.subtitle, draft.summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return values.contains(where: { !$0.isEmpty })
            || !(draft.mainTopics ?? []).isEmpty
            || !draft.conclusions.isEmpty
            || !draft.actions.isEmpty
            || !draft.risks.isEmpty
            || !draft.milestones.isEmpty
    }

    private static func decodingIssueDescription(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return error.localizedDescription
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(codingPath(context.codingPath, appending: key))"
        case .typeMismatch(let type, let context):
            return "字段 \(codingPath(context.codingPath)) 类型错误，期望 \(String(describing: type))"
        case .valueNotFound(let type, let context):
            return "字段 \(codingPath(context.codingPath)) 缺少 \(String(describing: type)) 值"
        case .dataCorrupted(let context):
            return "JSON 格式错误：\(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func codingPath(_ path: [CodingKey], appending key: CodingKey? = nil) -> String {
        let components = path.map(\.stringValue) + (key.map { [$0.stringValue] } ?? [])
        return components.isEmpty ? "根对象" : components.joined(separator: ".")
    }

    private func persist(_ artifact: MeetingMinutesArtifact) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let meetingID = artifact.document.meetingID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact.document).write(
            to: cachedURL(meetingID: meetingID, pathExtension: "json"),
            options: .atomic
        )
        try encoder.encode(artifact.noteVisionResults).write(
            to: cachedURL(meetingID: meetingID, pathExtension: "notes"),
            options: .atomic
        )
        try persistDerivedFiles(artifact)
    }

    private func persistDerivedFiles(_ artifact: MeetingMinutesArtifact) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let meetingID = artifact.document.meetingID
        try writeIfChanged(
            artifact.markdown,
            to: cachedURL(meetingID: meetingID, pathExtension: "md")
        )
        try writeIfChanged(
            artifact.html,
            to: cachedURL(meetingID: meetingID, pathExtension: "html")
        )
    }

    private func persistMissingDerivedFiles(_ artifact: MeetingMinutesArtifact) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let meetingID = artifact.document.meetingID
        try writeIfMissingOrEmpty(
            artifact.markdown,
            to: cachedURL(meetingID: meetingID, pathExtension: "md")
        )
        try writeIfMissingOrEmpty(
            artifact.html,
            to: cachedURL(meetingID: meetingID, pathExtension: "html")
        )
    }

    private func cachedContent(
        meetingID: Meeting.ID,
        pathExtension: String,
        fallback: String
    ) -> String {
        let url = cachedURL(meetingID: meetingID, pathExtension: pathExtension)
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return content
    }

    private func writeIfChanged(_ content: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            return
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeIfMissingOrEmpty(_ content: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func cachedURL(meetingID: Meeting.ID, pathExtension: String) -> URL {
        storageDirectory
            .appendingPathComponent(Self.safeFilename(meetingID))
            .appendingPathExtension(pathExtension)
    }

    private static func makeDocument(
        meeting: Meeting,
        segments: [TranscriptSegment],
        draft: MeetingMinutesModelDraft,
        preparedAt: Date
    ) -> MeetingMinutesDocument {
        let referenceDate = meeting.startedAt ?? meeting.createdAt
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"
        let meetingTime: String
        if let startedAt = meeting.startedAt, let endedAt = meeting.endedAt {
            meetingTime = "\(timeFormatter.string(from: startedAt))-\(timeFormatter.string(from: endedAt))"
        } else if let startedAt = meeting.startedAt {
            meetingTime = timeFormatter.string(from: startedAt)
        } else {
            meetingTime = "待确认"
        }

        let duration: String
        if let startedAt = meeting.startedAt, let endedAt = meeting.endedAt, endedAt > startedAt {
            let minutes = max(1, Int(ceil(endedAt.timeIntervalSince(startedAt) / 60)))
            duration = "约\(minutes)分钟"
        } else {
            duration = "待确认"
        }

        let participantDetails = draft.participants?.filter {
            !trimmed($0.name).isEmpty
        }
        let storedParticipantDetails = participantDetails?.isEmpty == true ? nil : participantDetails
        let participants = participantDetails?.map(\.name).filter {
            !trimmed($0).isEmpty
        } ?? participantCandidates(from: segments)
        let suggestedMeetingName = draft.meetingTitle.flatMap(MeetingTitleGeneration.normalize)
        let generatedMeetingName = MeetingTitleGeneration.shouldReplace(title: meeting.title)
            ? suggestedMeetingName ?? meeting.title
            : meeting.title
        let normalizedArchiveItems = draft.archiveItems
            .map(trimmed)
            .filter { !$0.isEmpty }
        let normalizedMainTopics = (draft.mainTopics ?? []).filter {
            !trimmed($0.topic).isEmpty || !trimmed($0.details).isEmpty
        }
        let mainTopics = normalizedMainTopics.isEmpty
            ? [MeetingMinutesMainTopic(
                topic: nonempty(draft.subtitle, fallback: generatedMeetingName),
                details: nonempty(draft.summary, fallback: "本次会议未形成可确认的主要内容，待人工复核。")
            )]
            : normalizedMainTopics

        let actions = draft.actions
            .filter { !trimmed($0.action).isEmpty }
            .map { action in
                MeetingMinutesAction(
                    action: action.action,
                    owners: sanitizedOwners(action.owners),
                    deadline: action.deadline,
                    deliverable: action.deliverable,
                    dependencies: action.dependencies,
                    acceptanceCriteria: action.acceptanceCriteria,
                    status: action.status,
                    evidence: action.evidence
                )
            }
        let keyFacts = draft.keyFacts?.filter {
            !trimmed($0.item).isEmpty || !trimmed($0.value).isEmpty
        }
        let storedKeyFacts = keyFacts?.isEmpty == true ? nil : keyFacts

        return MeetingMinutesDocument(
            meetingID: meeting.id,
            title: generatedMeetingName.hasSuffix("会议纪要") ? generatedMeetingName : "\(generatedMeetingName)会议纪要",
            meetingName: generatedMeetingName,
            meetingDate: dateFormatter.string(from: referenceDate),
            meetingTime: meetingTime,
            duration: duration,
            participants: participants.isEmpty ? ["待确认"] : participants,
            participantDetails: storedParticipantDetails,
            sources: meeting.captureSource == .imported
                ? ["外部导入转写记录"]
                : ["AgendAI 会小纪会议转写记录"],
            meetingType: draft.meetingType,
            backgroundAndPurpose: draft.backgroundAndPurpose,
            expectedProblem: draft.expectedProblem,
            subtitle: nonempty(draft.subtitle, fallback: "会议重点与后续安排"),
            summary: nonempty(draft.summary, fallback: "本次会议未形成可确认的摘要，待人工复核。"),
            mainTopics: mainTopics,
            keyFacts: storedKeyFacts,
            conclusions: draft.conclusions.filter { !trimmed($0.topic).isEmpty || !trimmed($0.conclusion).isEmpty },
            actions: actions,
            risks: draft.risks.filter { !trimmed($0.risk).isEmpty },
            milestones: draft.milestones.filter { !trimmed($0.date).isEmpty || !trimmed($0.target).isEmpty },
            archiveItems: normalizedArchiveItems.isEmpty ? ["AgendAI 会小纪会议转写记录", "本会议纪要"] : normalizedArchiveItems,
            sensitiveNote: "账号、密码等敏感信息应通过双方确认的安全方式单独移交，不在公开纪要中明文记录。",
            preparedDate: dateFormatter.string(from: preparedAt)
        )
    }

    private static func participantCandidates(from segments: [TranscriptSegment]) -> [String] {
        var seen: Set<String> = []
        return segments.compactMap { segment in
            let value = trimmed(segment.personName ?? segment.speakerLabel)
            let lowercased = value.lowercased()
            guard !value.isEmpty,
                  value != "未分配发言人",
                  !value.hasPrefix("未知发言人"),
                  !lowercased.hasPrefix("speaker_"),
                  !lowercased.hasPrefix("spk_") else {
                return nil
            }
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func sanitizedOwners(_ owners: [String]) -> [String] {
        var seen: Set<String> = []
        let normalized = owners
            .map(trimmed)
            .map { LibraryPlaceholderPolicy.isGeneratedPersonName($0) ? "待确认" : $0 }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        return normalized.isEmpty ? ["待确认"] : normalized
    }

    static func requestText(
        meeting: Meeting,
        transcript: String,
        manualNotes: String = "",
        vocabularyContext: String = "",
        now: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        let durationMinutes = effectiveDurationMinutes(meeting)
        let durationDescription = durationMinutes.map { "约\($0)分钟" } ?? "无法从会议时间确认"
        let mainTopicCount = recommendedMainTopicCount(meeting: meeting, transcript: transcript)
        return """
        会议标题：\(meeting.title)
        当前日期：\(formatter.string(from: now))
        会议时长：\(durationDescription)
        核心议题篇幅建议：约 \(mainTopicCount) 项，可根据实际内容上下浮动 1 项。这不是最低数量；同一事项必须归并，不得拆分凑数。

        \(vocabularyContext)

        \(manualNotes)

        以下是完整会议转写。请严格按系统消息输出 JSON：

        \(transcript)
        """
    }

    static func recommendedMainTopicCount(meeting: Meeting, transcript: String) -> Int {
        guard let minutes = effectiveDurationMinutes(meeting) else {
            return min(10, max(2, Int(ceil(Double(transcript.count) / 2_500))))
        }
        switch minutes {
        case ...10:
            return 2
        case ...20:
            return 3
        case ...30:
            return 4
        case ...45:
            return 5
        case ...60:
            return 6
        case ...90:
            return 8
        case ...120:
            return 10
        default:
            return min(12, 10 + Int(ceil(Double(minutes - 120) / 30)))
        }
    }

    private static func effectiveDurationMinutes(_ meeting: Meeting) -> Int? {
        let intervalDuration = meeting.recordingIntervals.reduce(0.0) { total, interval in
            guard let endedAt = interval.endedAt, endedAt > interval.startedAt else { return total }
            return total + endedAt.timeIntervalSince(interval.startedAt)
        }
        if intervalDuration > 0 {
            return max(1, Int(ceil(intervalDuration / 60)))
        }
        guard let startedAt = meeting.startedAt,
              let endedAt = meeting.endedAt,
              endedAt > startedAt else {
            return nil
        }
        return max(1, Int(ceil(endedAt.timeIntervalSince(startedAt) / 60)))
    }

    private static func mockDraft(for meeting: Meeting) -> MeetingMinutesModelDraft {
        MeetingMinutesModelDraft(
            meetingTitle: "项目进展与后续安排",
            subtitle: "会议重点与后续安排",
            summary: "会议围绕\(meeting.title)进行了讨论，具体结论和后续安排需结合转写内容复核。",
            mainTopics: [
                MeetingMinutesMainTopic(
                    topic: "会议主要内容",
                    details: "会议围绕\(meeting.title)的背景、核心议题、判断依据和后续方向进行了讨论，具体内容需结合转写记录复核。"
                )
            ],
            conclusions: [
                MeetingMinutesConclusion(topic: "会议内容", conclusion: "已完成会议转写，具体结论待人工复核。")
            ],
            actions: [
                MeetingMinutesAction(action: "复核会议纪要内容并确认行动项", owners: ["待确认"], deadline: "待确认")
            ],
            risks: [
                MeetingMinutesRisk(risk: "转写信息可能不完整", impact: "可能影响纪要准确性", mitigation: "导出前由参会人员复核。")
            ],
            milestones: [],
            archiveItems: ["AgendAI 会小纪会议转写记录", "本会议纪要"]
        )
    }

    private static func normalizedJSONObject(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmedValue.firstIndex(of: "{"),
              let last = trimmedValue.lastIndex(of: "}"),
              first <= last else {
            return trimmedValue
        }
        return String(trimmedValue[first...last])
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let value = trimmed(value)
        return value.isEmpty ? fallback : value
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeFilename(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>")
        let cleaned = value
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "会议纪要" : cleaned
    }

    private static func timelineTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct MeetingMinutesModelDraft: Codable, Equatable, Sendable {
    var meetingTitle: String?
    var meetingType: String? = nil
    var backgroundAndPurpose: String? = nil
    var expectedProblem: String? = nil
    var participants: [MeetingMinutesParticipant]? = nil
    var subtitle: String
    var summary: String
    var mainTopics: [MeetingMinutesMainTopic]? = nil
    var keyFacts: [MeetingMinutesKeyFact]? = nil
    var conclusions: [MeetingMinutesConclusion]
    var actions: [MeetingMinutesAction]
    var risks: [MeetingMinutesRisk]
    var milestones: [MeetingMinutesMilestone]
    var archiveItems: [String]
}

enum MeetingMinutesRenderer {
    static func markdown(
        _ document: MeetingMinutesDocument,
        notes: [MeetingNoteContent]
    ) -> String {
        let base = markdown(document)
        let includedNotes = notes.filter(\.note.includeInMinutes)
        guard !includedNotes.isEmpty else { return base }

        var lines = [base, "", "## 附件：人工笔记与图片资料", ""]
        for (index, content) in includedNotes.enumerated() {
            lines += [
                "### 人工笔记 \(index + 1)",
                "",
                "记录时间：\(content.note.createdAt.formatted(date: .abbreviated, time: .shortened))",
                ""
            ]
            let body = content.note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines += [body, ""]
            }
            for image in content.images {
                lines += ["图片：\(md(image.filename.isEmpty ? "图片" : image.filename))", ""]
                if let data = image.originalData {
                    let dataURL = "data:\(image.mimeType);base64,\(data.base64EncodedString())"
                    lines += ["![\(md(image.filename))](\(dataURL))", ""]
                }
                if !image.visionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines += ["> 图片识别信息：\(md(image.visionText))", ""]
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func markdown(_ document: MeetingMinutesDocument) -> String {
        guard hasHighFidelityData(document) else {
            return legacyMarkdown(document)
        }
        return highFidelityMarkdown(document)
    }

    private static func highFidelityMarkdown(_ document: MeetingMinutesDocument) -> String {
        let timeDescription = md("\(document.duration)；\(document.meetingTime)")
        let participants = md(participantSummary(document))
        let sources = md(document.sources.joined(separator: "；"))
        let topics = effectiveMainTopics(document)
        var lines = [
            "# \(document.title)",
            "",
            "| 项目 | 内容 |",
            "|---|---|",
            "| 会议名称 | \(md(document.meetingName)) |",
            "| 会议日期 | \(md(document.meetingDate)) |",
            "| 会议时间 | \(timeDescription) |",
            "| 会议类型 | \(md(document.meetingType ?? "待确认")) |",
            "| 参会人员 | \(participants) |",
            "| 会议依据 | \(sources) |",
            "",
            "## 一、会议摘要",
            "",
            document.summary
        ]
        if let background = substantive(document.backgroundAndPurpose) {
            lines += ["", "**会议背景：** \(md(background))"]
        }
        if let expectedProblem = substantive(document.expectedProblem) {
            lines += ["", "**会议目标：** \(md(expectedProblem))"]
        }
        if let keyFacts = document.keyFacts, !keyFacts.isEmpty {
            lines += ["", "### 关键事实", "", "| 事实/数字 | 性质 | 依据 |", "|---|---|---|"]
            for fact in keyFacts {
                lines.append("| \(md(factDescription(fact))) | \(md(fact.nature)) | \(md(fact.evidence)) |")
            }
        }

        lines += ["", "## 二、讨论纪要", ""]
        if topics.isEmpty {
            lines.append("暂无可确认的议题，待人工复核。")
        } else {
            for (index, topic) in topics.enumerated() {
                lines += [
                    "### \(index + 1). \(md(topic.topic))",
                    ""
                ]
                if let question = substantive(topic.question) {
                    lines += ["**讨论焦点：** \(md(question))", ""]
                }
                lines += [topicNarrative(topic), ""]
                let viewpoints = namedViewpoints(topic)
                if !viewpoints.isEmpty {
                    lines += ["**主要意见：**", ""]
                    for viewpoint in viewpoints {
                        let basis = substantive(viewpoint.basis).map { "（\(md($0))）" } ?? ""
                        lines.append("- \(md(viewpoint.speaker))：\(md(viewpoint.viewpoint))\(basis)")
                    }
                    lines.append("")
                }
                if let outcome = substantive(topic.outcome) {
                    lines += ["**形成结果：** \(md(outcome))", ""]
                }
                let status = substantive(topic.status) ?? "待确认"
                let evidence = substantive(topic.evidence) ?? substantive(topic.timeRange) ?? "待确认"
                lines += ["*状态：\(md(status))；依据：\(md(evidence))*", ""]
            }
        }

        lines += ["## 三、会议结论与待确认事项", "", "### 已形成结论", ""]
        if document.conclusions.isEmpty {
            lines.append("暂无明确决策，待人工复核。")
        } else {
            lines += ["| 事项 | 结论 | 状态 | 依据 |", "|---|---|---|---|"]
            for conclusion in document.conclusions {
                lines.append("| \(md(conclusion.topic)) | \(md(conclusion.conclusion)) | \(md(conclusion.status ?? "待确认")) | \(md(conclusion.evidence ?? conclusion.rationale ?? "待确认")) |")
            }
        }

        lines += ["", "### 风险与待确认事项", ""]
        if document.risks.isEmpty {
            lines.append("暂无明确风险或待确认事项。")
        } else {
            lines += ["| 事项 | 可能影响 | 下一步 |", "|---|---|---|"]
            for risk in document.risks {
                lines.append("| \(md(risk.risk)) | \(md(risk.impact)) | \(md(riskHandling(risk))) |")
            }
        }

        lines += ["", "## 四、后续行动", ""]
        if document.actions.isEmpty {
            lines.append("暂无明确行动项，待人工复核。")
        } else {
            lines += ["| 行动项 | 责任人 | 交付物 | 截止时间 |", "|---|---|---|---|"]
            for action in document.actions {
                let owners = action.owners.isEmpty ? "待确认" : action.owners.joined(separator: "、")
                lines.append("| \(md(action.action)) | \(md(owners)) | \(md(action.deliverable ?? "待确认")) | \(md(action.deadline)) |")
            }
        }

        if !document.milestones.isEmpty {
            lines += ["", "### 时间节点", "", "| 节点 | 目标 |", "|---|---|"]
            for milestone in document.milestones {
                lines.append("| \(md(milestone.date)) | \(md(milestone.target)) |")
            }
        }
        if !document.archiveItems.isEmpty {
            lines += ["", "**归档资料：** \(md(document.archiveItems.joined(separator: "、")))。"]
        }
        lines += ["", "> \(md(document.sensitiveNote))", "", "**整理日期：** \(document.preparedDate)", ""]
        return lines.joined(separator: "\n")
    }

    private static func substantive(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "待确认",
              trimmed != "暂无",
              !trimmed.hasPrefix("暂无明确") else {
            return nil
        }
        return trimmed
    }

    private static func participantSummary(_ document: MeetingMinutesDocument) -> String {
        if let details = document.participantDetails, !details.isEmpty {
            let values = details.compactMap { participant -> String? in
                guard let name = substantive(participant.name) else { return nil }
                guard let role = substantive(participant.role) else { return name }
                return "\(name)（\(role)）"
            }
            if !values.isEmpty { return values.joined(separator: "、") }
        }
        let participants = document.participants.compactMap(substantive)
        return participants.isEmpty ? "待确认" : participants.joined(separator: "、")
    }

    private static func topicNarrative(_ topic: MeetingMinutesMainTopic) -> String {
        if let details = substantive(topic.details), details != substantive(topic.topic) {
            return details
        }
        if let process = substantive(topic.discussionProcess) {
            return process
        }
        let steps = (topic.discussionSteps ?? []).compactMap { step -> String? in
            guard let content = substantive(step.content) else { return nil }
            if let speaker = substantive(step.speaker) {
                return "\(speaker)：\(content)"
            }
            return content
        }
        return steps.isEmpty ? "暂无可确认的讨论内容。" : steps.joined(separator: "；") + "。"
    }

    private static func namedViewpoints(_ topic: MeetingMinutesMainTopic) -> [MeetingMinutesViewpoint] {
        (topic.viewpoints ?? []).filter {
            substantive($0.speaker) != nil && substantive($0.viewpoint) != nil
        }
    }

    private static func factDescription(_ fact: MeetingMinutesKeyFact) -> String {
        guard let value = substantive(fact.value) else { return fact.item }
        return "\(fact.item)：\(value)"
    }

    private static func riskHandling(_ risk: MeetingMinutesRisk) -> String {
        var values: [String] = []
        for value in [risk.mitigation, risk.nextStep] {
            guard let value = substantive(value), !values.contains(value) else { continue }
            values.append(value)
        }
        guard values.count > 1 else { return values.first ?? "待确认" }
        let trailingPunctuation = CharacterSet(charactersIn: "。；;，,、 ")
        return values
            .map { $0.trimmingCharacters(in: trailingPunctuation) }
            .joined(separator: "；")
    }

    private static func legacyMarkdown(_ document: MeetingMinutesDocument) -> String {
        let timeDescription = md("\(document.duration)；\(document.meetingTime)")
        let participants = md(document.participants.joined(separator: "、"))
        let sources = md(document.sources.joined(separator: "；"))
        let mainTopics = effectiveMainTopics(document)
        var lines = [
            "# \(document.title)",
            "",
            "## 一、会议基本信息",
            "",
            "| 项目 | 内容 |",
            "|---|---|",
            "| 会议名称 | \(md(document.meetingName)) |",
            "| 会议日期 | \(md(document.meetingDate)) |",
            "| 会议时间 | \(timeDescription) |",
            "| 参会人员 | \(participants) |",
            "| 会议依据 | \(sources) |",
            "",
            "## 二、会议摘要",
            "",
            document.summary,
            "",
            "## 三、会议主要内容",
            "",
            "| 序号 | 主要内容要点 | 详细说明 |",
            "|---:|---|---|"
        ]
        for (index, topic) in mainTopics.enumerated() {
            lines.append("| \(index + 1) | \(md(topic.topic)) | \(md(topic.details)) |")
        }

        lines += [
            "",
            "## 四、主要结论",
            "",
            "| 序号 | 事项 | 会议结论 |",
            "|---:|---|---|"
        ]
        if document.conclusions.isEmpty {
            lines.append("| 1 | 暂无明确结论 | 待人工复核 |")
        } else {
            for (index, conclusion) in document.conclusions.enumerated() {
                lines.append("| \(index + 1) | \(md(conclusion.topic)) | \(md(conclusion.conclusion)) |")
            }
        }

        lines += [
            "",
            "## 五、后续行动项",
            "",
            "| 序号 | 行动项 | 责任人 | 时间要求 |",
            "|---:|---|---|---|"
        ]
        if document.actions.isEmpty {
            lines.append("| 1 | 暂无明确行动项 | 待确认 | 待确认 |")
        } else {
            for (index, action) in document.actions.enumerated() {
                let owners = action.owners.isEmpty ? "待确认" : action.owners.joined(separator: "、")
                lines.append("| \(index + 1) | \(md(action.action)) | \(md(owners)) | \(md(action.deadline)) |")
            }
        }

        lines += [
            "",
            "## 六、主要风险及待确认事项",
            "",
            "| 风险/待确认事项 | 可能影响 | 处理要求 |",
            "|---|---|---|"
        ]
        if document.risks.isEmpty {
            lines.append("| 暂无明确风险 | 待人工复核 | 持续跟进 |")
        } else {
            for risk in document.risks {
                lines.append("| \(md(risk.risk)) | \(md(risk.impact)) | \(md(risk.mitigation)) |")
            }
        }

        lines += [
            "",
            "## 七、交付时间节点",
            "",
            "| 节点 | 目标 |",
            "|---|---|"
        ]
        if document.milestones.isEmpty {
            lines.append("| 待确认 | 暂无明确时间节点 |")
        } else {
            for milestone in document.milestones {
                lines.append("| \(md(milestone.date)) | \(md(milestone.target)) |")
            }
        }

        lines += [
            "",
            "## 八、归档清单",
            "",
            document.archiveItems.joined(separator: "、") + "。",
            "",
            "> \(document.sensitiveNote)",
            "",
            "**整理日期：** \(document.preparedDate)",
            ""
        ]
        return lines.joined(separator: "\n")
    }

    static func html(_ document: MeetingMinutesDocument) -> String {
        guard hasHighFidelityData(document) else {
            return legacyHTML(document)
        }
        return highFidelityHTML(document)
    }

    static func html(
        _ document: MeetingMinutesDocument,
        notes: [MeetingNoteContent]
    ) -> String {
        let base = html(document)
        let includedNotes = notes.filter(\.note.includeInMinutes)
        guard !includedNotes.isEmpty else { return base }

        let noteBlocks = includedNotes.enumerated().map { index, content in
            let body = content.note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyHTML = body.isEmpty ? "" : "<p>\(htmlParagraph(body))</p>"
            let imagesHTML = content.images.map { image in
                let imageTitle = htmlEscape(image.filename.isEmpty ? "图片" : image.filename)
                let source: String
                if let data = image.originalData {
                    source = "data:\(image.mimeType);base64,\(data.base64EncodedString())"
                } else {
                    source = "data:,"
                }
                let visionText = image.visionText.trimmingCharacters(in: .whitespacesAndNewlines)
                let visionHTML = visionText.isEmpty
                    ? ""
                    : "<p class=\"evidence\">图片识别信息：\(htmlParagraph(visionText))</p>"
                return "<figure class=\"note-image\"><img src=\"\(source)\" alt=\"\(imageTitle)\"><figcaption>\(imageTitle)</figcaption>\(visionHTML)</figure>"
            }.joined(separator: "\n")
            return "<article class=\"note-item\"><h3>人工笔记 \(index + 1)</h3><p class=\"evidence\">记录时间：\(htmlEscape(content.note.createdAt.formatted(date: .abbreviated, time: .shortened)))</p>\(bodyHTML)\(imagesHTML)</article>"
        }.joined(separator: "\n")
        let section = "<section class=\"notes-section\" aria-label=\"人工笔记与图片资料\"><h2>附件：人工笔记与图片资料</h2>\(noteBlocks)</section>"
        if base.contains("</main>") {
            return base.replacingOccurrences(of: "</main>", with: section + "</main>", options: .literal, range: nil)
        }
        return base + section
    }

    private static func highFidelityHTML(_ document: MeetingMinutesDocument) -> String {
        let topicBlocks = effectiveMainTopics(document).enumerated().map { index, topic in
            let question = substantive(topic.question).map {
                "<p class=\"detail-line\"><strong>讨论焦点：</strong>\(htmlParagraph($0))</p>"
            } ?? ""
            let viewpoints = namedViewpoints(topic).map { viewpoint in
                let basis = substantive(viewpoint.basis).map { "（\(htmlEscape($0))）" } ?? ""
                return "<li><strong>\(htmlEscape(viewpoint.speaker))：</strong>\(htmlEscape(viewpoint.viewpoint))\(basis)</li>"
            }.joined(separator: "\n")
            let viewpointsBlock = viewpoints.isEmpty
                ? ""
                : "<div class=\"opinions\"><strong>主要意见：</strong><ul>\(viewpoints)</ul></div>"
            let outcome = substantive(topic.outcome).map {
                "<p class=\"detail-line\"><strong>形成结果：</strong>\(htmlParagraph($0))</p>"
            } ?? ""
            let status = substantive(topic.status) ?? "待确认"
            let evidence = substantive(topic.evidence) ?? substantive(topic.timeRange) ?? "待确认"
            return """
            <article class="topic">
              <h3>\(index + 1). \(htmlEscape(topic.topic))</h3>
              \(question)
              <p>\(htmlParagraph(topicNarrative(topic)))</p>
              \(viewpointsBlock)
              \(outcome)
              <p class="trace">状态：\(htmlEscape(status))　依据：\(htmlEscape(evidence))</p>
            </article>
            """
        }.joined(separator: "\n")
        let factRows = (document.keyFacts ?? []).map { item in
            "<tr><td>\(htmlEscape(factDescription(item)))</td><td>\(htmlEscape(item.nature))</td><td>\(htmlEscape(item.evidence))</td></tr>"
        }.joined(separator: "\n")
        let factsBlock = factRows.isEmpty ? "" : """
        <h3>关键事实</h3>
        <div class="table-wrap"><table><thead><tr><th>事实/数字</th><th>性质</th><th>依据</th></tr></thead><tbody>\(factRows)</tbody></table></div>
        """
        let conclusionRows = document.conclusions.map { item in
            "<tr><td>\(htmlEscape(item.topic))</td><td>\(htmlParagraph(item.conclusion))</td><td>\(htmlEscape(item.status ?? "待确认"))</td><td>\(htmlEscape(item.evidence ?? item.rationale ?? "待确认"))</td></tr>"
        }.joined(separator: "\n")
        let conclusionsBlock = conclusionRows.isEmpty
            ? "<p>暂无明确决策，待人工复核。</p>"
            : "<div class=\"table-wrap\"><table><thead><tr><th>事项</th><th>结论</th><th>状态</th><th>依据</th></tr></thead><tbody>\(conclusionRows)</tbody></table></div>"
        let riskRows = document.risks.map { item in
            "<tr><td>\(htmlEscape(item.risk))</td><td>\(htmlEscape(item.impact))</td><td>\(htmlEscape(riskHandling(item)))</td></tr>"
        }.joined(separator: "\n")
        let risksBlock = riskRows.isEmpty
            ? "<p>暂无明确风险或待确认事项。</p>"
            : "<div class=\"table-wrap\"><table><thead><tr><th>事项</th><th>可能影响</th><th>下一步</th></tr></thead><tbody>\(riskRows)</tbody></table></div>"
        let actionRows = document.actions.map { item in
            let owners = item.owners.isEmpty ? "待确认" : item.owners.joined(separator: "、")
            return "<tr><td>\(htmlEscape(item.action))</td><td>\(htmlEscape(owners))</td><td>\(htmlEscape(item.deliverable ?? "待确认"))</td><td>\(htmlEscape(item.deadline))</td></tr>"
        }.joined(separator: "\n")
        let actionsBlock = actionRows.isEmpty
            ? "<p>暂无明确行动项，待人工复核。</p>"
            : "<div class=\"table-wrap\"><table><thead><tr><th>行动项</th><th>责任人</th><th>交付物</th><th>截止时间</th></tr></thead><tbody>\(actionRows)</tbody></table></div>"
        let milestoneRows = document.milestones.map { item in
            "<tr><td>\(htmlEscape(item.date))</td><td>\(htmlEscape(item.target))</td></tr>"
        }.joined(separator: "\n")
        let milestonesBlock = milestoneRows.isEmpty ? "" : """
        <h3>时间节点</h3>
        <div class="table-wrap"><table><thead><tr><th>节点</th><th>目标</th></tr></thead><tbody>\(milestoneRows)</tbody></table></div>
        """
        let archiveBlock = document.archiveItems.isEmpty
            ? ""
            : "<p class=\"archive\"><strong>归档资料：</strong>\(htmlEscape(document.archiveItems.joined(separator: "、")))。</p>"
        let background = substantive(document.backgroundAndPurpose).map {
            "<p><strong>会议背景：</strong>\(htmlParagraph($0))</p>"
        } ?? ""
        let expectedProblem = substantive(document.expectedProblem).map {
            "<p><strong>会议目标：</strong>\(htmlParagraph($0))</p>"
        } ?? ""

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <meta name="color-scheme" content="light">
          <link rel="icon" href="data:,">
          <title>\(htmlEscape(document.title))</title>
          <style>
            * { box-sizing:border-box; }
            body { margin:0; padding:40px 20px; color:#333; background:#fff; font-family:"PingFang SC","Microsoft YaHei","SimSun",sans-serif; font-size:14px; line-height:1.9; letter-spacing:0; overflow-wrap:anywhere; }
            .document { max-width:860px; margin:0 auto; padding:30px 36px; background:#fff; border:1px solid #999; }
            h1 { margin:0 0 8px; color:#222; font-size:18px; line-height:1.5; text-align:center; }
            .subtitle { margin:0 0 20px; color:#666; font-size:13px; text-align:center; }
            h2 { margin:24px 0 12px; padding:6px 12px; color:#222; background:#f2f2f2; border-left:4px solid #c0392b; font-size:15px; line-height:1.6; }
            h3 { margin:16px 0 7px; color:#222; font-size:14px; line-height:1.6; }
            p { margin:0 0 10px; text-indent:2em; }
            strong { color:#222; }
            table { width:100%; margin:10px 0 18px; border-collapse:collapse; font-size:13px; line-height:1.65; }
            th, td { padding:8px 10px; border:1px solid #999; text-align:left; vertical-align:top; }
            th { color:#222; background:#f0f0f0; font-weight:600; text-align:center; }
            .meta th { width:92px; white-space:nowrap; }
            .topic { padding:4px 0 14px; border-bottom:1px solid #ccc; }
            .topic:last-child { border-bottom:0; }
            .topic > p, .detail-line, .opinions { text-indent:0; }
            .opinions { margin:6px 0 8px; }
            .opinions ul { margin:4px 0 0; padding-left:24px; }
            .opinions li { margin:2px 0; }
            .trace { margin-top:6px; color:#666; font-size:12px; }
            .archive { margin-top:14px; padding-top:10px; border-top:1px solid #ccc; text-indent:0; }
            .sensitive { color:#666; font-size:12px; text-indent:0; }
            .signature { margin-top:28px; color:#555; text-align:right; }
            .signature p { margin:0; text-indent:0; }
            .note-item { padding:10px 0 14px; border-bottom:1px solid #ccc; }
            .note-image img { display:block; max-width:100%; max-height:720px; height:auto; border:1px solid #999; }
            .note-image figcaption, .evidence { color:#666; font-size:12px; }
            @media (max-width:640px) {
              body { padding:20px 10px; }
              .document { padding:22px 16px; }
              .table-wrap { overflow-x:auto; }
              table { min-width:620px; }
              .meta { min-width:0; }
              .meta th, .meta td { display:block; width:100%; }
            }
            @media print { body { padding:0; } .document { max-width:none; border:0; padding:18px 0; } }
          </style>
        </head>
        <body>
          <main class="document">
            <header>
              <h1>\(htmlEscape(document.title))</h1>
              <p class="subtitle">\(htmlEscape(document.meetingDate))　\(htmlEscape(document.subtitle))</p>
            </header>
            <div class="table-wrap"><table class="meta"><tbody>
              <tr><th>会议名称</th><td>\(htmlEscape(document.meetingName))</td><th>会议日期</th><td>\(htmlEscape(document.meetingDate))</td></tr>
              <tr><th>会议时间</th><td>\(htmlEscape("\(document.duration)；\(document.meetingTime)"))</td><th>会议类型</th><td>\(htmlEscape(document.meetingType ?? "待确认"))</td></tr>
              <tr><th>参会人员</th><td colspan="3">\(htmlEscape(participantSummary(document)))</td></tr>
              <tr><th>会议依据</th><td colspan="3">\(htmlEscape(document.sources.joined(separator: "；")))</td></tr>
            </tbody></table></div>
            <section><h2>一、会议摘要</h2><p>\(htmlParagraph(document.summary))</p>\(background)\(expectedProblem)\(factsBlock)</section>
            <section><h2>二、讨论纪要</h2>\(topicBlocks.isEmpty ? "<p>暂无可确认的议题，待人工复核。</p>" : topicBlocks)</section>
            <section><h2>三、会议结论与待确认事项</h2><h3>已形成结论</h3>\(conclusionsBlock)<h3>风险与待确认事项</h3>\(risksBlock)</section>
            <section><h2>四、后续行动</h2>\(actionsBlock)\(milestonesBlock)\(archiveBlock)</section>
            <p class="sensitive">\(htmlEscape(document.sensitiveNote))</p>
            <div class="signature"><p>AgendAI 会小纪整理</p><p>\(htmlEscape(document.preparedDate))</p></div>
          </main>
        </body>
        </html>
        """
    }

    private static func highFidelityHTMLCardLayout(_ document: MeetingMinutesDocument) -> String {
        let participantDetails = document.participantDetails ?? document.participants.map {
            MeetingMinutesParticipant(name: $0, role: "待确认", evidence: "待确认", status: "待确认")
        }
        let participantRows = participantDetails.isEmpty
            ? "<tr><td>待确认</td><td>待确认</td><td>待确认</td><td>待确认</td></tr>"
            : participantDetails.map { item in
                "<tr><td>\(htmlEscape(item.name))</td><td>\(htmlEscape(item.role))</td><td>\(htmlEscape(item.evidence))</td><td>\(htmlEscape(item.status))</td></tr>"
            }.joined(separator: "\n")
        let topicBlocks = effectiveMainTopics(document).enumerated().map { index, topic in
            let viewpoints = (topic.viewpoints ?? []).map { viewpoint in
                let evidence = viewpoint.evidence.map { "<span class=\"evidence\">依据：\(htmlEscape($0))</span>" } ?? ""
                return "<li><strong>\(htmlEscape(viewpoint.speaker))</strong>：\(htmlEscape(viewpoint.viewpoint))<span class=\"basis\">理由/依据：\(htmlEscape(viewpoint.basis))</span>\(evidence)</li>"
            }.joined(separator: "\n")
            let steps = (topic.discussionSteps ?? []).enumerated().map { stepIndex, step in
                "<li class=\"discussion-step\"><span class=\"step-index\">\(stepIndex + 1)</span><span class=\"step-kind\">\(htmlEscape(step.kind))</span><span class=\"step-time\">\(htmlEscape(step.timeRange))</span><span class=\"step-speaker\">\(htmlEscape(step.speaker))</span><span class=\"step-content\">\(htmlEscape(step.content))</span><span class=\"evidence\">原文依据：\(htmlEscape(step.evidence))</span></li>"
            }.joined(separator: "\n")
            let viewpointsBlock = viewpoints.isEmpty ? "" : "<h3>关键观点</h3><ul class=\"viewpoints\">\(viewpoints)</ul>"
            let stepsBlock: String
            if !steps.isEmpty {
                stepsBlock = "<h3>讨论推进</h3><ol class=\"discussion-steps\">\(steps)</ol>"
            } else if let process = topic.discussionProcess, !process.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stepsBlock = "<h3>讨论推进</h3><p>\(htmlParagraph(process))</p>"
            } else {
                stepsBlock = "<h3>讨论推进</h3><p>待确认。</p>"
            }
            return """
            <article class="discussion-topic">
              <h3>\(index + 1). \(htmlEscape(topic.topic))</h3>
              <dl class="topic-meta"><dt>时间范围</dt><dd>\(htmlEscape(topic.timeRange ?? "待确认"))</dd><dt>核心问题</dt><dd>\(htmlEscape(topic.question ?? "待确认"))</dd></dl>
              \(viewpointsBlock)
              \(stepsBlock)
              <div class="topic-outcome"><strong>形成结果</strong><p>\(htmlParagraph(topic.outcome ?? "待确认"))</p><p><strong>结果状态：</strong>\(htmlEscape(topic.status ?? "待确认"))</p><p class="evidence">原文依据：\(htmlEscape(topic.evidence ?? "待确认"))</p></div>
            </article>
            """
        }.joined(separator: "\n")
        let factRows = (document.keyFacts ?? []).map { item in
            "<tr><td>\(htmlEscape(item.item))</td><td>\(htmlEscape(item.value))</td><td>\(htmlEscape(item.nature))</td><td>\(htmlEscape(item.context))</td><td>\(htmlEscape(item.evidence))</td></tr>"
        }.joined(separator: "\n")
        let conclusionBlocks = document.conclusions.map { item in
            "<article class=\"decision-item\"><h3>\(htmlEscape(item.topic))</h3><p><strong>结论：</strong>\(htmlParagraph(item.conclusion))</p><p><strong>状态：</strong>\(htmlEscape(item.status ?? "待确认"))</p><p><strong>形成依据：</strong>\(htmlParagraph(item.rationale ?? "待确认"))</p><p><strong>适用范围/前提：</strong>\(htmlParagraph(item.scope ?? "待确认"))</p><p class=\"evidence\">原文依据：\(htmlEscape(item.evidence ?? "待确认"))</p></article>"
        }.joined(separator: "\n")
        let actionBlocks = document.actions.map { item in
            let owners = item.owners.isEmpty ? "待确认" : item.owners.joined(separator: "、")
            let dependencies = item.dependencies?.joined(separator: "、") ?? "待确认"
            return "<article class=\"action-item\"><h3>\(htmlEscape(item.action))</h3><dl><dt>责任人</dt><dd>\(htmlEscape(owners))</dd><dt>截止时间</dt><dd>\(htmlEscape(item.deadline))</dd><dt>交付物</dt><dd>\(htmlParagraph(item.deliverable ?? "待确认"))</dd><dt>依赖</dt><dd>\(htmlEscape(dependencies))</dd><dt>验收标准</dt><dd>\(htmlParagraph(item.acceptanceCriteria ?? "待确认"))</dd><dt>状态</dt><dd>\(htmlEscape(item.status ?? "待确认"))</dd></dl><p class=\"evidence\">原文依据：\(htmlEscape(item.evidence ?? "待确认"))</p></article>"
        }.joined(separator: "\n")
        let riskRows = document.risks.map { item in
            "<tr><td>\(htmlEscape(item.category ?? "待确认"))</td><td>\(htmlEscape(item.risk))</td><td>\(htmlEscape(item.impact))</td><td>\(htmlEscape(item.mitigation))</td><td>\(htmlEscape(item.nextStep ?? "待确认"))</td><td>\(htmlEscape(item.evidence ?? "待确认"))</td></tr>"
        }.joined(separator: "\n")
        let milestoneRows = document.milestones.map { item in
            "<tr><td>\(htmlEscape(item.date))</td><td>\(htmlEscape(item.target))</td></tr>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <meta name="color-scheme" content="light">
          <link rel="icon" href="data:,">
          <title>\(htmlEscape(document.title))</title>
          <style>
            :root { --ink:#25282a; --muted:#697177; --line:#d7dadd; --paper:#fff; --canvas:#eef0ef; --soft:#f5f6f5; --accent:#a9443d; --teal:#3c6264; --teal-soft:#edf4f3; --warning:#8a642c; }
            * { box-sizing:border-box; }
            html { scroll-behavior:smooth; }
            body { margin:0; background:var(--canvas); color:var(--ink); font-family:"PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif; font-size:15px; line-height:1.8; letter-spacing:0; overflow-wrap:anywhere; }
            .document { width:min(100% - 32px, 980px); margin:34px auto; padding:44px 52px 42px; background:var(--paper); border:1px solid var(--line); box-shadow:0 12px 34px rgba(33,40,42,.07); }
            h1 { margin:0; font-size:30px; line-height:1.35; text-align:center; }
            h2 { margin:0 0 12px; padding:7px 12px; background:var(--soft); border-left:4px solid var(--accent); font-size:18px; line-height:1.5; }
            h3 { margin:0 0 8px; font-size:16px; line-height:1.55; }
            .subtitle { margin:8px 0 26px; color:var(--muted); font-size:14px; text-align:center; }
            .rule { height:1px; margin:0 0 28px; background:var(--line); border:0; }
            .section { margin-top:31px; }
            .meta-table, .data-table { width:100%; border-collapse:collapse; table-layout:fixed; }
            .meta-table { margin-bottom:25px; font-size:13px; }
            .meta-table th, .meta-table td, .data-table th, .data-table td { padding:9px 12px; border:1px solid #aeb4b8; vertical-align:top; text-align:left; overflow-wrap:anywhere; }
            .meta-table th { width:112px; color:var(--teal); background:var(--teal-soft); white-space:nowrap; }
            .summary { margin:0 0 32px; padding:18px 20px 17px; background:#f7f8f7; border:1px solid var(--line); border-top:3px solid var(--teal); }
            .summary-label { display:block; margin-bottom:5px; color:var(--teal); font-size:12px; font-weight:700; }
            .summary p, .document p { margin:0 0 8px; }
            .discussion-topic, .decision-item, .action-item { margin:14px 0; padding:18px 20px; border:1px solid var(--line); border-left:3px solid var(--teal); background:#fcfcfb; }
            .topic-meta, .action-item dl { display:grid; grid-template-columns:max-content minmax(0,1fr); gap:5px 14px; margin:10px 0 15px; }
            dt { color:var(--teal); font-weight:700; }
            dd { margin:0; }
            .viewpoints, .discussion-steps { margin:8px 0 16px; padding-left:22px; }
            .viewpoints li { margin:5px 0; }
            .discussion-step { display:grid; grid-template-columns:28px max-content max-content max-content minmax(0,1fr); gap:6px 9px; margin:7px 0; padding:8px 10px; border-left:2px solid #cbd3d1; list-style:none; }
            .step-index { color:var(--muted); }
            .step-kind, .step-time { color:var(--accent); font-weight:700; }
            .step-speaker { color:var(--teal); font-weight:700; }
            .step-content { min-width:0; }
            .evidence { color:var(--muted); font-size:13px; }
            .basis { display:block; color:#4e585b; font-size:13px; }
            .data-table { font-size:13.5px; line-height:1.7; }
            .data-table th { background:#eef1f0; text-align:center; }
            .data-table tbody tr:nth-child(even) td { background:#fcfcfb; }
            .archive { padding:15px 17px; background:#fafafa; border:1px solid var(--line); }
            .note-item { margin:14px 0; padding:18px 20px; border:1px solid var(--line); background:#fcfcfb; }
            .note-image { margin:14px 0 0; }
            .note-image img { display:block; max-width:100%; max-height:720px; height:auto; border:1px solid var(--line); background:#fff; }
            .note-image figcaption { margin-top:5px; color:var(--muted); font-size:12px; }
            .sensitive-note { margin-top:10px !important; padding-top:10px; color:var(--warning); border-top:1px solid #e7dcc5; font-size:13px; }
            .footer { display:flex; justify-content:space-between; gap:20px; margin-top:36px; padding-top:15px; border-top:1px solid var(--line); color:var(--muted); font-size:12px; }
            @media (max-width: 720px) {
              body { font-size:14px; }
              .document { width:100%; margin:0; padding:30px 16px 28px; border:0; box-shadow:none; }
              h1 { font-size:24px; }
              .meta-table, .data-table { table-layout:auto; }
              .meta-table th, .meta-table td { display:block; width:100%; }
              .discussion-step { grid-template-columns:22px max-content max-content minmax(0,1fr); }
              .step-speaker { grid-column:2 / -1; }
              .step-content { grid-column:2 / -1; }
              .discussion-step .evidence { grid-column:2 / -1; }
              .footer { display:block; }
            }
            @media print { body { background:#fff; } .document { width:100%; margin:0; padding:18px 0; border:0; box-shadow:none; } }
          </style>
        </head>
        <body>
          <main class="document">
            <header><h1>\(htmlEscape(document.title))</h1><p class="subtitle">\(htmlEscape(document.meetingDate)) · \(htmlEscape(document.subtitle))</p><hr class="rule"></header>
            <section aria-label="会议基本信息"><table class="meta-table"><tbody><tr><th>会议名称</th><td>\(htmlEscape(document.meetingName))</td><th>会议日期</th><td>\(htmlEscape(document.meetingDate))</td></tr><tr><th>会议时间</th><td>\(htmlEscape("\(document.duration)；\(document.meetingTime)"))</td><th>会议类型</th><td>\(htmlEscape(document.meetingType ?? "待确认"))</td></tr><tr><th>参会人员</th><td colspan="3">\(htmlEscape(document.participants.joined(separator: "、")))</td></tr><tr><th>会议依据</th><td colspan="3">\(htmlEscape(document.sources.joined(separator: "；")))</td></tr></tbody></table></section>
            <section class="summary" aria-label="会议概览"><span class="summary-label">会议摘要</span><p>\(htmlParagraph(document.summary))</p><p><strong>背景与目的：</strong>\(htmlParagraph(document.backgroundAndPurpose ?? "待确认"))</p><p><strong>预期解决的问题：</strong>\(htmlParagraph(document.expectedProblem ?? "待确认"))</p></section>
            \(section(number: "03", title: "参会人员与角色线索", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>人员/称谓</th><th>角色线索</th><th>原文依据</th><th>状态</th></tr></thead><tbody>\(participantRows)</tbody></table></div>"))
            \(section(number: "04", title: "议题讨论还原", body: topicBlocks))
            \(section(number: "05", title: "关键事实与数字", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>事项</th><th>内容</th><th>性质</th><th>上下文</th><th>原文依据</th></tr></thead><tbody>\(factRows.isEmpty ? "<tr><td>暂无</td><td>待确认</td><td>待确认</td><td>待确认</td><td>待确认</td></tr>" : factRows)</tbody></table></div>"))
            \(section(number: "06", title: "决策与共识", body: conclusionBlocks.isEmpty ? "<p>暂无明确决策，待人工复核。</p>" : conclusionBlocks))
            \(section(number: "07", title: "行动项", body: actionBlocks.isEmpty ? "<p>暂无明确行动项，待人工复核。</p>" : actionBlocks))
            \(section(number: "08", title: "未决事项与风险", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>分类</th><th>事项</th><th>影响</th><th>处理要求</th><th>下一步</th><th>原文依据</th></tr></thead><tbody>\(riskRows.isEmpty ? "<tr><td>暂无</td><td>暂无</td><td>待确认</td><td>待确认</td><td>待确认</td><td>待确认</td></tr>" : riskRows)</tbody></table></div>"))
            \(section(number: "09", title: "时间节点与归档资料", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>节点</th><th>目标</th></tr></thead><tbody>\(milestoneRows.isEmpty ? "<tr><td>待确认</td><td>暂无明确时间节点</td></tr>" : milestoneRows)</tbody></table></div><div class=\"archive\"><p>归档资料：\(htmlEscape(document.archiveItems.joined(separator: "、")))。</p><p class=\"sensitive-note\">\(htmlEscape(document.sensitiveNote))</p></div>"))
            <footer class="footer"><span>整理日期：\(htmlEscape(document.preparedDate))</span><span>会议依据：\(htmlEscape(document.sources.joined(separator: "；")))</span></footer>
          </main>
        </body>
        </html>
        """
    }

    private static func legacyHTML(_ document: MeetingMinutesDocument) -> String {
        let mainTopicRows = effectiveMainTopics(document).enumerated().map { index, item in
            "<tr><td>\(index + 1)</td><td>\(htmlEscape(item.topic))</td><td>\(htmlParagraph(item.details))</td></tr>"
        }.joined(separator: "\n")
        let conclusionRows = document.conclusions.isEmpty
            ? #"<tr><td>1</td><td>暂无明确结论</td><td>待人工复核</td></tr>"#
            : document.conclusions.enumerated().map { index, item in
                "<tr><td>\(index + 1)</td><td>\(htmlEscape(item.topic))</td><td>\(htmlEscape(item.conclusion))</td></tr>"
            }.joined(separator: "\n")
        let actionRows = document.actions.isEmpty
            ? #"<tr><td>1</td><td>暂无明确行动项</td><td class="owner">待确认</td><td class="deadline">待确认</td></tr>"#
            : document.actions.enumerated().map { index, item in
                let owners = item.owners.isEmpty ? "待确认" : item.owners.joined(separator: "、")
                return "<tr><td>\(index + 1)</td><td>\(htmlEscape(item.action))</td><td class=\"owner\">\(htmlEscape(owners))</td><td class=\"deadline\">\(htmlEscape(item.deadline))</td></tr>"
            }.joined(separator: "\n")
        let riskRows = document.risks.isEmpty
            ? #"<tr><td>暂无明确风险</td><td>待人工复核</td><td>持续跟进</td></tr>"#
            : document.risks.map { item in
                "<tr><td>\(htmlEscape(item.risk))</td><td>\(htmlEscape(item.impact))</td><td>\(htmlEscape(item.mitigation))</td></tr>"
            }.joined(separator: "\n")
        let milestoneRows = document.milestones.isEmpty
            ? #"<tr><td>待确认</td><td>暂无明确时间节点</td></tr>"#
            : document.milestones.map { item in
                "<tr><td class=\"deadline\">\(htmlEscape(item.date))</td><td>\(htmlEscape(item.target))</td></tr>"
            }.joined(separator: "\n")
        let timeline = document.milestones.map { item in
            """
            <div class="timeline-item">
              <span class="timeline-date">\(htmlEscape(item.date))</span>
              <span class="timeline-text">\(htmlEscape(item.target))</span>
            </div>
            """
        }.joined(separator: "\n")
        let timelineBlock = timeline.isEmpty ? "" : "<div class=\"timeline\">\(timeline)</div>"

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <meta name="color-scheme" content="light">
          <title>\(htmlEscape(document.title))</title>
          <style>
            :root {
              --ink: #25282a; --muted: #697177; --line: #d7dadd; --line-strong: #aeb4b8;
              --paper: #ffffff; --canvas: #eef0ef; --soft: #f5f6f5; --accent: #a9443d;
              --accent-soft: #f8f0ee; --teal: #3c6264; --teal-soft: #edf4f3; --warning: #8a642c;
            }
            * { box-sizing: border-box; }
            html { scroll-behavior: smooth; }
            body { margin: 0; background: var(--canvas); color: var(--ink); font-family: "PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif; font-size: 15px; line-height: 1.85; letter-spacing: 0; -webkit-font-smoothing: antialiased; }
            .document { width: min(100% - 32px, 980px); margin: 34px auto; padding: 44px 52px 42px; background: var(--paper); border: 1px solid var(--line); box-shadow: 0 12px 34px rgba(33,40,42,.07); }
            .eyebrow { margin: 0 0 8px; color: var(--accent); font-size: 11px; font-weight: 700; text-align: center; }
            h1 { margin: 0; font-size: 30px; line-height: 1.35; text-align: center; letter-spacing: 0; }
            .subtitle { margin: 8px 0 26px; color: var(--muted); font-size: 14px; text-align: center; }
            .rule { height: 1px; margin: 0 0 28px; background: var(--line); border: 0; }
            .meta-table, .data-table { width: 100%; border-collapse: collapse; }
            .meta-table { margin-bottom: 25px; font-size: 13px; }
            .meta-table th, .meta-table td, .data-table th, .data-table td { padding: 9px 12px; border: 1px solid var(--line-strong); vertical-align: top; text-align: left; }
            .meta-table th { width: 112px; color: var(--teal); background: var(--teal-soft); white-space: nowrap; }
            .summary { margin: 0 0 32px; padding: 18px 20px 17px; background: #f7f8f7; border: 1px solid var(--line); border-top: 3px solid var(--teal); }
            .summary-label { display: block; margin-bottom: 5px; color: var(--teal); font-size: 12px; font-weight: 700; }
            .summary p, .document p { margin: 0; }
            .section { margin-top: 31px; }
            .section-heading { margin: 0 0 11px; padding: 7px 12px 7px 13px; background: var(--soft); border-left: 4px solid var(--accent); font-size: 17px; line-height: 1.5; }
            .section-number { margin-right: 10px; color: var(--accent); font-size: 12px; }
            .table-wrap { overflow-x: auto; margin: 0 -2px; }
            .data-table { margin: 0 0 7px; font-size: 13.5px; line-height: 1.7; }
            .data-table th { color: #333b3d; background: #eef1f0; text-align: center; white-space: nowrap; }
            .data-table td:first-child { text-align: center; }
            .data-table tbody tr:nth-child(even) td { background: #fcfcfb; }
            .owner { color: var(--teal); font-weight: 700; }
            .deadline { color: var(--accent); font-weight: 700; }
            .timeline { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; margin: 14px 0 18px; }
            .timeline-item { min-height: 94px; padding: 12px 13px; border-top: 3px solid var(--accent); background: var(--accent-soft); }
            .timeline-date { display: block; margin-bottom: 3px; color: var(--accent); font-size: 13px; font-weight: 700; }
            .timeline-text { display: block; color: #444b4d; font-size: 13px; line-height: 1.55; }
            .archive { padding: 15px 17px; background: #fafafa; border: 1px solid var(--line); color: #42494c; }
            .sensitive-note { margin-top: 10px !important; padding-top: 10px; color: var(--warning); border-top: 1px solid #e7dcc5; font-size: 13px; }
            .footer { display: flex; justify-content: space-between; gap: 20px; margin-top: 36px; padding-top: 15px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
            @media (max-width: 720px) {
              body { font-size: 14px; }
              .document { width: 100%; margin: 0; padding: 30px 16px 28px; border: 0; box-shadow: none; }
              h1 { font-size: 24px; }
              .data-table { min-width: 680px; }
              .meta-table th, .meta-table td { display: block; width: 100%; }
              .timeline { grid-template-columns: repeat(2, minmax(0, 1fr)); }
              .footer { display: block; }
            }
            @media print { body { background: #fff; } .document { width: 100%; margin: 0; padding: 18px 0; border: 0; box-shadow: none; } }
          </style>
        </head>
        <body>
          <main class="document">
            <header>
              <p class="eyebrow">MEETING MINUTES</p>
              <h1>\(htmlEscape(document.title))</h1>
              <p class="subtitle">\(htmlEscape(document.meetingDate)) · \(htmlEscape(document.subtitle))</p>
              <hr class="rule">
            </header>
            <section aria-label="会议基本信息">
              <table class="meta-table"><tbody>
                <tr><th>会议名称</th><td>\(htmlEscape(document.meetingName))</td><th>会议日期</th><td>\(htmlEscape(document.meetingDate))</td></tr>
                <tr><th>会议时间</th><td>\(htmlEscape("\(document.duration)；\(document.meetingTime)"))</td><th>参会人员</th><td>\(htmlEscape(document.participants.joined(separator: "、")))</td></tr>
                <tr><th>会议依据</th><td colspan="3">\(htmlEscape(document.sources.joined(separator: "；")))</td></tr>
              </tbody></table>
            </section>
            <section class="summary" aria-label="会议摘要"><span class="summary-label">会议摘要</span><p>\(htmlEscape(document.summary))</p></section>
            \(section(number: "01", title: "会议主要内容", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>序号</th><th>主要内容要点</th><th>详细说明</th></tr></thead><tbody>\(mainTopicRows)</tbody></table></div>"))
            \(section(number: "02", title: "主要结论", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>序号</th><th>事项</th><th>会议结论</th></tr></thead><tbody>\(conclusionRows)</tbody></table></div>"))
            \(section(number: "03", title: "后续行动项", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>序号</th><th>行动项</th><th>责任人</th><th>时间要求</th></tr></thead><tbody>\(actionRows)</tbody></table></div>"))
            \(section(number: "04", title: "主要风险及待确认事项", body: "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>风险/待确认事项</th><th>可能影响</th><th>处理要求</th></tr></thead><tbody>\(riskRows)</tbody></table></div>"))
            \(section(number: "05", title: "交付时间节点", body: timelineBlock + "<div class=\"table-wrap\"><table class=\"data-table\"><thead><tr><th>节点</th><th>目标</th></tr></thead><tbody>\(milestoneRows)</tbody></table></div>"))
            \(section(number: "06", title: "归档清单", body: "<div class=\"archive\"><p>\(htmlEscape(document.archiveItems.joined(separator: "、")))。</p><p class=\"sensitive-note\">\(htmlEscape(document.sensitiveNote))</p></div>"))
            <footer class="footer"><span>整理日期：\(htmlEscape(document.preparedDate))</span><span>会议依据：\(htmlEscape(document.sources.joined(separator: "；")))</span></footer>
          </main>
        </body>
        </html>
        """
    }

    private static func section(number: String, title: String, body: String) -> String {
        "<section class=\"section\"><h2 class=\"section-heading\"><span class=\"section-number\">\(number)</span>\(htmlEscape(title))</h2>\(body)</section>"
    }

    private static func effectiveMainTopics(_ document: MeetingMinutesDocument) -> [MeetingMinutesMainTopic] {
        let topics = (document.mainTopics ?? []).filter {
            !$0.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard topics.isEmpty else { return topics }
        return [MeetingMinutesMainTopic(
            topic: document.subtitle.isEmpty ? document.meetingName : document.subtitle,
            details: document.summary
        )]
    }

    private static func hasHighFidelityData(_ document: MeetingMinutesDocument) -> Bool {
        document.participantDetails != nil
            || document.keyFacts != nil
            || document.meetingType != nil
            || document.backgroundAndPurpose != nil
            || document.expectedProblem != nil
            || (document.mainTopics ?? []).contains { topic in
                topic.timeRange != nil
                    || topic.question != nil
                    || topic.viewpoints != nil
                    || topic.discussionSteps != nil
                    || topic.discussionProcess != nil
                    || topic.outcome != nil
                    || topic.status != nil
                    || topic.evidence != nil
            }
            || document.conclusions.contains { item in
                item.status != nil || item.rationale != nil || item.scope != nil || item.evidence != nil
            }
            || document.actions.contains { item in
                item.deliverable != nil
                    || item.dependencies != nil
                    || item.acceptanceCriteria != nil
                    || item.status != nil
                    || item.evidence != nil
            }
            || document.risks.contains { item in
                item.category != nil || item.nextStep != nil || item.evidence != nil
            }
    }

    private static func md(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func htmlParagraph(_ value: String) -> String {
        htmlEscape(value)
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

enum MeetingMinutesGenerationError: LocalizedError {
    case invalidStructuredOutput(details: String)
    case missingNoteImageData(filename: String)

    var errorDescription: String? {
        switch self {
        case .invalidStructuredOutput(let details):
            return "模型返回的会议纪要结构无效（\(details)）。"
        case .missingNoteImageData(let filename):
            return "笔记图片“\(filename)”原图未能从本地数据库读取。"
        }
    }
}
