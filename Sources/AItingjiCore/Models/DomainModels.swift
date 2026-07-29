import Foundation

public enum CaptureSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case screenAudio = "screen_audio"
    case appAudio = "app_audio"
    case systemAudio = "system_audio"
    case mixed
    case imported
}

public enum MeetingStatus: String, Codable, Sendable {
    case draft
    case permissionChecking = "permission_checking"
    case recording
    case paused
    case processing
    case done
    case failed
}

public enum MeetingHandoffStatus: String, Codable, Sendable, CaseIterable {
    case ignored
    case pending
    case processing
    case failed
    case completed
}

public enum DiarizationStatus: String, Codable, Sendable {
    case notStarted = "not_started"
    case temporary
    case corrected
    case final
    case failed
}

public enum DiarizationRunScope: String, Codable, Sendable {
    case rolling
    case full
}

public enum AudioCaptureTrack: String, Codable, Sendable {
    case microphone
    case computer
    case mixed
}

public enum DiarizationRunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
}

public enum ModelSourceType: String, Codable, Sendable, CaseIterable {
    case asr
    case voiceprint
    case postprocess
    case meetingMinutes = "meeting_minutes"
    case agent
}

/// 文本模型使用的 OpenAI API 协议。旧配置默认保持 Chat Completions。
public enum ModelAPIProtocol: String, Codable, Sendable, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses

    public var displayName: String {
        switch self {
        case .chatCompletions:
            return "Chat Completions"
        case .responses:
            return "Responses"
        }
    }
}

public enum MeetingNoteVisionStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case processing
    case completed
    case failed
}

public struct MeetingNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var meetingID: String
    public var body: String
    public var includeInMinutes: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingID: String,
        body: String = "",
        includeInMinutes: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.body = body
        self.includeInMinutes = includeInMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MeetingNoteImage: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var noteID: String
    public var filename: String
    public var mimeType: String
    public var originalData: Data?
    public var thumbnailData: Data
    public var sha256: String
    public var visionStatus: MeetingNoteVisionStatus
    public var visionText: String
    public var visionModel: String?
    public var visionPromptVersion: String?
    public var visionUpdatedAt: Date?
    public var visionError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        noteID: String,
        filename: String,
        mimeType: String,
        originalData: Data? = nil,
        thumbnailData: Data = Data(),
        sha256: String,
        visionStatus: MeetingNoteVisionStatus = .pending,
        visionText: String = "",
        visionModel: String? = nil,
        visionPromptVersion: String? = nil,
        visionUpdatedAt: Date? = nil,
        visionError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.noteID = noteID
        self.filename = filename
        self.mimeType = mimeType
        self.originalData = originalData
        self.thumbnailData = thumbnailData
        self.sha256 = sha256
        self.visionStatus = visionStatus
        self.visionText = visionText
        self.visionModel = visionModel
        self.visionPromptVersion = visionPromptVersion
        self.visionUpdatedAt = visionUpdatedAt
        self.visionError = visionError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MeetingNoteContent: Identifiable, Equatable, Sendable {
    public var note: MeetingNote
    public var images: [MeetingNoteImage]

    public var id: String { note.id }

    public init(note: MeetingNote, images: [MeetingNoteImage] = []) {
        self.note = note
        self.images = images
    }
}

public struct ModelSource: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var type: ModelSourceType
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public var apiProtocol: ModelAPIProtocol
    public var selectedModel: String?
    public var availableModels: [String]
    public var isDefault: Bool
    public var enabled: Bool
    public var meetingMinutesMaximumConcurrency: Int?
    public var supportsVision: Bool
    public var lastTestOK: Bool?
    public var lastTestMessage: String?
    public var lastTestAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, baseURL, apiKey, apiProtocol, selectedModel, availableModels
        case isDefault, enabled, meetingMinutesMaximumConcurrency, supportsVision
        case lastTestOK, lastTestMessage, lastTestAt
    }

    public init(
        id: String,
        type: ModelSourceType,
        name: String,
        baseURL: String,
        apiKey: String = "",
        apiProtocol: ModelAPIProtocol = .chatCompletions,
        selectedModel: String? = nil,
        availableModels: [String] = [],
        isDefault: Bool = false,
        enabled: Bool = true,
        meetingMinutesMaximumConcurrency: Int? = 1,
        supportsVision: Bool = false,
        lastTestOK: Bool? = nil,
        lastTestMessage: String? = nil,
        lastTestAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiProtocol = apiProtocol
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.isDefault = isDefault
        self.enabled = enabled
        self.meetingMinutesMaximumConcurrency = meetingMinutesMaximumConcurrency.map { max(1, $0) }
        self.supportsVision = supportsVision
        self.lastTestOK = lastTestOK
        self.lastTestMessage = lastTestMessage
        self.lastTestAt = lastTestAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let maximumConcurrency: Int?
        if container.contains(.meetingMinutesMaximumConcurrency) {
            maximumConcurrency = try container.decodeIfPresent(
                Int.self,
                forKey: .meetingMinutesMaximumConcurrency
            )
        } else {
            maximumConcurrency = 1
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            type: try container.decode(ModelSourceType.self, forKey: .type),
            name: try container.decode(String.self, forKey: .name),
            baseURL: try container.decode(String.self, forKey: .baseURL),
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
            apiProtocol: try container.decodeIfPresent(ModelAPIProtocol.self, forKey: .apiProtocol) ?? .chatCompletions,
            selectedModel: try container.decodeIfPresent(String.self, forKey: .selectedModel),
            availableModels: try container.decodeIfPresent([String].self, forKey: .availableModels) ?? [],
            isDefault: try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            meetingMinutesMaximumConcurrency: maximumConcurrency,
            supportsVision: try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false,
            lastTestOK: try container.decodeIfPresent(Bool.self, forKey: .lastTestOK),
            lastTestMessage: try container.decodeIfPresent(String.self, forKey: .lastTestMessage),
            lastTestAt: try container.decodeIfPresent(Date.self, forKey: .lastTestAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(apiProtocol, forKey: .apiProtocol)
        try container.encodeIfPresent(selectedModel, forKey: .selectedModel)
        try container.encode(availableModels, forKey: .availableModels)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(enabled, forKey: .enabled)
        if let meetingMinutesMaximumConcurrency {
            try container.encode(meetingMinutesMaximumConcurrency, forKey: .meetingMinutesMaximumConcurrency)
        } else {
            try container.encodeNil(forKey: .meetingMinutesMaximumConcurrency)
        }
        try container.encode(supportsVision, forKey: .supportsVision)
        try container.encodeIfPresent(lastTestOK, forKey: .lastTestOK)
        try container.encodeIfPresent(lastTestMessage, forKey: .lastTestMessage)
        try container.encodeIfPresent(lastTestAt, forKey: .lastTestAt)
    }
}

public struct VoiceprintPerson: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var aliases: [String]
    public var jobTitle: String
    public var roleTags: [String]
    public var responsibilities: String
    public var zentaoAccount: String
    public var zentaoUserID: String
    public var threshold: Double
    public var isActive: Bool

    public init(
        id: String,
        displayName: String,
        aliases: [String] = [],
        jobTitle: String = "",
        roleTags: [String] = [],
        responsibilities: String = "",
        zentaoAccount: String = "",
        zentaoUserID: String = "",
        threshold: Double = VoiceprintMatchingPolicy.minimumPersonThreshold,
        isActive: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.jobTitle = jobTitle
        self.roleTags = roleTags
        self.responsibilities = responsibilities
        self.zentaoAccount = zentaoAccount
        self.zentaoUserID = zentaoUserID
        self.threshold = threshold
        self.isActive = isActive
    }
}

public struct TerminologyEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var canonicalName: String
    public var aliases: [String]
    public var category: String
    public var notes: String
    public var isActive: Bool

    public init(
        id: String,
        canonicalName: String,
        aliases: [String] = [],
        category: String = "",
        notes: String = "",
        isActive: Bool = true
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.category = category
        self.notes = notes
        self.isActive = isActive
    }
}

public struct VoiceprintSample: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var personID: String
    public var sourceMeetingID: String?
    public var sourceSegmentID: String?
    public var embedding: [Double]
    public var audioRef: String?
    public var durationMs: Int
    public var qualityScore: Double
    public var createdAt: Date

    public init(
        id: String,
        personID: String,
        sourceMeetingID: String? = nil,
        sourceSegmentID: String? = nil,
        embedding: [Double],
        audioRef: String? = nil,
        durationMs: Int = 0,
        qualityScore: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.personID = personID
        self.sourceMeetingID = sourceMeetingID
        self.sourceSegmentID = sourceSegmentID
        self.embedding = embedding
        self.audioRef = audioRef
        self.durationMs = durationMs
        self.qualityScore = qualityScore
        self.createdAt = createdAt
    }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var meetingID: String
    public var startMs: Int
    public var endMs: Int
    public var speakerLabel: String
    public var autoSpeakerLabel: String
    /// 完整录音后重新转写时，文本来自的原始音轨。旧的混合轨记录为 nil。
    public var sourceTrack: AudioCaptureTrack?
    public var personID: String?
    public var personName: String?
    public var confidence: Double
    public var rawText: String
    public var processedText: String
    public var finalText: String
    public var isManual: Bool
    public var manualReason: String?

    public init(
        id: String,
        meetingID: String,
        startMs: Int,
        endMs: Int,
        speakerLabel: String,
        autoSpeakerLabel: String = "",
        sourceTrack: AudioCaptureTrack? = nil,
        personID: String? = nil,
        personName: String? = nil,
        confidence: Double = 0,
        rawText: String = "",
        processedText: String = "",
        finalText: String = "",
        isManual: Bool = false,
        manualReason: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startMs = startMs
        self.endMs = endMs
        self.speakerLabel = speakerLabel
        self.autoSpeakerLabel = autoSpeakerLabel
        self.sourceTrack = sourceTrack
        self.personID = personID
        self.personName = personName
        self.confidence = confidence
        self.rawText = rawText
        self.processedText = processedText
        self.finalText = finalText
        self.isManual = isManual
        self.manualReason = manualReason
    }
}

public struct MeetingRecordingInterval: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: String = UUID().uuidString,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: MeetingStatus
    public var captureSource: CaptureSource
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var recordingIntervals: [MeetingRecordingInterval]
    public var modelSnapshot: [String: String]
    public var voiceprintSnapshot: [String: String]
    public var isArchived: Bool
    public var handoffStatus: MeetingHandoffStatus
    public var handoffStartedAt: Date?
    public var handoffCompletedAt: Date?
    public var handoffContentHash: String?
    public var handoffError: String?
    public var audioFilePath: String?
    public var microphoneAudioFilePath: String?
    public var computerAudioFilePath: String?
    public var diarizationStatus: DiarizationStatus
    /// 最近一次标准会议纪要生成失败原因；保留原文后允许用户重试。
    public var minutesGenerationError: String?

    public init(
        id: String,
        title: String,
        status: MeetingStatus = .draft,
        captureSource: CaptureSource = .microphone,
        createdAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        recordingIntervals: [MeetingRecordingInterval] = [],
        modelSnapshot: [String: String] = [:],
        voiceprintSnapshot: [String: String] = [:],
        isArchived: Bool = false,
        handoffStatus: MeetingHandoffStatus = .ignored,
        handoffStartedAt: Date? = nil,
        handoffCompletedAt: Date? = nil,
        handoffContentHash: String? = nil,
        handoffError: String? = nil,
        audioFilePath: String? = nil,
        microphoneAudioFilePath: String? = nil,
        computerAudioFilePath: String? = nil,
        diarizationStatus: DiarizationStatus = .notStarted,
        minutesGenerationError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.captureSource = captureSource
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordingIntervals = recordingIntervals
        self.modelSnapshot = modelSnapshot
        self.voiceprintSnapshot = voiceprintSnapshot
        self.isArchived = isArchived
        self.handoffStatus = handoffStatus
        self.handoffStartedAt = handoffStartedAt
        self.handoffCompletedAt = handoffCompletedAt
        self.handoffContentHash = handoffContentHash
        self.handoffError = handoffError
        self.audioFilePath = audioFilePath
        self.microphoneAudioFilePath = microphoneAudioFilePath
        self.computerAudioFilePath = computerAudioFilePath
        self.diarizationStatus = diarizationStatus
        self.minutesGenerationError = minutesGenerationError
    }
}

public struct DiarizationRun: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var meetingID: String
    public var scope: DiarizationRunScope
    public var status: DiarizationRunStatus
    public var audioFilePath: String
    public var turns: [DiarizationTurn]
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: String,
        meetingID: String,
        scope: DiarizationRunScope,
        status: DiarizationRunStatus,
        audioFilePath: String,
        turns: [DiarizationTurn] = [],
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.scope = scope
        self.status = status
        self.audioFilePath = audioFilePath
        self.turns = turns
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}
