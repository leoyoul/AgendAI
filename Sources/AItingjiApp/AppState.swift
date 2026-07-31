import AItingjiCore
import AppKit
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

private struct FinalDiarizationSetupError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum AppStatePersistenceError: LocalizedError {
    case unavailable

    var errorDescription: String? { "本地数据库不可用" }
}

private struct StandardMinutesGenerationFailure: LocalizedError, Sendable {
    let attempts: Int
    let reason: String

    var errorDescription: String? {
        "连续 \(attempts) 次未生成标准会议纪要：\(reason)"
    }
}

enum RecordingStartupError: LocalizedError {
    case asrWarmup(String)

    var errorDescription: String? {
        switch self {
        case .asrWarmup(let detail):
            return RecordingStartupFailureMessage.asrWarmup(detail)
        }
    }
}

@MainActor
@Observable
final class AppState {
    static let meetingPageSize = 30
    private static let standardMinutesGenerationAttempts = 3
    private var store: AppPersistenceStore?
    @ObservationIgnored private var handoffChangeObserver: HandoffChangeObserver?
    private let modelTester = ModelSourceTester(loader: URLSessionDataLoader())
    private let meetingMinutesGenerator: MeetingMinutesGenerator
    private let meetingAnalysisGenerator: MeetingAnalysisGenerator
    private let debugLogStore: AppDebugLogStore
    private let permissionService = PermissionService()
    private var activeCapture: AudioCaptureSession?
    private(set) var activeRecordingMeetingID: Meeting.ID?
    private var liveChunkAccumulator = AudioChunkAccumulator(targetDurationMs: 10_000)
    private var liveRecordingOffsetMs = 0
    @ObservationIgnored private let captureCallbackBuffer = CaptureCallbackBuffer()
    @ObservationIgnored private var pendingTranscriptionQueue: PendingTranscriptionQueue?
    private var pendingTranscriptionWorkers: [Meeting.ID: Task<Void, Never>] = [:]
    private var pendingTranscriptionWriteCounts: [Meeting.ID: Int] = [:]
    private var unresolvedTranscriptionCounts: [Meeting.ID: Int] = [:]
    private var isStoppingCapture = false
    private var isCaptureTransitionInFlight = false
    private var postprocessingTasks: [Meeting.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var meetingMinutesGenerationTasks: [Meeting.ID: Task<Void, Never>] = [:]
    private var pendingPostprocessRecoveryMeetingIDs: Set<Meeting.ID> = []
    private(set) var postprocessingMeetingIDs: Set<Meeting.ID> = []
    private(set) var recentlyCompletedMeetingIDs: Set<Meeting.ID> = []
    private var recordingRetranscriptionTask: Task<Void, Never>?
    private(set) var recordingRetranscriptionMeetingID: Meeting.ID?
    var isPostprocessingSelectedMeeting: Bool {
        selectedMeetingID.map(isMeetingMinutesActive) ?? false
    }
    var isRecordingRetranscriptionSelectedMeeting: Bool {
        recordingRetranscriptionMeetingID == selectedMeetingID
    }
    var isPersistenceAvailable: Bool {
        store != nil
    }
    var isCaptureTransitioning: Bool {
        isCaptureTransitionInFlight || isStoppingCapture
    }
    private var meetingAudioWriters: MeetingAudioTrackWriters?
    private var pausedCaptureSource: CaptureSource?
    var meetings: [Meeting]
    var visibleMeetings: [Meeting]
    var visibleMeetingLimit = AppState.meetingPageSize
    var selectedMeetingID: Meeting.ID?
    var selectedCaptureSource: CaptureSource = .microphone
    var microphoneDevices: [MicrophoneDeviceDescriptor] = []
    var selectedMicrophoneDeviceID = ""
    var segmentsByMeeting: [Meeting.ID: [TranscriptSegment]]
    var notesByMeeting: [Meeting.ID: [MeetingNote]]
    var noteImagesByMeeting: [Meeting.ID: [MeetingNoteImage]]
    var modelSources: [ModelSource]
    var people: [VoiceprintPerson]
    var terminologyEntries: [TerminologyEntry]
    var voiceprintSamples: [VoiceprintSample]
    var diarizationRunsByMeeting: [Meeting.ID: [DiarizationRun]]
    var diarizationMappingsByMeeting: [Meeting.ID: [DiarizationSpeakerMapping]]
    var diarizationSpeakerPreset: DiarizationSpeakerPreset
    var postprocessPrompt: String
    var meetingMinutesPrompt: String
    var meetingAnalysisPrompt: String
    var knowledgeBaseConfiguration: DifyKnowledgeBaseConfiguration
    var currentUserPersonID: VoiceprintPerson.ID?
    var meetingAgentWorkspacePath: String
    var meetingAgentMessagesByMeeting: [Meeting.ID: [MeetingAgentChatMessage]]
    private(set) var meetingAgentContextUsageByMeeting: [Meeting.ID: MeetingAgentContextUsage] = [:]
    private(set) var meetingAgentSessionStatsByMeeting: [Meeting.ID: PiAgentSessionStats] = [:]
    private(set) var meetingAgentRespondingIDs: Set<Meeting.ID> = []
    private(set) var meetingAgentContextNotices: [Meeting.ID: String] = [:]
    @ObservationIgnored private var meetingAgentResponseTasks: [Meeting.ID: Task<Void, Never>] = [:]
    var permissionSnapshot = CapturePermissionSnapshot()
    var exportPreview = ""
    private(set) var meetingMinutesArtifacts: [Meeting.ID: MeetingMinutesArtifact] = [:]
    private(set) var generatingMeetingMinutesIDs: Set<Meeting.ID> = []
    private(set) var debugLogEntries: [AppDebugLogEntry] = []
    private var debugPersistedMeetingsByID: [Meeting.ID: Meeting] = [:]
    private(set) var meetingAnalysisArtifacts: [Meeting.ID: MeetingAnalysisArtifact] = [:]
    private(set) var generatingMeetingAnalysisIDs: Set<Meeting.ID> = []
    @ObservationIgnored private var meetingAnalysisTasks: [Meeting.ID: Task<Void, Never>] = [:]
    var statusMessage = "正在加载本地数据。"
    var libraryStatusMessage = ""
    var recordingStartupState: RecordingStartupState = .idle
    var recordingStartupError: String?
    var canSwitchFailedStartToMicrophone = false
    var inputLevel: Double = 0.18
    private(set) var recordingElapsedMs = 0

    var shouldShowSelectedMeetingRecordingTimer: Bool {
        activeRecordingMeetingID == selectedMeetingID
            && (recordingStartupState == .starting
                || recordingStartupState == .recording
                || recordingStartupState == .paused)
    }

    var hasActiveRecording: Bool {
        activeRecordingMeetingID != nil
    }

    func isMeetingRecording(_ meetingID: Meeting.ID) -> Bool {
        activeRecordingMeetingID == meetingID
            && (recordingStartupState == .starting
                || recordingStartupState == .recording
                || recordingStartupState == .paused)
    }

    func isMeetingPostprocessing(_ meetingID: Meeting.ID) -> Bool {
        postprocessingMeetingIDs.contains(meetingID)
    }

    func isMeetingMinutesActive(_ meetingID: Meeting.ID) -> Bool {
        postprocessingMeetingIDs.contains(meetingID)
            || generatingMeetingMinutesIDs.contains(meetingID)
    }

    func isMeetingProtectedFromMutation(_ meetingID: Meeting.ID) -> Bool {
        activeRecordingMeetingID == meetingID
            || isMeetingMinutesActive(meetingID)
            || generatingMeetingAnalysisIDs.contains(meetingID)
    }

    func isMeetingContentLocked(_ meetingID: Meeting.ID) -> Bool {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            return true
        }
        return meeting.isArchived
            || isMeetingMinutesActive(meetingID)
    }

    var isSelectedMeetingContentLocked: Bool {
        selectedMeetingID.map(isMeetingContentLocked) ?? true
    }

    func acknowledgeMeetingCompletion(_ meetingID: Meeting.ID) {
        recentlyCompletedMeetingIDs.remove(meetingID)
    }

    var calendarActiveMeetingID: Meeting.ID? {
        recordingStartupState == .recording ? activeRecordingMeetingID : nil
    }

    var selectedMicrophoneDevice: MicrophoneDeviceDescriptor? {
        microphoneDevices.first { $0.id == selectedMicrophoneDeviceID }
    }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selectedMeetingID }
    }

    @discardableResult
    func selectMeeting(_ meetingID: Meeting.ID) -> Bool {
        guard meetings.contains(where: { $0.id == meetingID }) else {
            return false
        }
        selectedMeetingID = meetingID
        refreshExportPreview()
        refreshSelectedMeetingMinutes()
        refreshSelectedMeetingAnalysis()
        return true
    }

    var archivedMeetings: [Meeting] {
        meetings
            .filter(\.isArchived)
            .sorted { $0.createdAt > $1.createdAt }
    }

    var unarchivedMeetingCount: Int {
        meetings.lazy.filter { !$0.isArchived }.count
    }

    var selectedSegments: [TranscriptSegment] {
        guard let selectedMeetingID else {
            return []
        }
        return segmentsByMeeting[selectedMeetingID, default: []].sorted { $0.startMs < $1.startMs }
    }

    var selectedMeetingNotes: [MeetingNoteContent] {
        guard let selectedMeetingID else { return [] }
        return meetingNoteContents(meetingID: selectedMeetingID)
    }

    func meetingNoteContents(meetingID: Meeting.ID) -> [MeetingNoteContent] {
        let imagesByNote = Dictionary(grouping: noteImagesByMeeting[meetingID, default: []], by: \.noteID)
        return notesByMeeting[meetingID, default: []]
            .sorted { $0.createdAt < $1.createdAt }
            .map { MeetingNoteContent(note: $0, images: imagesByNote[$0.id, default: []]) }
    }

    var selectedMeetingMinutesArtifact: MeetingMinutesArtifact? {
        guard let selectedMeetingID else { return nil }
        return meetingMinutesArtifacts[selectedMeetingID]
    }

    var selectedMeetingMinutesGenerationError: String? {
        selectedMeeting?.minutesGenerationError
    }

    var selectedMeetingHasIncludedImages: Bool {
        selectedMeetingNotes.contains { content in
            content.note.includeInMinutes && !content.images.isEmpty
        }
    }

    var selectedMeetingMinutesVisionWarning: String? {
        guard selectedMeetingHasIncludedImages else { return nil }
        guard let source = defaultModelSource(type: .agent) else { return nil }
        guard source.supportsVision else {
            return "本场包含纳入纪要的图片笔记，请在 Agent 模型配置中开启“支持视觉输入”，并使用多模态模型。"
        }
        return nil
    }

    var debugMeetingStates: [MeetingDebugState] {
        meetings
            .sorted { $0.createdAt > $1.createdAt }
            .map { meeting in
                let persisted = debugPersistedMeetingsByID[meeting.id]
                return MeetingDebugState(
                    id: meeting.id,
                    title: meeting.title,
                    memoryStatus: meeting.status,
                    persistedStatus: persisted?.status,
                    memoryArchived: meeting.isArchived,
                    persistedArchived: persisted?.isArchived,
                    automaticMinutesActive: postprocessingMeetingIDs.contains(meeting.id),
                    manualMinutesActive: generatingMeetingMinutesIDs.contains(meeting.id),
                    recoveryPending: pendingPostprocessRecoveryMeetingIDs.contains(meeting.id),
                    analysisActive: generatingMeetingAnalysisIDs.contains(meeting.id),
                    hasMinutesArtifact: meetingMinutesArtifacts[meeting.id] != nil,
                    minutesGenerationError: meeting.minutesGenerationError
                )
            }
    }

    var selectedMeetingAnalysisArtifact: MeetingAnalysisArtifact? {
        guard let selectedMeetingID else { return nil }
        return meetingAnalysisArtifacts[selectedMeetingID]
    }

    var isGeneratingSelectedMeetingMinutes: Bool {
        guard let selectedMeetingID else { return false }
        return generatingMeetingMinutesIDs.contains(selectedMeetingID)
            || postprocessingMeetingIDs.contains(selectedMeetingID)
    }

    var hasEnabledMeetingMinutesModel: Bool {
        defaultModelSource(type: .agent) != nil
    }

    var canGenerateSelectedMeetingMinutes: Bool {
        guard let selectedMeetingID, !selectedSegments.isEmpty else { return false }
        return hasEnabledMeetingMinutesModel
            && selectedMeetingMinutesVisionWarning == nil
            && !isMeetingRecording(selectedMeetingID)
            && !isMeetingPostprocessing(selectedMeetingID)
            && !generatingMeetingMinutesIDs.contains(selectedMeetingID)
    }

    var isGeneratingSelectedMeetingAnalysis: Bool {
        guard let selectedMeetingID else { return false }
        return generatingMeetingAnalysisIDs.contains(selectedMeetingID)
    }

    var canGenerateSelectedMeetingAnalysis: Bool {
        guard let selectedMeetingID,
              selectedMeetingMinutesArtifact != nil,
              !selectedSegments.isEmpty else { return false }
        return defaultModelSource(type: .agent) != nil
            && !isMeetingRecording(selectedMeetingID)
            && !isMeetingPostprocessing(selectedMeetingID)
            && !generatingMeetingMinutesIDs.contains(selectedMeetingID)
            && !generatingMeetingAnalysisIDs.contains(selectedMeetingID)
    }

    init(
        storeFactory: () throws -> AppPersistenceStore = { try AppPersistenceStore() },
        pendingTranscriptionRootURL: URL? = nil,
        resumePendingTranscriptions: Bool = true,
        meetingMinutesGenerator: MeetingMinutesGenerator = MeetingMinutesGenerator(),
        meetingAnalysisGenerator: MeetingAnalysisGenerator = MeetingAnalysisGenerator(),
        debugLogStore: AppDebugLogStore = AppDebugLogStore()
    ) {
        self.meetingMinutesGenerator = meetingMinutesGenerator
        self.meetingAnalysisGenerator = meetingAnalysisGenerator
        self.debugLogStore = debugLogStore
        pendingTranscriptionQueue = try? PendingTranscriptionQueue(
            rootDirectoryURL: pendingTranscriptionRootURL ?? Self.pendingTranscriptionRootURL
        )
        var persistedMicrophoneDeviceID: String?
        var persistedMeetingAgentWorkspacePath: String?
        var shouldSeedMeetingMinutesModel = true
        var shouldPersistMeetingMinutesPromptUpgrade = false
        do {
            let store = try storeFactory()
            self.store = store
            let snapshot = try store.loadSnapshot()
            if snapshot.meetings.isEmpty {
                meetings = snapshot.meetings
                visibleMeetings = []
                selectedMeetingID = nil
                selectedCaptureSource = .microphone
                segmentsByMeeting = snapshot.segmentsByMeeting
                notesByMeeting = snapshot.notesByMeeting
                noteImagesByMeeting = snapshot.noteImagesByMeeting
                people = snapshot.people
                terminologyEntries = snapshot.terminologyEntries
                voiceprintSamples = snapshot.voiceprintSamples
                diarizationRunsByMeeting = snapshot.diarizationRunsByMeeting
                diarizationMappingsByMeeting = snapshot.diarizationMappingsByMeeting
                meetingAgentMessagesByMeeting = snapshot.meetingAgentMessagesByMeeting
                modelSources = snapshot.modelSources
                diarizationSpeakerPreset = DiarizationSpeakerPreset.parse(
                    snapshot.appSettings[AppSettingKey.diarizationSpeakerPreset]
                )
                postprocessPrompt = snapshot.appSettings[AppSettingKey.postprocessPrompt] ?? PostprocessPrompt.defaultMouthFillerCleanup
                let storedMeetingMinutesPrompt = snapshot.appSettings[AppSettingKey.meetingMinutesPrompt] ?? PostprocessPrompt.meetingMinutes
                if snapshot.appSettings[AppSettingKey.meetingMinutesPromptVersion] == PostprocessPrompt.meetingMinutesPromptVersion {
                    meetingMinutesPrompt = storedMeetingMinutesPrompt
                } else {
                    meetingMinutesPrompt = PostprocessPrompt.upgradedMeetingMinutesPrompt(storedMeetingMinutesPrompt)
                    shouldPersistMeetingMinutesPromptUpgrade = true
                }
                meetingAnalysisPrompt = snapshot.appSettings[AppSettingKey.meetingAnalysisPrompt] ?? PostprocessPrompt.meetingAnalysis
                knowledgeBaseConfiguration = Self.decodeKnowledgeBaseConfiguration(
                    snapshot.appSettings[AppSettingKey.difyKnowledgeBaseConfiguration]
                )
                currentUserPersonID = snapshot.appSettings[AppSettingKey.currentUserPersonID]
                    .flatMap { $0.isEmpty ? nil : $0 }
                persistedMeetingAgentWorkspacePath = snapshot.appSettings[AppSettingKey.meetingAgentWorkspacePath]
                pendingPostprocessRecoveryMeetingIDs = Self.decodePostprocessRecoveryMeetingIDs(
                    snapshot.appSettings[AppSettingKey.pendingPostprocessMeetingIDs]
                )
                persistedMicrophoneDeviceID = snapshot.appSettings[AppSettingKey.microphoneDeviceID]
                shouldSeedMeetingMinutesModel = snapshot.appSettings[AppSettingKey.meetingMinutesModelSeeded] != "true"
                statusMessage = "本地数据库已初始化，请新建会议并配置 ASR 服务后开始录音。"
            } else {
                meetings = snapshot.meetings
                let initialVisibleMeetings = Self.visibleMeetings(from: snapshot.meetings, limit: Self.meetingPageSize)
                visibleMeetings = initialVisibleMeetings
                selectedMeetingID = initialVisibleMeetings.first?.id
                selectedCaptureSource = Self.normalizedCaptureSource(snapshot.meetings.first?.captureSource ?? .microphone)
                segmentsByMeeting = snapshot.segmentsByMeeting
                notesByMeeting = snapshot.notesByMeeting
                noteImagesByMeeting = snapshot.noteImagesByMeeting
                people = snapshot.people
                terminologyEntries = snapshot.terminologyEntries
                voiceprintSamples = snapshot.voiceprintSamples
                diarizationRunsByMeeting = snapshot.diarizationRunsByMeeting
                diarizationMappingsByMeeting = snapshot.diarizationMappingsByMeeting
                meetingAgentMessagesByMeeting = snapshot.meetingAgentMessagesByMeeting
                modelSources = snapshot.modelSources
                diarizationSpeakerPreset = DiarizationSpeakerPreset.parse(
                    snapshot.appSettings[AppSettingKey.diarizationSpeakerPreset]
                )
                postprocessPrompt = snapshot.appSettings[AppSettingKey.postprocessPrompt] ?? PostprocessPrompt.defaultMouthFillerCleanup
                let storedMeetingMinutesPrompt = snapshot.appSettings[AppSettingKey.meetingMinutesPrompt] ?? PostprocessPrompt.meetingMinutes
                if snapshot.appSettings[AppSettingKey.meetingMinutesPromptVersion] == PostprocessPrompt.meetingMinutesPromptVersion {
                    meetingMinutesPrompt = storedMeetingMinutesPrompt
                } else {
                    meetingMinutesPrompt = PostprocessPrompt.upgradedMeetingMinutesPrompt(storedMeetingMinutesPrompt)
                    shouldPersistMeetingMinutesPromptUpgrade = true
                }
                meetingAnalysisPrompt = snapshot.appSettings[AppSettingKey.meetingAnalysisPrompt] ?? PostprocessPrompt.meetingAnalysis
                knowledgeBaseConfiguration = Self.decodeKnowledgeBaseConfiguration(
                    snapshot.appSettings[AppSettingKey.difyKnowledgeBaseConfiguration]
                )
                currentUserPersonID = snapshot.appSettings[AppSettingKey.currentUserPersonID]
                    .flatMap { $0.isEmpty ? nil : $0 }
                persistedMeetingAgentWorkspacePath = snapshot.appSettings[AppSettingKey.meetingAgentWorkspacePath]
                pendingPostprocessRecoveryMeetingIDs = Self.decodePostprocessRecoveryMeetingIDs(
                    snapshot.appSettings[AppSettingKey.pendingPostprocessMeetingIDs]
                )
                persistedMicrophoneDeviceID = snapshot.appSettings[AppSettingKey.microphoneDeviceID]
                shouldSeedMeetingMinutesModel = snapshot.appSettings[AppSettingKey.meetingMinutesModelSeeded] != "true"
            }
        } catch {
            store = nil
            let defaults = Self.defaultSnapshot()
            meetings = defaults.meetings
            visibleMeetings = []
            selectedMeetingID = nil
            selectedCaptureSource = .microphone
            segmentsByMeeting = defaults.segmentsByMeeting
            notesByMeeting = defaults.notesByMeeting
            noteImagesByMeeting = defaults.noteImagesByMeeting
            people = defaults.people
            terminologyEntries = defaults.terminologyEntries
            voiceprintSamples = defaults.voiceprintSamples
            diarizationRunsByMeeting = defaults.diarizationRunsByMeeting
            diarizationMappingsByMeeting = defaults.diarizationMappingsByMeeting
            meetingAgentMessagesByMeeting = defaults.meetingAgentMessagesByMeeting
            modelSources = defaults.modelSources
            diarizationSpeakerPreset = DiarizationSpeakerPreset.parse(
                defaults.appSettings[AppSettingKey.diarizationSpeakerPreset]
            )
            postprocessPrompt = defaults.appSettings[AppSettingKey.postprocessPrompt] ?? PostprocessPrompt.defaultMouthFillerCleanup
            meetingMinutesPrompt = defaults.appSettings[AppSettingKey.meetingMinutesPrompt] ?? PostprocessPrompt.meetingMinutes
            meetingAnalysisPrompt = defaults.appSettings[AppSettingKey.meetingAnalysisPrompt] ?? PostprocessPrompt.meetingAnalysis
            knowledgeBaseConfiguration = Self.decodeKnowledgeBaseConfiguration(
                defaults.appSettings[AppSettingKey.difyKnowledgeBaseConfiguration]
            )
            currentUserPersonID = nil
            persistedMeetingAgentWorkspacePath = defaults.appSettings[AppSettingKey.meetingAgentWorkspacePath]
            pendingPostprocessRecoveryMeetingIDs = []
            persistedMicrophoneDeviceID = defaults.appSettings[AppSettingKey.microphoneDeviceID]
            shouldSeedMeetingMinutesModel = false
            statusMessage = "本地数据库不可用：\(error.localizedDescription)。为避免数据丢失，已禁用录音和编辑。"
        }
        meetingAgentWorkspacePath = Self.normalizedMeetingAgentWorkspacePath(
            persistedMeetingAgentWorkspacePath
        )
        if shouldPersistMeetingMinutesPromptUpgrade {
            persistAppSetting(AppSettingKey.meetingMinutesPrompt, value: meetingMinutesPrompt)
            persistAppSetting(
                AppSettingKey.meetingMinutesPromptVersion,
                value: PostprocessPrompt.meetingMinutesPromptVersion
            )
        }
        removeGeneratedPlaceholderAliasesIfNeeded()
        pruneStalePostprocessRecoveryMarkers()
        recoverInterruptedMeetingsIfNeeded()
        refreshMicrophoneDevices(preferredDeviceID: persistedMicrophoneDeviceID)
        migrateExampleASRToLocalDefaultIfNeeded()
        disableExamplePostprocessSourceIfNeeded()
        _ = shouldSeedMeetingMinutesModel // 旧配置仅保留兼容；原始纪要现由 Agent 生成。
        enforceSingleEnabledASRSourceIfNeeded()
        refreshVisibleMeetings()
        refreshPermissionStatus()
        refreshExportPreview()
        restoreMeetingMinutesArtifacts()
        restoreMeetingAnalysisArtifacts()
        refreshDebugLogPage()
        appendDebugLog(category: "应用", message: "应用启动，已加载 \(meetings.count) 场会议。")
        recoverInterruptedMeetingAgentMessages()
        if resumePendingTranscriptions {
            Task { [weak self] in
                await self?.resumeBackgroundProcessingIfNeeded()
            }
        }
    }

    @discardableResult
    func createMeeting() -> Meeting.ID? {
        guard ensurePersistenceAvailable(action: "新建会议") else {
            return nil
        }
        let meeting = Meeting(
            id: UUID().uuidString,
            title: "新会议 \(meetings.count + 1)",
            status: .draft,
            captureSource: selectedCaptureSource,
            createdAt: Date()
        )
        guard let store else {
            statusMessage = "本地数据库不可用，不能新建会议。"
            return nil
        }
        do {
            try MeetingCollectionPolicy.insert(meeting, into: &meetings) { meeting in
                try store.upsertMeeting(meeting)
            }
        } catch {
            statusMessage = "会议保存失败：\(error.localizedDescription)"
            return nil
        }
        segmentsByMeeting[meeting.id] = []
        diarizationRunsByMeeting[meeting.id] = []
        diarizationMappingsByMeeting[meeting.id] = []
        selectedMeetingID = meeting.id
        refreshVisibleMeetings()
        exportPreview = ""
        statusMessage = "已创建会议，开始录音后会写入实时片段。"
        return meeting.id
    }

    func updateSelectedMeetingTitle(_ title: String) {
        guard ensurePersistenceAvailable(action: "编辑会议") else {
            return
        }
        guard let selectedMeetingID else {
            statusMessage = "请先选择会议。"
            return
        }
        guard !isMeetingContentLocked(selectedMeetingID) else {
            statusMessage = contentLockMessage(for: selectedMeetingID)
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "会议标题不能为空。"
            return
        }
        updateMeeting(id: selectedMeetingID) { meeting in
            meeting.title = trimmed
        }
        refreshVisibleMeetings()
        refreshExportPreview()
        statusMessage = "会议标题已保存。"
    }

    func loadMoreMeetings() {
        visibleMeetingLimit += Self.meetingPageSize
        refreshVisibleMeetings()
    }

    @discardableResult
    func archiveMeeting(_ meetingID: Meeting.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "归档会议") else {
            return false
        }
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            return false
        }
        guard !isMeetingProtectedFromMutation(meetingID) else {
            statusMessage = "录音或会议纪要生成中，不能归档当前会议。"
            return false
        }
        guard let store else {
            statusMessage = "本地数据库不可用，不能归档会议。"
            return false
        }

        do {
            try store.setMeetingArchived(id: meetingID, isArchived: true)
            guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
                  !meetings[index].isArchived else {
                return false
            }
            meetings[index].isArchived = true
            refreshVisibleMeetings()
            statusMessage = "会议已归档：\(meeting.title)。"
            appendDebugLog(category: "归档", message: "会议已归档。", meetingID: meetingID)
            return true
        } catch {
            statusMessage = "会议归档失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func restoreMeeting(_ meetingID: Meeting.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "恢复会议"),
              let meeting = meetings.first(where: { $0.id == meetingID }),
              meeting.isArchived,
              let store else {
            return false
        }
        do {
            try store.setMeetingArchived(
                id: meetingID,
                isArchived: false
            )
            if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
                meetings[index].isArchived = false
                meetings[index].handoffStatus = .ignored
                meetings[index].handoffStartedAt = nil
                meetings[index].handoffCompletedAt = nil
                meetings[index].handoffContentHash = nil
                meetings[index].handoffError = nil
            }
            refreshVisibleMeetings()
            statusMessage = "会议已恢复：\(meeting.title)。"
            appendDebugLog(category: "归档", message: "会议已从归档恢复。", meetingID: meetingID)
            return true
        } catch {
            statusMessage = "会议恢复失败：\(error.localizedDescription)"
            return false
        }
    }

    func startObservingHandoffChanges() {
        guard handoffChangeObserver == nil else {
            return
        }
        handoffChangeObserver = HandoffChangeObserver { [weak self] in
            Task { @MainActor in
                self?.refreshHandoffStateFromPersistence()
            }
        }
    }

    func refreshHandoffStateFromPersistence() {
        guard let store else {
            return
        }
        do {
            let persistedMeetings = try store.loadMeetings()
            let persistedByID = Dictionary(uniqueKeysWithValues: persistedMeetings.map { ($0.id, $0) })
            for index in meetings.indices {
                guard let persisted = persistedByID[meetings[index].id] else {
                    continue
                }
                let current = meetings[index]
                let taskWasCancelled = persisted.isArchived && isMeetingProtectedFromMutation(current.id)
                if taskWasCancelled {
                    cancelMeetingWorkForExternalArchive(meetingID: current.id)
                }
                if current != persisted {
                    appendDebugLog(
                        category: "同步",
                        message: "检测到外部状态更新：\(current.status.rawValue)/归档=\(current.isArchived) -> \(persisted.status.rawValue)/归档=\(persisted.isArchived)。",
                        meetingID: current.id
                    )
                }
                // The handoff process owns only the confirmed title and archive fields.
                // Keep local recording/transcription state intact unless an active task was cancelled.
                var merged = current
                merged.title = persisted.title
                merged.isArchived = persisted.isArchived
                merged.handoffStatus = persisted.handoffStatus
                merged.handoffStartedAt = persisted.handoffStartedAt
                merged.handoffCompletedAt = persisted.handoffCompletedAt
                merged.handoffContentHash = persisted.handoffContentHash
                merged.handoffError = persisted.handoffError
                if taskWasCancelled {
                    merged.status = .failed
                    merged.minutesGenerationError = "会议已被外部归档，正在生成的会议纪要已取消。"
                }
                meetings[index] = merged
            }
            debugPersistedMeetingsByID = persistedByID
            refreshVisibleMeetings()
            refreshExportPreview()
        } catch {
            statusMessage = "交接状态刷新失败：\(error.localizedDescription)"
        }
    }

    func refreshDebugLogPage() {
        debugLogEntries = debugLogStore.load()
        guard let store else {
            debugPersistedMeetingsByID = [:]
            return
        }
        do {
            let persistedMeetings = try store.loadMeetings()
            debugPersistedMeetingsByID = Dictionary(uniqueKeysWithValues: persistedMeetings.map { ($0.id, $0) })
        } catch {
            statusMessage = "调试状态读取失败：\(error.localizedDescription)"
        }
    }

    private func appendDebugLog(category: String, message: String, meetingID: Meeting.ID? = nil) {
        let entry = AppDebugLogEntry(category: category, message: message, meetingID: meetingID)
        do {
            try debugLogStore.append(entry)
            debugLogEntries.insert(entry, at: 0)
            if debugLogEntries.count > 500 {
                debugLogEntries.removeLast(debugLogEntries.count - 500)
            }
        } catch {
            statusMessage = "调试日志写入失败：\(error.localizedDescription)"
        }
    }

    private func cancelMeetingWorkForExternalArchive(meetingID: Meeting.ID) {
        postprocessingTasks[meetingID]?.cancel()
        postprocessingTasks.removeValue(forKey: meetingID)
        meetingMinutesGenerationTasks[meetingID]?.cancel()
        meetingMinutesGenerationTasks.removeValue(forKey: meetingID)
        meetingAnalysisTasks[meetingID]?.cancel()
        meetingAnalysisTasks.removeValue(forKey: meetingID)
        postprocessingMeetingIDs.remove(meetingID)
        generatingMeetingMinutesIDs.remove(meetingID)
        generatingMeetingAnalysisIDs.remove(meetingID)
        _ = setPostprocessRecoveryPending(false, meetingID: meetingID)
        appendDebugLog(category: "归档", message: "检测到外部归档，已取消正在运行的会议任务。", meetingID: meetingID)
    }

    @discardableResult
    func deleteMeeting(_ meetingID: Meeting.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "删除会议") else {
            return false
        }
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            return false
        }
        guard !isMeetingProtectedFromMutation(meetingID) else {
            statusMessage = "录音、会议纪要或 AI 分析进行中，不能删除当前会议。"
            return false
        }

        guard let store else {
            statusMessage = "本地数据库不可用，不能删除会议。"
            return false
        }
        do {
            try store.deleteMeeting(id: meetingID)
            let audioDeletionError = deleteMeetingAudioDirectory(for: meeting)
            meetings.removeAll { $0.id == meetingID }
            segmentsByMeeting.removeValue(forKey: meetingID)
            notesByMeeting.removeValue(forKey: meetingID)
            noteImagesByMeeting.removeValue(forKey: meetingID)
            diarizationRunsByMeeting.removeValue(forKey: meetingID)
            diarizationMappingsByMeeting.removeValue(forKey: meetingID)
            meetingAgentResponseTasks[meetingID]?.cancel()
            meetingAgentResponseTasks.removeValue(forKey: meetingID)
            meetingAgentRespondingIDs.remove(meetingID)
            meetingAgentContextNotices.removeValue(forKey: meetingID)
            meetingAgentMessagesByMeeting.removeValue(forKey: meetingID)
            meetingMinutesArtifacts.removeValue(forKey: meetingID)
            meetingAnalysisArtifacts.removeValue(forKey: meetingID)
            generatingMeetingAnalysisIDs.remove(meetingID)
            recentlyCompletedMeetingIDs.remove(meetingID)
            if selectedMeetingID == meetingID {
                selectedMeetingID = nil
            }
            refreshVisibleMeetings()
            refreshExportPreview()
            if let audioDeletionError {
                statusMessage = "会议已删除，但音频目录清理失败：\(audioDeletionError.localizedDescription)"
            } else {
                statusMessage = "会议已删除：\(meeting.title)。"
            }
            return true
        } catch {
            statusMessage = "会议删除失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addMeetingNote(body: String = "") -> MeetingNote.ID? {
        guard ensurePersistenceAvailable(action: "新增笔记"), let meetingID = selectedMeetingID, let store else {
            return nil
        }
        guard !isMeetingContentLocked(meetingID) else {
            statusMessage = "当前会议暂不可编辑笔记。"
            return nil
        }
        let note = MeetingNote(meetingID: meetingID, body: body)
        do {
            try store.upsertMeetingNote(note)
            notesByMeeting[meetingID, default: []].append(note)
            invalidateMeetingMinutesArtifact(for: meetingID)
            statusMessage = "笔记已新增。"
            return note.id
        } catch {
            statusMessage = "笔记新增失败：(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func updateMeetingNote(noteID: MeetingNote.ID, body: String) -> Bool {
        guard ensurePersistenceAvailable(action: "保存笔记"), let store else {
            return false
        }
        guard let meetingID = notesByMeeting.first(where: { $0.value.contains(where: { $0.id == noteID }) })?.key,
              !isMeetingContentLocked(meetingID),
              let index = notesByMeeting[meetingID]?.firstIndex(where: { $0.id == noteID }) else {
            statusMessage = "当前会议暂不可编辑笔记。"
            return false
        }
        var note = notesByMeeting[meetingID]![index]
        note.body = body
        note.updatedAt = Date()
        do {
            try store.upsertMeetingNote(note)
            notesByMeeting[meetingID]![index] = note
            invalidateMeetingMinutesArtifact(for: meetingID)
            return true
        } catch {
            statusMessage = "笔记保存失败：(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setMeetingNoteIncluded(noteID: MeetingNote.ID, includeInMinutes: Bool) -> Bool {
        guard ensurePersistenceAvailable(action: "更新笔记设置"), let store else {
            return false
        }
        guard let meetingID = notesByMeeting.first(where: { $0.value.contains(where: { $0.id == noteID }) })?.key,
              !isMeetingContentLocked(meetingID),
              let index = notesByMeeting[meetingID]?.firstIndex(where: { $0.id == noteID }) else {
            statusMessage = "当前会议暂不可编辑笔记。"
            return false
        }
        var note = notesByMeeting[meetingID]![index]
        note.includeInMinutes = includeInMinutes
        note.updatedAt = Date()
        do {
            try store.upsertMeetingNote(note)
            notesByMeeting[meetingID]![index] = note
            invalidateMeetingMinutesArtifact(for: meetingID)
            return true
        } catch {
            statusMessage = "笔记设置保存失败：(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteMeetingNote(noteID: MeetingNote.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "删除笔记"), let store else {
            return false
        }
        guard let meetingID = notesByMeeting.first(where: { $0.value.contains(where: { $0.id == noteID }) })?.key,
              !isMeetingContentLocked(meetingID) else {
            statusMessage = "当前会议暂不可编辑笔记。"
            return false
        }
        do {
            try store.deleteMeetingNote(id: noteID)
            notesByMeeting[meetingID]?.removeAll { $0.id == noteID }
            noteImagesByMeeting[meetingID]?.removeAll { $0.noteID == noteID }
            invalidateMeetingMinutesArtifact(for: meetingID)
            statusMessage = "笔记已删除。"
            return true
        } catch {
            statusMessage = "笔记删除失败：(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addMeetingNoteImage(
        noteID: MeetingNote.ID,
        filename: String,
        mimeType: String,
        originalData: Data,
        thumbnailData: Data
    ) -> MeetingNoteImage.ID? {
        guard ensurePersistenceAvailable(action: "保存笔记图片"), let store else {
            return nil
        }
        guard let meetingID = notesByMeeting.first(where: { $0.value.contains(where: { $0.id == noteID }) })?.key,
              !isMeetingContentLocked(meetingID) else {
            statusMessage = "当前会议暂不可编辑笔记。"
            return nil
        }
        let image = MeetingNoteImage(
            noteID: noteID,
            filename: filename,
            mimeType: mimeType,
            originalData: originalData,
            thumbnailData: thumbnailData,
            sha256: Self.sha256(originalData)
        )
        do {
            try store.upsertMeetingNoteImage(image)
            noteImagesByMeeting[meetingID, default: []].append(image)
            invalidateMeetingMinutesArtifact(for: meetingID)
            statusMessage = "笔记图片已保存。"
            return image.id
        } catch {
            statusMessage = "笔记图片保存失败：(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func deleteMeetingNoteImage(imageID: MeetingNoteImage.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "删除笔记图片"), let store else {
            return false
        }
        guard let meetingID = noteImagesByMeeting.first(where: { $0.value.contains(where: { $0.id == imageID }) })?.key,
              !isMeetingContentLocked(meetingID) else {
            statusMessage = "当前会议暂不可编辑笔记。"
            return false
        }
        do {
            try store.deleteMeetingNoteImage(id: imageID)
            noteImagesByMeeting[meetingID]?.removeAll { $0.id == imageID }
            invalidateMeetingMinutesArtifact(for: meetingID)
            return true
        } catch {
            statusMessage = "笔记图片删除失败：(error.localizedDescription)"
            return false
        }
    }

    func loadMeetingNoteContents(
        meetingID: Meeting.ID,
        includeOriginalData: Bool
    ) throws -> [MeetingNoteContent] {
        guard let store else {
            throw AppStatePersistenceError.unavailable
        }
        let (notes, images) = try store.loadMeetingNotes(
            meetingID: meetingID,
            includeOriginalData: includeOriginalData
        )
        if !includeOriginalData {
            notesByMeeting[meetingID] = notes
            noteImagesByMeeting[meetingID] = images
        }
        let imagesByNote = Dictionary(grouping: images, by: \.noteID)
        return notes
            .sorted { $0.createdAt < $1.createdAt }
            .map { MeetingNoteContent(note: $0, images: imagesByNote[$0.id, default: []]) }
    }

    private func persistMeetingNoteVisionResults(_ results: [MeetingNoteVisionResult]) {
        guard let store else { return }
        for result in results {
            do {
                try store.updateMeetingNoteImageVision(
                    id: result.imageID,
                    status: .completed,
                    text: result.text,
                    model: result.model,
                    promptVersion: result.promptVersion
                )
                for meetingID in noteImagesByMeeting.keys {
                    guard let index = noteImagesByMeeting[meetingID]?.firstIndex(where: { $0.id == result.imageID }) else {
                        continue
                    }
                    noteImagesByMeeting[meetingID]![index].visionStatus = .completed
                    noteImagesByMeeting[meetingID]![index].visionText = result.text
                    noteImagesByMeeting[meetingID]![index].visionModel = result.model
                    noteImagesByMeeting[meetingID]![index].visionPromptVersion = result.promptVersion
                    noteImagesByMeeting[meetingID]![index].visionUpdatedAt = Date()
                    noteImagesByMeeting[meetingID]![index].visionError = nil
                    break
                }
            } catch {
                statusMessage = "图片识别结果保存失败：(error.localizedDescription)"
            }
        }
    }

    private func setMeetingNoteImageVisionStatus(
        _ notes: [MeetingNoteContent],
        status: MeetingNoteVisionStatus,
        error: String? = nil
    ) {
        guard let store else { return }
        for image in notes.filter(\.note.includeInMinutes).flatMap(\.images) {
            do {
                try store.updateMeetingNoteImageVision(
                    id: image.id,
                    status: status,
                    text: status == .failed ? "" : image.visionText,
                    model: image.visionModel,
                    promptVersion: image.visionPromptVersion,
                    error: error
                )
                for meetingID in noteImagesByMeeting.keys {
                    guard let index = noteImagesByMeeting[meetingID]?.firstIndex(where: { $0.id == image.id }) else {
                        continue
                    }
                    noteImagesByMeeting[meetingID]![index].visionStatus = status
                    noteImagesByMeeting[meetingID]![index].visionError = error
                    break
                }
            } catch {
                statusMessage = "图片识别状态保存失败：(error.localizedDescription)"
            }
        }
    }

    private func invalidateMeetingMinutesArtifact(for meetingID: Meeting.ID) {
        guard meetingMinutesArtifacts[meetingID] != nil else { return }
        meetingMinutesArtifacts.removeValue(forKey: meetingID)
        meetingMinutesGenerator.removeCachedArtifact(meetingID: meetingID)
        updateMeeting(id: meetingID) {
            if $0.status != .processing {
                $0.minutesGenerationError = "会议笔记已修改，请重新生成会议纪要。"
            }
        }
        if selectedMeetingID == meetingID {
            statusMessage = "会议笔记已修改，原会议纪要已失效，请重新生成。"
        }
    }

    func updateSelectedCaptureSource(_ source: CaptureSource) {
        let source = Self.normalizedCaptureSource(source)
        selectedCaptureSource = source
        updateSelectedMeeting { meeting in
            meeting.captureSource = source
        }
        if recordingStartupState == .failed {
            recordingStartupState = .idle
            recordingStartupError = nil
            canSwitchFailedStartToMicrophone = false
        }
        refreshPermissionStatus()
        statusMessage = "采集来源已切换为：\(source.displayName)。"
    }

    func updateSelectedMicrophoneDevice(_ deviceID: String) {
        guard activeRecordingMeetingID == nil,
              !isCaptureTransitioning,
              let device = microphoneDevices.first(where: { $0.id == deviceID }) else {
            return
        }
        selectedMicrophoneDeviceID = device.id
        persistAppSetting(AppSettingKey.microphoneDeviceID, value: device.id)
        statusMessage = "录音麦克风已切换为：\(device.name)。"
    }

    func refreshMicrophoneDevices() {
        let preferredDeviceID = selectedMicrophoneDeviceID.isEmpty ? nil : selectedMicrophoneDeviceID
        refreshMicrophoneDevices(preferredDeviceID: preferredDeviceID)
        if let selectedMicrophoneDevice {
            statusMessage = "已刷新麦克风设备，当前使用：\(selectedMicrophoneDevice.name)。"
        } else {
            statusMessage = "未找到可用麦克风。"
        }
    }

    func startRecordingPreview() {
        guard ensurePersistenceAvailable(action: "开始录音") else {
            return
        }
        guard !isCaptureTransitioning else {
            statusMessage = "录音状态正在切换，请稍候。"
            return
        }
        if recordingStartupState == .paused {
            resumeRecordingPreview()
            return
        }
        guard activeCapture == nil else {
            statusMessage = "录音已经在进行中。"
            return
        }
        guard let recordingMeetingID = selectedMeetingID,
              let meeting = meetings.first(where: { $0.id == recordingMeetingID }) else {
            setRecordingStartFailure("录音未开始：请先选择会议。", canSwitchToMicrophone: false)
            return
        }
        guard !isMeetingContentLocked(recordingMeetingID) else {
            statusMessage = contentLockMessage(for: recordingMeetingID)
            return
        }
        let restartDecision = RecordingRestartPolicy.validate(
            meeting: meeting,
            existingSegmentCount: segmentsByMeeting[recordingMeetingID, default: []].count
        )
        guard restartDecision.isAccepted else {
            setRecordingStartFailure(
                restartDecision.reason ?? "当前会议已有转写记录，请新建会议后再录音。",
                canSwitchToMicrophone: false
            )
            return
        }

        recordingStartupState = .starting
        recordingStartupError = nil
        canSwitchFailedStartToMicrophone = false
        inputLevel = 0
        recordingElapsedMs = 0
        refreshPermissionStatus()
        let preflight = CaptureStartPreflight.evaluate(
            source: selectedCaptureSource,
            snapshot: permissionSnapshot
        )
        if case .blocked(let block) = preflight {
            updateSelectedMeeting { meeting in
                meeting.status = .draft
            }
            setRecordingStartFailure(block.message, canSwitchToMicrophone: block.canSwitchToMicrophone)
            return
        }

        let source = selectedCaptureSource
        activeRecordingMeetingID = recordingMeetingID
        liveRecordingOffsetMs = 0
        liveChunkAccumulator.reset()
        captureCallbackBuffer.reset()
        unresolvedTranscriptionCounts[recordingMeetingID] = 0
        do {
            try prepareMeetingAudioWriter()
        } catch {
            activeRecordingMeetingID = nil
            setRecordingStartFailure("录音未开始：会议音频文件创建失败：\(error.localizedDescription)", canSwitchToMicrophone: false)
            return
        }
        statusMessage = "正在预热转写模型。"

        let capture = makeCaptureSession(for: source)
        activeCapture = capture

        Task {
            do {
                try await warmUpRealtimeModels()
                statusMessage = "模型预热完成，正在启动\(source.displayName)采集。"
                try await capture.start(callbacks: makeAudioCaptureCallbacks())
                let intervalStartedAt = Date()
                updateMeeting(id: recordingMeetingID) { meeting in
                    meeting.status = .recording
                    meeting.captureSource = source
                    MeetingRecordingTimeline.beginInterval(
                        for: &meeting,
                        at: intervalStartedAt
                    )
                }
                recordingStartupState = .recording
                recordingStartupError = nil
                canSwitchFailedStartToMicrophone = false
                statusMessage = "\(source.displayName)采集中。"
            } catch let error as RecordingStartupError {
                activeCapture = nil
                activeRecordingMeetingID = nil
                finishMeetingAudioWriter()
                await capture.stop()
                captureCallbackBuffer.reset()
                updateMeeting(id: recordingMeetingID) { meeting in
                    meeting.status = .draft
                }
                inputLevel = 0
                setRecordingStartFailure(error.localizedDescription, canSwitchToMicrophone: false)
            } catch {
                activeCapture = nil
                activeRecordingMeetingID = nil
                finishMeetingAudioWriter()
                await capture.stop()
                captureCallbackBuffer.reset()
                updateMeeting(id: recordingMeetingID) { meeting in
                    meeting.status = .draft
                }
                inputLevel = 0
                setRecordingStartFailure(
                    RecordingStartupFailureMessage.captureStart(source: source, detail: errorDescription(from: error)),
                    canSwitchToMicrophone: false
                )
            }
        }
    }

    func refreshPermissionStatus() {
        permissionSnapshot = CapturePermissionSnapshot(
            microphone: permissionService.microphoneStatus(),
            screenRecording: permissionService.screenRecordingStatus()
        )
    }

    func permissionGuidance(for source: CaptureSource? = nil) -> CapturePermissionGuidance {
        CapturePermissionGuidance(
            requirement: CapturePermissionRequirement(source: source ?? selectedCaptureSource),
            microphone: permissionSnapshot.microphone,
            screenRecording: permissionSnapshot.screenRecording
        )
    }

    func requestMicrophonePermission() {
        statusMessage = "正在请求麦克风权限。"
        Task {
            let granted = await permissionService.requestMicrophoneAccess()
            refreshPermissionStatus()
            statusMessage = granted ? "麦克风已授权。" : "麦克风未授权，请在系统设置中允许会小纪使用麦克风。"
        }
    }

    func requestScreenRecordingPermission() {
        refreshPermissionStatus()
        switch ScreenRecordingPermissionRequestPolicy.evaluate(status: permissionSnapshot.screenRecording) {
        case .alreadyAuthorized(let message):
            statusMessage = message
        case .requestSystemPrompt:
            _ = permissionService.requestScreenRecordingAccess()
            refreshPermissionStatus()
            if permissionSnapshot.screenRecording == .authorized {
                statusMessage = "屏幕录制已授权，不需要再次授权。"
            } else {
                statusMessage = "请在系统设置中允许会小纪使用屏幕录制，授权后退出并重新打开会小纪。"
            }
        }
    }

    func openPermissionSettings(for permission: CapturePermissionKind) {
        let opened = NSWorkspace.shared.open(permissionService.settingsURL(for: permission))
        if !opened {
            NSWorkspace.shared.open(permissionService.fallbackSettingsURL)
        }
    }

    func switchFailedStartToMicrophone() {
        updateSelectedCaptureSource(.microphone)
        statusMessage = "已切换为麦克风录制，请再次点击开始。"
    }

    func setRecordingStartFailure(_ message: String, canSwitchToMicrophone: Bool) {
        recordingStartupState = .failed
        recordingStartupError = message
        canSwitchFailedStartToMicrophone = canSwitchToMicrophone
        statusMessage = message
        inputLevel = 0
    }

    func pauseRecordingPreview() {
        guard !isCaptureTransitioning else {
            statusMessage = "录音状态正在切换，请稍候。"
            return
        }
        guard recordingStartupState == .recording else {
            statusMessage = "当前没有正在进行的录音可暂停。"
            return
        }
        let capture = activeCapture
        isCaptureTransitionInFlight = true
        isStoppingCapture = true
        activeCapture = nil
        pausedCaptureSource = selectedCaptureSource
        if let activeRecordingMeetingID {
            let pausedAt = Date()
            updateMeeting(id: activeRecordingMeetingID) { meeting in
                meeting.status = .paused
                MeetingRecordingTimeline.closeInterval(
                    for: &meeting,
                    at: pausedAt
                )
            }
        }
        recordingStartupState = .paused
        recordingStartupError = nil
        canSwitchFailedStartToMicrophone = false
        inputLevel = 0
        statusMessage = "录音已暂停。"
        Task {
            defer {
                isStoppingCapture = false
                isCaptureTransitionInFlight = false
            }
            await capture?.stop()
            drainCaptureCallbackBuffer()
            flushLiveChunkAccumulator()
            if let activeRecordingMeetingID {
                await waitForPendingLiveTranscription(meetingID: activeRecordingMeetingID)
            }
            // pause 后立刻把 WAV header + PCM 落盘，避免硬崩后留下头字段过期的 WAV。
            do {
                try meetingAudioWriters?.flush()
            } catch {
                statusMessage = "暂停时音频落盘失败：\(error.localizedDescription)"
            }
        }
    }

    func resumeRecordingPreview() {
        guard ensurePersistenceAvailable(action: "继续录音") else {
            return
        }
        guard !isCaptureTransitioning else {
            statusMessage = "录音状态正在切换，请稍候。"
            return
        }
        guard recordingStartupState == .paused else {
            startRecordingPreview()
            return
        }
        guard activeCapture == nil else {
            statusMessage = "录音已经在进行中。"
            return
        }
        guard let recordingMeetingID = activeRecordingMeetingID else {
            setRecordingStartFailure("继续录音失败：找不到当前录音会议。", canSwitchToMicrophone: false)
            return
        }

        let source = pausedCaptureSource ?? selectedCaptureSource
        recordingStartupState = .starting
        recordingStartupError = nil
        canSwitchFailedStartToMicrophone = false
        inputLevel = 0
        refreshPermissionStatus()
        let preflight = CaptureStartPreflight.evaluate(
            source: source,
            snapshot: permissionSnapshot
        )
        if case .blocked(let block) = preflight {
            recordingStartupState = .paused
            recordingStartupError = block.message
            canSwitchFailedStartToMicrophone = block.canSwitchToMicrophone
            statusMessage = block.message
            return
        }

        guard let meetingAudioWriters else {
            recordingStartupState = .paused
            recordingStartupError = "继续录音失败：找不到当前会议的音频写入器。"
            statusMessage = recordingStartupError ?? "继续录音失败。"
            return
        }
        liveRecordingOffsetMs = meetingAudioWriters.mixedDurationMs
        liveChunkAccumulator.reset()
        captureCallbackBuffer.reset()
        isStoppingCapture = false
        statusMessage = "正在继续录音，预热转写模型。"

        let capture = makeCaptureSession(for: source)
        activeCapture = capture
        Task {
            do {
                try await warmUpRealtimeModels()
                statusMessage = "模型预热完成，正在继续\(source.displayName)采集。"
                try await capture.start(callbacks: makeAudioCaptureCallbacks())
                let intervalStartedAt = Date()
                updateMeeting(id: recordingMeetingID) { meeting in
                    meeting.status = .recording
                    meeting.captureSource = source
                    MeetingRecordingTimeline.beginInterval(
                        for: &meeting,
                        at: intervalStartedAt
                    )
                }
                recordingStartupState = .recording
                recordingStartupError = nil
                canSwitchFailedStartToMicrophone = false
                pausedCaptureSource = nil
                statusMessage = "\(source.displayName)采集中。"
            } catch let error as RecordingStartupError {
                activeCapture = nil
                await capture.stop()
                captureCallbackBuffer.reset()
                recordingStartupState = .paused
                inputLevel = 0
                recordingStartupError = error.localizedDescription
                statusMessage = error.localizedDescription
            } catch {
                activeCapture = nil
                await capture.stop()
                captureCallbackBuffer.reset()
                recordingStartupState = .paused
                inputLevel = 0
                let message = RecordingStartupFailureMessage.captureStart(source: source, detail: errorDescription(from: error))
                recordingStartupError = message
                statusMessage = message
            }
        }
    }

    func stopRecordingPreview() {
        guard !isCaptureTransitioning else {
            statusMessage = "录音状态正在切换，请稍候。"
            return
        }
        guard recordingStartupState == .recording || recordingStartupState == .paused else {
            statusMessage = "当前没有正在进行的录音可停止。"
            return
        }
        let capture = activeCapture
        let stoppingMeetingID = activeRecordingMeetingID
        isCaptureTransitionInFlight = true
        isStoppingCapture = true
        activeCapture = nil
        let stoppedAt = Date()
        if let stoppingMeetingID {
            updateMeeting(id: stoppingMeetingID) { meeting in
                meeting.status = .processing
                MeetingRecordingTimeline.endInterval(
                    for: &meeting,
                    at: stoppedAt
                )
            }
            postprocessingMeetingIDs.insert(stoppingMeetingID)
            recentlyCompletedMeetingIDs.remove(stoppingMeetingID)
        }
        inputLevel = 0
        recordingStartupState = .idle
        recordingStartupError = nil
        canSwitchFailedStartToMicrophone = false
        pausedCaptureSource = nil
        statusMessage = "录音已停止，正在保存录音和实时记录。"
        Task {
            defer {
                isStoppingCapture = false
                isCaptureTransitionInFlight = false
            }
            await capture?.stop()
            drainCaptureCallbackBuffer()
            flushLiveChunkAccumulator()
            if let stoppingMeetingID {
                await waitForPendingLiveTranscription(meetingID: stoppingMeetingID)
            }
            finishMeetingAudioWriter()
            activeRecordingMeetingID = nil
            if let stoppingMeetingID {
                finalizeStoppedMeeting(meetingID: stoppingMeetingID)
            } else {
                statusMessage = "录音已停止。录音文件已保存，可在会议详情回放。"
            }
        }
    }

    func transcribeMockAudioWithDefaultASR() {
        guard let selectedMeetingID else {
            statusMessage = "请先选择会议。"
            return
        }
        guard !isMeetingContentLocked(selectedMeetingID) else {
            statusMessage = contentLockMessage(for: selectedMeetingID)
            return
        }
        guard let source = defaultModelSource(type: .asr) else {
            statusMessage = "请先配置默认转写模型。"
            return
        }
        guard source.baseURL.hasPrefix("mock://") || !source.baseURL.contains("example.com") else {
            statusMessage = "默认转写服务还是示例地址，请先在模型配置中填写真实 baseURL。"
            return
        }

        let sequence = (segmentsByMeeting[selectedMeetingID]?.count ?? 0) + 1
        let chunk = AudioChunk(
            sequence: sequence,
            startMs: sequence * 2_000,
            endMs: sequence * 2_000 + 1_600,
            samples: [0.0, 0.2, -0.2, 0.1, 0.0],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )

        updateSelectedMeeting { meeting in
            meeting.status = .processing
        }
        statusMessage = "正在调用默认 ASR 模型转写模拟音频。"

        Task {
            do {
                let asr: ASRSegment
                if source.baseURL.hasPrefix("mock://") {
                    asr = try await MockASRClient(text: "这是一次模拟音频转写").transcribe(chunk: chunk)
                } else {
                    asr = try await OpenAICompatibleASRClient(
                        source: source,
                        uploader: URLSessionDataUploader(session: HTTPSessionFactory.asr())
                    ).transcribe(chunk: chunk)
                }
                _ = try appendASRSegment(asr, meetingID: selectedMeetingID, sequence: sequence)
                updateMeeting(id: selectedMeetingID) { meeting in
                    meeting.status = .done
                }
                statusMessage = "ASR 转写完成，已写入会议记录。"
            } catch {
                updateMeeting(id: selectedMeetingID) { meeting in
                    meeting.status = .failed
                }
                statusMessage = "ASR 转写失败：\(error.localizedDescription)"
            }
        }
    }

    func retranscribeSelectedMeetingFromRecording() {
        guard ensurePersistenceAvailable(action: "录音重新转写") else {
            return
        }
        guard !isCaptureTransitioning else {
            statusMessage = "录音正在收尾，请等待音频保存完成后再重新转写。"
            return
        }
        guard recordingRetranscriptionTask == nil else {
            statusMessage = "录音重新转写正在进行中。"
            return
        }
        guard activeCapture == nil,
              recordingStartupState != .starting,
              recordingStartupState != .recording,
              recordingStartupState != .paused else {
            statusMessage = "录音进行中，不能重新转写。"
            return
        }
        guard let selectedMeetingID,
              let meeting = meetings.first(where: { $0.id == selectedMeetingID }) else {
            statusMessage = "请先选择会议。"
            return
        }
        guard !isMeetingContentLocked(selectedMeetingID) else {
            statusMessage = contentLockMessage(for: selectedMeetingID)
            return
        }
        guard !postprocessingMeetingIDs.contains(selectedMeetingID) else {
            statusMessage = "当前会议正在生成会议纪要，请等待完成。"
            return
        }
        guard let audioFilePath = meeting.audioFilePath,
              FileManager.default.fileExists(atPath: audioFilePath) else {
            statusMessage = "当前会议没有可用的完整录音。"
            return
        }
        guard let asrSource = defaultModelSource(type: .asr),
              asrSource.baseURL.hasPrefix("mock://") || !asrSource.baseURL.contains("example.com") else {
            statusMessage = "请先配置可用的默认 ASR 服务。"
            return
        }

        recordingRetranscriptionTask = Task {
            await retranscribeMeetingFromRecording(
                meetingID: selectedMeetingID,
                audioFilePath: audioFilePath,
                asrSource: asrSource
            )
        }
    }

    func stopSelectedRecordingRetranscription() {
        guard isRecordingRetranscriptionSelectedMeeting else {
            statusMessage = "当前没有正在进行的录音重新转写。"
            return
        }
        statusMessage = "正在停止录音重新转写。"
        recordingRetranscriptionTask?.cancel()
    }

    func updateSegmentText(segmentID: TranscriptSegment.ID, text: String) {
        guard let selectedMeetingID, !isMeetingContentLocked(selectedMeetingID) else {
            statusMessage = selectedMeetingID.map { contentLockMessage(for: $0) } ?? "请先选择会议。"
            return
        }
        updateSegment(segmentID: segmentID) { segment in
            segment.finalText = text
            segment.isManual = true
            segment.manualReason = "手工编辑文本"
        }
        refreshExportPreview()
    }

    func renameSegment(segmentID: TranscriptSegment.ID, to personName: String) {
        guard let selectedMeetingID, !isMeetingContentLocked(selectedMeetingID) else {
            statusMessage = selectedMeetingID.map { contentLockMessage(for: $0) } ?? "请先选择会议。"
            return
        }
        let trimmedName = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }
        let person = findOrCreatePerson(named: trimmedName)
        updateSegment(segmentID: segmentID) { segment in
            segment = applyManualSpeakerName(
                to: segment,
                personID: person.id,
                personName: person.displayName
            )
        }
        refreshExportPreview()
        statusMessage = "已把片段改名为：\(trimmedName)。"
    }

    func renameSegments(segmentIDs: [TranscriptSegment.ID], to personName: String) {
        guard let selectedMeetingID, !isMeetingContentLocked(selectedMeetingID) else {
            statusMessage = selectedMeetingID.map { contentLockMessage(for: $0) } ?? "请先选择会议。"
            return
        }
        let trimmedName = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }
        let person = findOrCreatePerson(named: trimmedName)
        var renamedCount = 0
        for segmentID in segmentIDs {
            updateSegment(segmentID: segmentID) { segment in
                segment = applyManualSpeakerName(
                    to: segment,
                    personID: person.id,
                    personName: person.displayName
                )
                renamedCount += 1
            }
        }
        refreshExportPreview()
        statusMessage = "已把 \(renamedCount) 个片段改名为：\(trimmedName)。"
    }

    /// 保存当前会议的人工 speaker mapping，并把对应音频片段补录到长期声纹库。
    func renameDiarizedSpeakerForCurrentMeeting(
        automaticLabel: String,
        currentLabel: String,
        to name: String
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let meetingID = selectedMeetingID else {
            statusMessage = "请先选择会议。"
            return
        }
        guard !isMeetingContentLocked(meetingID) else {
            statusMessage = contentLockMessage(for: meetingID)
            return
        }
        guard automaticLabel != DiarizationApplication.multiTrackOverlapLabel else {
            statusMessage = "多人重叠片段不能批量归属，请逐句确认。"
            return
        }
        guard var mapping = diarizationMappingsByMeeting[meetingID, default: []]
            .first(where: { $0.speakerLabel == currentLabel }) else {
            statusMessage = "当前发言人不是可追溯的匿名分离结果，请逐句修改。"
            return
        }
        let person = findOrCreatePerson(named: trimmed)

        mapping.speakerLabel = trimmed
        mapping.personID = person.id
        mapping.personName = person.displayName
        mapping.isManual = true
        upsertDiarizationSpeakerMapping(mapping)

        var changedCount = 0
        for segment in segmentsByMeeting[meetingID, default: []] where
            segment.autoSpeakerLabel == automaticLabel || segment.speakerLabel == currentLabel {
            updateSegment(segmentID: segment.id) { current in
                current = applyManualSpeakerName(
                    to: current,
                    personID: person.id,
                    personName: person.displayName
                )
                changedCount += 1
            }
        }
        refreshExportPreview()
        statusMessage = "已将本次会议的 \(automaticLabel) 改为 \(trimmed)，并更新 \(changedCount) 个历史片段。"
    }

    func refreshExportPreview() {
        guard let selectedMeeting else {
            exportPreview = ""
            return
        }
        exportPreview = MarkdownExporter().export(meeting: selectedMeeting, segments: selectedSegments)
    }

    func chooseTranscriptFileForImport(onImported: @escaping (Meeting.ID) -> Void) {
        guard ensurePersistenceAvailable(action: "导入转写记录") else { return }
        let panel = NSOpenPanel()
        panel.title = "导入转写记录"
        panel.prompt = "导入"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .text,
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "vtt")
        ].compactMap { $0 }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .creationDateKey
                    ])
                    if let fileSize = values.fileSize,
                       fileSize > TranscriptImportParser.maximumFileSize {
                        throw TranscriptImportError.fileTooLarge(
                            maximumBytes: TranscriptImportParser.maximumFileSize
                        )
                    }
                    var encoding = String.Encoding.utf8
                    let content = try String(contentsOf: url, usedEncoding: &encoding)
                    let title = url.deletingPathExtension().lastPathComponent
                    if let meetingID = self.importTranscript(
                        title: title,
                        content: content,
                        fileExtension: url.pathExtension,
                        meetingDate: values.contentModificationDate ?? values.creationDate
                    ) {
                        onImported(meetingID)
                    }
                } catch {
                    self.statusMessage = "转写记录导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    func importTranscript(
        title: String,
        content: String,
        fileExtension: String? = nil,
        meetingDate: Date? = nil,
        importedAt: Date = Date()
    ) -> Meeting.ID? {
        guard ensurePersistenceAvailable(action: "导入转写记录"), let store else { return nil }
        do {
            let records = try TranscriptImportParser.parse(content, fileExtension: fileExtension)
            let meetingID = UUID().uuidString
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let startedAt = meetingDate ?? importedAt
            let durationMs = records.map(\.endMs).max() ?? 1
            let meeting = Meeting(
                id: meetingID,
                title: normalizedTitle.isEmpty ? "导入会议" : normalizedTitle,
                status: .done,
                captureSource: .imported,
                createdAt: importedAt,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(durationMs) / 1_000)
            )
            let segments = records.map { record in
                TranscriptSegment(
                    id: UUID().uuidString,
                    meetingID: meetingID,
                    startMs: record.startMs,
                    endMs: record.endMs,
                    speakerLabel: record.speakerLabel,
                    autoSpeakerLabel: record.speakerLabel,
                    confidence: 0,
                    rawText: record.text,
                    processedText: record.text,
                    finalText: record.text
                )
            }

            try store.importTranscriptMeeting(meeting, segments: segments)
            meetings.append(meeting)
            meetings.sort { $0.createdAt > $1.createdAt }
            segmentsByMeeting[meetingID] = segments
            diarizationRunsByMeeting[meetingID] = []
            diarizationMappingsByMeeting[meetingID] = []
            selectedMeetingID = meetingID
            refreshVisibleMeetings()
            refreshExportPreview()
            statusMessage = "已导入 \(segments.count) 条转写记录，正在进入会议纪要生成流程。"
            startPostprocessing(meetingID: meetingID)
            return meetingID
        } catch {
            statusMessage = "转写记录导入失败：\(error.localizedDescription)"
            return nil
        }
    }

    func exportSelectedMeetingMarkdown() {
        guard let selectedMeeting else {
            statusMessage = "请先选择会议。"
            return
        }
        let markdown = MarkdownExporter().export(meeting: selectedMeeting, segments: selectedSegments)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "当前会议没有可导出的 Markdown 内容。"
            return
        }

        let panel = NSSavePanel()
        panel.title = "导出 Markdown"
        panel.nameFieldStringValue = "\(safeFilename(selectedMeeting.title)).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    self.statusMessage = "Markdown 已导出：\(url.path)。"
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "Markdown 导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func refreshSelectedMeetingMinutes() {
        guard let selectedMeetingID else { return }
        do {
            let artifact = try meetingMinutesGenerator.load(meetingID: selectedMeetingID)
            guard !discardLegacyImportedTranscriptFallbackIfNeeded(
                meetingID: selectedMeetingID,
                artifact: artifact
            ) else {
                return
            }
            meetingMinutesArtifacts[selectedMeetingID] = artifact
        } catch {
            statusMessage = "会议纪要读取失败：\(error.localizedDescription)"
        }
    }

    func refreshSelectedMeetingAnalysis() {
        guard let selectedMeetingID else { return }
        do {
            meetingAnalysisArtifacts[selectedMeetingID] = try meetingAnalysisGenerator.load(meetingID: selectedMeetingID)
        } catch {
            statusMessage = "AI 分析会议纪要读取失败：\(error.localizedDescription)"
        }
    }

    private func restoreMeetingMinutesArtifacts() {
        var legacyFallbackArtifacts: [Meeting.ID: MeetingMinutesArtifact] = [:]
        for meeting in meetings {
            do {
                if let artifact = try meetingMinutesGenerator.load(meetingID: meeting.id) {
                    if artifact.document.isLegacyImportedTranscriptFallback {
                        legacyFallbackArtifacts[meeting.id] = artifact
                    } else {
                        meetingMinutesArtifacts[meeting.id] = artifact
                    }
                }
            } catch where meeting.id == selectedMeetingID {
                statusMessage = "会议纪要读取失败：\(error.localizedDescription)"
            } catch {
                continue
            }
        }
        for (meetingID, artifact) in legacyFallbackArtifacts {
            _ = discardLegacyImportedTranscriptFallbackIfNeeded(meetingID: meetingID, artifact: artifact)
        }
    }

    @discardableResult
    private func discardLegacyImportedTranscriptFallbackIfNeeded(
        meetingID: Meeting.ID,
        artifact: MeetingMinutesArtifact?
    ) -> Bool {
        guard artifact?.document.isLegacyImportedTranscriptFallback == true else { return false }
        meetingMinutesArtifacts.removeValue(forKey: meetingID)
        meetingMinutesGenerator.removeCachedArtifact(meetingID: meetingID)
        updateMeeting(id: meetingID) {
            $0.status = .failed
            $0.minutesGenerationError = "旧版导入基础纪要已失效，请重新生成标准会议纪要。"
        }
        return true
    }

    private func restoreMeetingAnalysisArtifacts() {
        for meeting in meetings {
            do {
                if let artifact = try meetingAnalysisGenerator.load(meetingID: meeting.id) {
                    meetingAnalysisArtifacts[meeting.id] = artifact
                }
            } catch where meeting.id == selectedMeetingID {
                statusMessage = "AI 分析会议纪要读取失败：\(error.localizedDescription)"
            } catch {
                continue
            }
        }
    }

    func generateSelectedMeetingMinutes(additionalPrompt: String = "") {
        guard let meeting = selectedMeeting else {
            statusMessage = "请先选择会议。"
            return
        }
        let meetingID = meeting.id
        let segments = selectedSegments
        guard !segments.isEmpty else {
            statusMessage = "当前会议没有转写内容，无法生成会议纪要。"
            return
        }
        guard let source = defaultModelSource(type: .agent) else {
            statusMessage = "请先在模型配置中新增、启用并测试 Agent 模型。"
            return
        }
        if let visionWarning = selectedMeetingMinutesVisionWarning {
            statusMessage = visionWarning
            return
        }
        guard !isMeetingRecording(meetingID), !isMeetingPostprocessing(meetingID) else {
            statusMessage = "请等待当前会议录音和自动纪要生成完成后再重新生成。"
            return
        }
        let notes: [MeetingNoteContent]
        do {
            notes = try loadMeetingNoteContents(meetingID: meetingID, includeOriginalData: true)
        } catch {
            let reason = errorDescription(from: error)
            statusMessage = "读取会议笔记失败：\(reason)"
            appendDebugLog(
                category: "纪要",
                message: "手动纪要生成失败：阶段=读取会议笔记；失败原因=\(reason)；错误类型=\(errorTypeDescription(from: error))。",
                meetingID: meetingID
            )
            return
        }
        setMeetingNoteImageVisionStatus(notes, status: .processing)
        guard generatingMeetingMinutesIDs.insert(meetingID).inserted else {
            return
        }
        let modelName = source.selectedModel ?? source.name
        updateMeeting(id: meetingID) {
            $0.status = .processing
            $0.minutesGenerationError = nil
        }
        statusMessage = "“\(meeting.title)”已加入会议纪要生成队列，将按顺序使用“\(modelName)”执行。"
        appendDebugLog(
            category: "纪要",
            message: "手动纪要生成已加入队列：模型=\(modelName)；转写片段=\(segments.count)。",
            meetingID: meetingID
        )

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.generatingMeetingMinutesIDs.remove(meetingID)
                self.meetingMinutesGenerationTasks.removeValue(forKey: meetingID)
            }
            do {
                let artifact = try await self.generateStandardMeetingMinutes(
                    meeting: meeting,
                    segments: segments,
                    source: source,
                    prompt: self.meetingMinutesPrompt,
                    additionalPrompt: additionalPrompt,
                    notes: notes
                )
                guard !Task.isCancelled,
                      let currentMeeting = self.meetings.first(where: { $0.id == meetingID }),
                      !currentMeeting.isArchived else {
                    return
                }
                self.meetingMinutesArtifacts[meetingID] = artifact
                self.persistMeetingNoteVisionResults(artifact.noteVisionResults)
                _ = self.setPostprocessRecoveryPending(false, meetingID: meetingID)
                self.updateMeeting(id: meetingID) {
                    $0.status = .done
                    $0.minutesGenerationError = nil
                }
                do {
                    let generatedTitle = try self.persistGeneratedMeetingTitle(
                        meeting: meeting,
                        artifact: artifact
                    )
                    let titleMessage = generatedTitle.map { "，标题已更新为“\($0)”" } ?? ""
                    self.statusMessage = "会议纪要已生成\(titleMessage)，可预览或导出 MD、HTML。"
                } catch {
                    self.statusMessage = "会议纪要已生成，但标题更新失败：\(error.localizedDescription)。"
                }
                self.appendDebugLog(category: "纪要", message: "手动纪要生成完成。", meetingID: meetingID)
            } catch is CancellationError {
                self.appendDebugLog(category: "纪要", message: "手动纪要生成已取消。", meetingID: meetingID)
            } catch {
                self.setMeetingNoteImageVisionStatus(notes, status: .failed, error: error.localizedDescription)
                self.markStandardMinutesGenerationFailed(
                    meetingID: meetingID,
                    error: error,
                    source: source,
                    mode: "手动"
                )
            }
        }
        meetingMinutesGenerationTasks[meetingID] = task
    }

    func exportSelectedMeetingMinutes(_ format: MeetingMinutesExportFormat) {
        guard let artifact = selectedMeetingMinutesArtifact else {
            statusMessage = "请先生成会议纪要。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出会议纪要 \(format.displayName)"
        panel.nameFieldStringValue = MeetingMinutesGenerator.exportFileName(
            document: artifact.document,
            pathExtension: format.pathExtension
        )
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try format.content(from: artifact).write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    self.statusMessage = "会议纪要 \(format.displayName) 已导出：\(url.path)。"
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "会议纪要导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func previewSelectedMeetingMinutesHTML() {
        guard let meetingID = selectedMeetingID,
              let url = meetingMinutesGenerator.cachedHTMLURL(meetingID: meetingID) else {
            statusMessage = "请先生成会议纪要。"
            return
        }
        guard NSWorkspace.shared.open(url) else {
            statusMessage = "无法打开会议纪要 HTML 预览。"
            return
        }
        statusMessage = "已打开会议纪要 HTML 预览。"
    }

    func generateSelectedMeetingAnalysis() {
        guard let meeting = selectedMeeting,
              let originalMinutes = selectedMeetingMinutesArtifact else {
            statusMessage = "请先生成原始会议纪要。"
            return
        }
        let meetingID = meeting.id
        let segments = selectedSegments
        guard !segments.isEmpty else {
            statusMessage = "当前会议没有转写内容，无法生成 AI 分析。"
            return
        }
        guard let source = defaultModelSource(type: .agent) else {
            statusMessage = "请先在模型配置中新增、启用并测试 Agent 模型。"
            return
        }
        guard canGenerateSelectedMeetingAnalysis,
              generatingMeetingAnalysisIDs.insert(meetingID).inserted else { return }

        let activePeople = people.filter(\.isActive)
        let activeTerminology = terminologyEntries.filter(\.isActive)
        let runtime = meetingAnalysisRuntimeConfiguration(meeting: meeting)
        statusMessage = "正在生成 AI 分析会议纪要，并联动人员库、知识库、常用词和网络工具。"

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.generatingMeetingAnalysisIDs.remove(meetingID)
                self.meetingAnalysisTasks.removeValue(forKey: meetingID)
                try? FileManager.default.removeItem(at: runtime.sessionDirectoryURL)
                try? FileManager.default.removeItem(at: runtime.workingDirectoryURL)
            }
            do {
                let knowledgeContext = await self.retrieveMeetingAnalysisKnowledgeContext(
                    meeting: meeting,
                    originalMinutes: originalMinutes
                )
                let artifact = try await self.meetingAnalysisGenerator.generate(
                    meeting: meeting,
                    segments: segments,
                    originalMinutes: originalMinutes,
                    people: activePeople,
                    terminology: activeTerminology,
                    knowledgeContext: knowledgeContext,
                    source: source,
                    runtime: runtime,
                    prompt: self.meetingAnalysisPrompt
                )
                self.meetingAnalysisArtifacts[meetingID] = artifact
                self.statusMessage = "AI 分析会议纪要已生成，任务分工已按人员职责整理。"
            } catch is CancellationError {
                self.statusMessage = "AI 分析会议纪要生成已取消。"
            } catch {
                self.statusMessage = "AI 分析会议纪要生成失败：\(error.localizedDescription)"
            }
        }
        meetingAnalysisTasks[meetingID] = task
    }

    func stopSelectedMeetingAnalysis() {
        guard let meetingID = selectedMeetingID,
              generatingMeetingAnalysisIDs.contains(meetingID) else { return }
        meetingAnalysisTasks[meetingID]?.cancel()
        statusMessage = "正在停止 AI 分析会议纪要生成。"
    }

    func previewSelectedMeetingAnalysisHTML() {
        guard let meetingID = selectedMeetingID,
              let url = meetingAnalysisGenerator.cachedHTMLURL(meetingID: meetingID) else {
            statusMessage = "请先生成 AI 分析会议纪要。"
            return
        }
        guard NSWorkspace.shared.open(url) else {
            statusMessage = "无法打开 AI 分析会议纪要 HTML 预览。"
            return
        }
        statusMessage = "已打开 AI 分析会议纪要 HTML 预览。"
    }

    func exportSelectedMeetingAnalysis(_ format: MeetingMinutesExportFormat) {
        guard let artifact = selectedMeetingAnalysisArtifact else {
            statusMessage = "请先生成 AI 分析会议纪要。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 AI 分析会议纪要 \(format.displayName)"
        panel.nameFieldStringValue = MeetingAnalysisGenerator.exportFileName(
            document: artifact.document,
            pathExtension: format.pathExtension
        )
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try format.content(from: artifact).write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    self.statusMessage = "AI 分析会议纪要 \(format.displayName) 已导出：\(url.path)。"
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "AI 分析会议纪要导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportMeetingAudioFile(url: URL, title: String, meetingTitle: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "录音文件不存在，无法导出。"
            return
        }

        let fileExtension = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let panel = NSSavePanel()
        panel.title = "导出录音"
        panel.nameFieldStringValue = "\(safeFilename("\(meetingTitle)-\(title)")).\(fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .audio]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else {
                return
            }

            do {
                let sourceURL = url.standardizedFileURL
                let targetURL = destinationURL.standardizedFileURL
                guard sourceURL != targetURL else {
                    Task { @MainActor in
                        self.statusMessage = "导出位置不能与原录音文件相同。"
                    }
                    return
                }
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                Task { @MainActor in
                    self.statusMessage = "录音已导出：\(targetURL.path)。"
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "录音导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func addModelSource(type: ModelSourceType) {
        if type == .voiceprint {
            statusMessage = "声纹识别使用会小纪内置服务，可直接启停或配置 Hugging Face token。"
            return
        }
        let source = ModelSource(
            id: UUID().uuidString,
            type: type,
            name: "新增\(type.displayName)服务",
            baseURL: "",
            selectedModel: nil,
            enabled: false
        )
        modelSources.append(source)
        persistModelSource(source)
    }

    func updateModelSource(_ source: ModelSource) {
        guard let index = modelSources.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        if source.type == .asr {
            var updated = source
            if updated.enabled || updated.isDefault {
                updated.enabled = true
                updated.isDefault = true
                applyExclusiveASRSelection(source: updated)
            } else {
                updated.isDefault = false
                modelSources[index] = updated
                persistModelSource(updated)
            }
            return
        }
        modelSources[index] = source
        persistModelSource(source)
    }

    func deleteModelSource(_ sourceID: ModelSource.ID) {
        guard let source = modelSources.first(where: { $0.id == sourceID }) else {
            return
        }
        let wasDefault = source.isDefault
        modelSources.removeAll { $0.id == sourceID }
        do {
            try store?.deleteModelSource(id: sourceID)
        } catch {
            statusMessage = "\(source.type.displayName)模型服务删除失败：\(error.localizedDescription)"
            return
        }

        if wasDefault,
           let replacementIndex = modelSources.firstIndex(where: { $0.type == source.type && $0.enabled }) {
            modelSources[replacementIndex].isDefault = true
            persistModelSource(modelSources[replacementIndex])
            statusMessage = "已删除\(source.type.displayName)模型服务：\(source.name)。已切换默认服务为：\(modelSources[replacementIndex].name)。"
            return
        }

        if wasDefault {
            statusMessage = "已删除默认\(source.type.displayName)模型服务：\(source.name)。当前没有可用默认服务，请新增并测试。"
        } else {
            statusMessage = "已删除\(source.type.displayName)模型服务：\(source.name)。"
        }
    }

    func setDefaultModelSource(_ sourceID: ModelSource.ID) {
        guard let source = modelSources.first(where: { $0.id == sourceID }) else {
            return
        }
        if source.type == .asr {
            var updated = source
            updated.enabled = true
            updated.isDefault = true
            applyExclusiveASRSelection(source: updated)
            statusMessage = "已启用并设为默认转写模型服务：\(updated.name)。"
            return
        }
        for index in modelSources.indices where modelSources[index].type == source.type {
            modelSources[index].isDefault = modelSources[index].id == sourceID
            persistModelSource(modelSources[index])
        }
        statusMessage = "已设置默认\(source.type.displayName)模型服务：\(source.name)。"
    }

    func testModelSource(_ sourceID: ModelSource.ID) {
        guard let source = modelSources.first(where: { $0.id == sourceID }) else {
            return
        }
        Task {
            var testedSource = source
            let result: ModelSourceTestResult
            if source.type == .asr {
                result = await testASRModelSource(source)
            } else if source.type == .voiceprint {
                result = await testVoiceprintModelSource(source)
            } else {
                result = await modelTester.test(source: source)
            }
            testedSource.availableModels = result.models
            if testedSource.selectedModel == nil {
                testedSource.selectedModel = result.models.first
            }
            testedSource.lastTestOK = result.ok
            testedSource.lastTestMessage = result.message
            testedSource.lastTestAt = Date()
            updateModelSource(testedSource)
            statusMessage = "\(testedSource.name)：\(result.message)。"
        }
    }

    func updateKnowledgeBaseConfiguration(_ configuration: DifyKnowledgeBaseConfiguration) {
        var normalized = configuration
        normalized.baseURL = normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.selectedKnowledgeBaseIDs = Array(Set(normalized.selectedKnowledgeBaseIDs)).sorted()
        knowledgeBaseConfiguration = normalized
        persistKnowledgeBaseConfiguration()
        libraryStatusMessage = "知识库配置已保存。"
    }

    func testAndLoadKnowledgeBases(_ configuration: DifyKnowledgeBaseConfiguration) {
        var probe = configuration
        probe.enabled = true
        Task {
            do {
                let client = DifyKnowledgeBaseClient(
                    configuration: probe,
                    transport: URLSessionDifyHTTPTransport()
                )
                let knowledgeBases = try await client.fetchKnowledgeBases()
                var updated = configuration
                updated.knowledgeBases = knowledgeBases
                let availableIDs = Set(knowledgeBases.map(\.id))
                updated.selectedKnowledgeBaseIDs.removeAll { !availableIDs.contains($0) }
                knowledgeBaseConfiguration = updated
                persistKnowledgeBaseConfiguration()
                libraryStatusMessage = "Dify 服务可用，已加载 \(knowledgeBases.count) 个知识库。"
            } catch {
                libraryStatusMessage = "Dify 连接失败：\(error.localizedDescription)"
            }
        }
    }

    private func testASRModelSource(_ source: ModelSource) async -> ModelSourceTestResult {
        let modelListResult = await modelTester.test(source: source)
        guard source.selectedModel?.isEmpty == false else {
            return ModelSourceTestResult(
                ok: false,
                message: "请先选择 ASR 模型。",
                models: modelListResult.models
            )
        }

        let sampleRate = 16_000
        let samples = (0..<sampleRate).map { index in
            Float(0.04 * sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate)))
        }
        let probeChunk = AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            samples: samples,
            format: AudioFormatDescription(sampleRate: Double(sampleRate), channels: 1)
        )

        do {
            _ = try await transcribeRecordingChunk(probeChunk, using: source)
            let models = modelListResult.models.isEmpty
                ? source.availableModels
                : modelListResult.models
            return ModelSourceTestResult(
                ok: true,
                message: "真实转写接口可用。",
                models: models
            )
        } catch {
            let models = modelListResult.models.isEmpty
                ? source.availableModels
                : modelListResult.models
            return ModelSourceTestResult(
                ok: false,
                message: "真实转写失败：\(errorDescription(from: error))",
                models: models
            )
        }
    }

    private func testVoiceprintModelSource(_ source: ModelSource) async -> ModelSourceTestResult {
        guard source.baseURL == "sidecar://diarization" else {
            return ModelSourceTestResult(ok: false, message: "当前仅支持会小纪内置声纹服务。", models: [])
        }
        let token = DiarizationTokenResolver.resolve(
            source: source,
            environment: ProcessInfo.processInfo.environment
        )
        do {
            let transport = try makeFinalDiarizationTransport(huggingFaceToken: token)
            defer { Task { await transport.shutdown() } }
            let health = try await DiarizationSidecarClient(transport: transport)
                .preload(huggingFaceToken: token)
            return ModelSourceTestResult(
                ok: true,
                message: "本机说话人分离与声纹模型已加载。",
                models: health.models.isEmpty ? [VoiceprintModelMigration.sidecarModel] : health.models
            )
        } catch {
            return ModelSourceTestResult(
                ok: false,
                message: "真实模型加载失败：\(errorDescription(from: error))",
                models: [VoiceprintModelMigration.sidecarModel]
            )
        }
    }

    func updatePostprocessPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        postprocessPrompt = trimmed.isEmpty ? PostprocessPrompt.defaultMouthFillerCleanup : prompt
        persistAppSetting(AppSettingKey.postprocessPrompt, value: postprocessPrompt)
        statusMessage = "后处理提示词已保存。"
    }

    func updateMeetingMinutesPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingMinutesPrompt = trimmed.isEmpty ? PostprocessPrompt.meetingMinutes : prompt
        persistAppSetting(AppSettingKey.meetingMinutesPrompt, value: meetingMinutesPrompt)
        persistAppSetting(
            AppSettingKey.meetingMinutesPromptVersion,
            value: PostprocessPrompt.meetingMinutesPromptVersion
        )
        statusMessage = "会议纪要提示词已保存。"
    }

    func updateMeetingAnalysisPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingAnalysisPrompt = trimmed.isEmpty ? PostprocessPrompt.meetingAnalysis : prompt
        persistAppSetting(AppSettingKey.meetingAnalysisPrompt, value: meetingAnalysisPrompt)
        statusMessage = "AI 分析提示词已保存。"
    }

    private func defaultModelSource(type: ModelSourceType) -> ModelSource? {
        modelSources.first { $0.type == type && $0.isDefault && $0.enabled }
            ?? modelSources.first { $0.type == type && $0.enabled }
    }

    func isMeetingAgentResponding(_ meetingID: Meeting.ID) -> Bool {
        meetingAgentRespondingIDs.contains(meetingID)
    }

    func refreshMeetingAgentContextUsage(_ meetingID: Meeting.ID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        meetingAgentContextUsageByMeeting[meetingID] = MeetingAgentContextBuilder.buildContext(
            meeting: meeting,
            segments: segmentsByMeeting[meetingID, default: []],
            minutesMarkdown: meetingMinutesArtifacts[meetingID]?.markdown,
            people: people.filter(\.isActive),
            currentUserPersonID: currentUserPersonID,
            terminology: terminologyEntries.filter(\.isActive),
            history: meetingAgentMessagesByMeeting[meetingID, default: []],
            knowledgeContext: "",
            question: ""
        ).usage
    }

    func updateMeetingAgentWorkspace(_ url: URL) {
        let normalized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            statusMessage = "Agent 工作目录不可用。"
            return
        }
        meetingAgentWorkspacePath = normalized.path
        persistAppSetting(AppSettingKey.meetingAgentWorkspacePath, value: normalized.path)
        statusMessage = "Agent 工作目录已切换：\(normalized.path)"
    }

    func sendMeetingAgentQuestion(
        meetingID: Meeting.ID,
        question: String,
        usesKnowledgeBase: Bool
    ) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              !meetingAgentRespondingIDs.contains(meetingID),
              let meeting = meetings.first(where: { $0.id == meetingID }),
              let source = defaultModelSource(type: .agent),
              let store else {
            return
        }

        let history = meetingAgentMessagesByMeeting[meetingID, default: []]
        let segments = segmentsByMeeting[meetingID, default: []]
        let minutesMarkdown = meetingMinutesArtifacts[meetingID]?.markdown
        let activePeople = people.filter(\.isActive)
        let activeTerminology = terminologyEntries.filter(\.isActive)
        let now = Date()
        let userMessage = MeetingAgentChatMessage(
            meetingID: meetingID,
            role: .user,
            content: question,
            createdAt: now
        )
        let initialActivity = MeetingAgentContextBuilder.initialActivity(
            segmentCount: segments.count,
            hasMinutes: minutesMarkdown != nil,
            peopleCount: activePeople.count,
            terminologyCount: activeTerminology.count
        )
        let assistantMessage = MeetingAgentChatMessage(
            meetingID: meetingID,
            role: .assistant,
            content: "",
            activity: initialActivity,
            timeline: [MeetingAgentTurnSegment(kind: .process, activity: initialActivity)],
            status: .streaming,
            createdAt: now.addingTimeInterval(0.001)
        )

        do {
            try store.upsertMeetingAgentChatMessage(userMessage)
            try store.upsertMeetingAgentChatMessage(assistantMessage)
        } catch {
            statusMessage = "Agent 会话保存失败：\(error.localizedDescription)"
            return
        }
        meetingAgentMessagesByMeeting[meetingID, default: []].append(contentsOf: [userMessage, assistantMessage])
        meetingAgentRespondingIDs.insert(meetingID)
        meetingAgentContextNotices[meetingID] = "正在装载会议上下文。"

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runMeetingAgentResponse(
                meeting: meeting,
                source: source,
                question: question,
                history: history,
                segments: segments,
                minutesMarkdown: minutesMarkdown,
                people: activePeople,
                terminology: activeTerminology,
                assistantMessageID: assistantMessage.id,
                usesKnowledgeBase: usesKnowledgeBase
            )
        }
        meetingAgentResponseTasks[meetingID] = task
    }

    func stopMeetingAgentResponse(_ meetingID: Meeting.ID) {
        if let messageID = meetingAgentMessagesByMeeting[meetingID]?
            .last(where: { $0.role == .assistant && $0.status == .streaming })?
            .id {
            updateMeetingAgentMessage(meetingID: meetingID, messageID: messageID) {
                $0.appendAgentActivity("已停止生成")
                if $0.content.isEmpty {
                    $0.content = "已停止。"
                    $0.timeline.append(MeetingAgentTurnSegment(kind: .final, content: $0.content))
                }
                $0.status = .cancelled
            }
            persistMeetingAgentMessage(meetingID: meetingID, messageID: messageID)
        }
        meetingAgentResponseTasks[meetingID]?.cancel()
    }

    private func runMeetingAgentResponse(
        meeting: Meeting,
        source: ModelSource,
        question: String,
        history: [MeetingAgentChatMessage],
        segments: [TranscriptSegment],
        minutesMarkdown: String?,
        people: [VoiceprintPerson],
        terminology: [TerminologyEntry],
        assistantMessageID: MeetingAgentChatMessage.ID,
        usesKnowledgeBase: Bool
    ) async {
        let meetingID = meeting.id
        let deltaClock = ContinuousClock()
        var lastDeltaFlush = deltaClock.now
        var pendingReasoning = ""
        var pendingText = ""
        func flushPendingDeltas() {
            guard !pendingReasoning.isEmpty || !pendingText.isEmpty else { return }
            let reasoning = pendingReasoning
            let text = pendingText
            pendingReasoning = ""
            pendingText = ""
            lastDeltaFlush = deltaClock.now
            updateMeetingAgentMessage(meetingID: meetingID, messageID: assistantMessageID) {
                if !reasoning.isEmpty { $0.appendAgentReasoning(reasoning) }
                if !text.isEmpty { $0.appendAgentText(text) }
            }
        }
        func flushDeltasWhenNeeded() {
            if lastDeltaFlush.duration(to: deltaClock.now) >= .milliseconds(50) {
                flushPendingDeltas()
            }
        }
        defer {
            meetingAgentRespondingIDs.remove(meetingID)
            meetingAgentResponseTasks.removeValue(forKey: meetingID)
        }
        do {
            let knowledgeContext = await retrieveMeetingAgentKnowledgeContext(
                meetingID: meetingID,
                question: question,
                usesKnowledgeBase: usesKnowledgeBase,
                assistantMessageID: assistantMessageID
            )
            try Task.checkCancellation()
            let runtime = meetingAgentRuntimeConfiguration(meeting: meeting)
            let context: MeetingAgentBuiltContext
            if runtime.hasPersistedSession {
                context = MeetingAgentContextBuilder.buildContinuationContext(
                    meeting: meeting,
                    people: people,
                    currentUserPersonID: currentUserPersonID,
                    knowledgeContext: knowledgeContext,
                    question: question
                )
                appendMeetingAgentActivity(
                    meetingID: meetingID,
                    messageID: assistantMessageID,
                    text: "继续 Pi 会话：仅发送本轮增量上下文"
                )
            } else {
                context = MeetingAgentContextBuilder.buildContext(
                    meeting: meeting,
                    segments: segments,
                    minutesMarkdown: minutesMarkdown,
                    people: people,
                    currentUserPersonID: currentUserPersonID,
                    terminology: terminology,
                    history: history,
                    knowledgeContext: knowledgeContext,
                    question: question
                )
            }
            meetingAgentContextUsageByMeeting[meetingID] = context.usage
            appendMeetingAgentActivity(
                meetingID: meetingID,
                messageID: assistantMessageID,
                text: context.usage.activityDescription
            )
            let prompt = context.prompt + """

            【Agent 运行环境】
            当前工作目录：\(runtime.workingDirectoryURL.path)
            你可以使用文件、命令、插件、skill 和 Web Search 工具完成任务。文件修改必须围绕用户请求；使用 web_search 时传 workflow: \"none\"，避免 RPC 嵌入模式进入交互式筛选页。
            """
            let client = PiAgentRPCClient()
            for try await event in client.stream(source: source, prompt: prompt, runtime: runtime) {
                try Task.checkCancellation()
                switch event {
                case .promptAccepted:
                    flushPendingDeltas()
                    appendMeetingAgentActivity(
                        meetingID: meetingID,
                        messageID: assistantMessageID,
                        text: "Pi Agent 已接收请求"
                    )
                case .thinkingDelta(let delta):
                    pendingReasoning += delta
                    flushDeltasWhenNeeded()
                case .textDelta(let delta):
                    pendingText += delta
                    flushDeltasWhenNeeded()
                case .toolExecutionStarted(let name):
                    flushPendingDeltas()
                    appendMeetingAgentActivity(
                        meetingID: meetingID,
                        messageID: assistantMessageID,
                        text: "开始调用：\(name)"
                    )
                case .toolExecutionEnded(let name, let isError):
                    flushPendingDeltas()
                    appendMeetingAgentActivity(
                        meetingID: meetingID,
                        messageID: assistantMessageID,
                        text: "\(isError ? "调用失败" : "调用完成")：\(name)"
                    )
                case .compactionStarted:
                    flushPendingDeltas()
                    appendMeetingAgentActivity(
                        meetingID: meetingID,
                        messageID: assistantMessageID,
                        text: "正在自动压缩上下文"
                    )
                case .compactionEnded(_, let tokensBefore, let estimatedTokensAfter):
                    flushPendingDeltas()
                    let before = tokensBefore.map { $0.formatted() } ?? "未知"
                    let after = estimatedTokensAfter.map { $0.formatted() } ?? "待下轮统计"
                    appendMeetingAgentActivity(
                        meetingID: meetingID,
                        messageID: assistantMessageID,
                        text: "上下文压缩完成：\(before) → \(after) tokens"
                    )
                case .extensionInteractionCancelled(let title):
                    flushPendingDeltas()
                    appendMeetingAgentActivity(
                        meetingID: meetingID,
                        messageID: assistantMessageID,
                        text: "已取消插件交互问询：\(title)"
                    )
                case .sessionStats(let stats):
                    flushPendingDeltas()
                    meetingAgentSessionStatsByMeeting[meetingID] = stats
                    updateMeetingAgentMessage(meetingID: meetingID, messageID: assistantMessageID) {
                        $0.appendRootActivity(Self.meetingAgentSessionStatsDescription(stats))
                    }
                case .completed(let content):
                    flushPendingDeltas()
                    updateMeetingAgentMessage(meetingID: meetingID, messageID: assistantMessageID) {
                        $0.completeAgentTurn(finalText: content.isEmpty ? $0.content : content)
                    }
                }
            }
            flushPendingDeltas()
            try Task.checkCancellation()
        } catch is CancellationError {
            flushPendingDeltas()
            updateMeetingAgentMessage(meetingID: meetingID, messageID: assistantMessageID) {
                if $0.status != .cancelled {
                    $0.appendAgentActivity("已停止生成")
                    if $0.content.isEmpty {
                        $0.content = "已停止。"
                        $0.timeline.append(MeetingAgentTurnSegment(kind: .final, content: $0.content))
                    }
                    $0.status = .cancelled
                }
            }
        } catch {
            flushPendingDeltas()
            updateMeetingAgentMessage(meetingID: meetingID, messageID: assistantMessageID) {
                $0.appendAgentActivity("请求失败")
                $0.content = "请求失败：\(error.localizedDescription)"
                $0.timeline.append(MeetingAgentTurnSegment(kind: .final, content: $0.content))
                $0.status = .failed
            }
        }
        persistMeetingAgentMessage(meetingID: meetingID, messageID: assistantMessageID)
    }

    private func retrieveMeetingAgentKnowledgeContext(
        meetingID: Meeting.ID,
        question: String,
        usesKnowledgeBase: Bool,
        assistantMessageID: MeetingAgentChatMessage.ID
    ) async -> String {
        let configuration = knowledgeBaseConfiguration
        guard usesKnowledgeBase,
              configuration.enabled,
              !configuration.selectedKnowledgeBases.isEmpty else {
            meetingAgentContextNotices[meetingID] = "已载入本地上下文；本次未检索 Dify。"
            appendMeetingAgentActivity(
                meetingID: meetingID,
                messageID: assistantMessageID,
                text: "Dify 知识库：未检索"
            )
            return ""
        }

        let client = DifyKnowledgeBaseClient(
            configuration: configuration,
            transport: URLSessionDifyHTTPTransport()
        )
        let query = String(question.prefix(DifyKnowledgeBaseClient<URLSessionDifyHTTPTransport>.maximumQueryLength))
        var sections: [String] = []
        var failures: [String] = []
        for knowledgeBase in configuration.selectedKnowledgeBases {
            do {
                let result = try await client.retrieve(query: query, from: knowledgeBase.id)
                let records = result.records.prefix(5).map { record in
                    let documentName = record.segment.document?.name ?? "未命名文档"
                    return "[\(knowledgeBase.name) / \(documentName)]\n\(record.segment.content)"
                }
                if !records.isEmpty {
                    sections.append(records.joined(separator: "\n\n"))
                }
                appendMeetingAgentActivity(
                    meetingID: meetingID,
                    messageID: assistantMessageID,
                    text: "已检索 \(knowledgeBase.name)：\(records.count) 条"
                )
            } catch {
                failures.append(knowledgeBase.name)
                appendMeetingAgentActivity(
                    meetingID: meetingID,
                    messageID: assistantMessageID,
                    text: "检索失败：\(knowledgeBase.name)"
                )
            }
        }
        if failures.isEmpty {
            meetingAgentContextNotices[meetingID] = "已载入本地上下文，并联动 \(configuration.selectedKnowledgeBases.count) 个 Dify 知识库。"
        } else {
            meetingAgentContextNotices[meetingID] = "本地上下文已载入；部分 Dify 检索失败：\(failures.joined(separator: "、"))。"
        }
        return String(sections.joined(separator: "\n\n---\n\n").prefix(40_000))
    }

    private func retrieveMeetingAnalysisKnowledgeContext(
        meeting: Meeting,
        originalMinutes: MeetingMinutesArtifact
    ) async -> String {
        let configuration = knowledgeBaseConfiguration
        guard configuration.enabled, !configuration.selectedKnowledgeBases.isEmpty else {
            return ""
        }
        let client = DifyKnowledgeBaseClient(
            configuration: configuration,
            transport: URLSessionDifyHTTPTransport()
        )
        let rawQuery = "\(meeting.title)\n\(originalMinutes.document.summary)"
        let query = String(rawQuery.prefix(
            DifyKnowledgeBaseClient<URLSessionDifyHTTPTransport>.maximumQueryLength
        ))
        var sections: [String] = []
        for knowledgeBase in configuration.selectedKnowledgeBases {
            guard let result = try? await client.retrieve(query: query, from: knowledgeBase.id) else {
                continue
            }
            let records = result.records.prefix(5).map { record in
                let documentName = record.segment.document?.name ?? "未命名文档"
                return "[\(knowledgeBase.name) / \(documentName)]\n\(record.segment.content)"
            }
            if !records.isEmpty {
                sections.append(records.joined(separator: "\n\n"))
            }
        }
        return String(sections.joined(separator: "\n\n---\n\n").prefix(40_000))
    }

    private func appendMeetingAgentActivity(
        meetingID: Meeting.ID,
        messageID: MeetingAgentChatMessage.ID,
        text: String
    ) {
        updateMeetingAgentMessage(meetingID: meetingID, messageID: messageID) { message in
            message.appendAgentActivity(text)
        }
    }

    private func updateMeetingAgentMessage(
        meetingID: Meeting.ID,
        messageID: MeetingAgentChatMessage.ID,
        update: (inout MeetingAgentChatMessage) -> Void
    ) {
        guard var messages = meetingAgentMessagesByMeeting[meetingID],
              let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        update(&messages[index])
        messages[index].updatedAt = Date()
        meetingAgentMessagesByMeeting[meetingID] = messages
    }

    private func persistMeetingAgentMessage(
        meetingID: Meeting.ID,
        messageID: MeetingAgentChatMessage.ID
    ) {
        guard let message = meetingAgentMessagesByMeeting[meetingID]?.first(where: { $0.id == messageID }) else {
            return
        }
        do {
            try store?.upsertMeetingAgentChatMessage(message)
        } catch {
            statusMessage = "Agent 会话保存失败：\(error.localizedDescription)"
        }
    }

    private func recoverInterruptedMeetingAgentMessages() {
        for meetingID in Array(meetingAgentMessagesByMeeting.keys) {
            guard var messages = meetingAgentMessagesByMeeting[meetingID] else { continue }
            var changedMessages: [MeetingAgentChatMessage] = []
            for index in messages.indices where messages[index].status == .streaming {
                messages[index].status = .cancelled
                messages[index].appendAgentActivity("应用退出，回答已中断")
                if messages[index].content.isEmpty {
                    messages[index].content = "上次回答因应用退出而中断，请重新发送。"
                    messages[index].timeline.append(MeetingAgentTurnSegment(
                        kind: .final,
                        content: messages[index].content
                    ))
                }
                messages[index].updatedAt = Date()
                changedMessages.append(messages[index])
            }
            meetingAgentMessagesByMeeting[meetingID] = messages
            for message in changedMessages {
                try? store?.upsertMeetingAgentChatMessage(message)
            }
        }
    }

    private func meetingAgentRuntimeConfiguration(meeting: Meeting) -> PiAgentRuntimeConfiguration {
        let resources = PiAgentResourceResolver().resolve()
        return PiAgentRuntimeConfiguration(
            workingDirectoryURL: URL(fileURLWithPath: meetingAgentWorkspacePath, isDirectory: true),
            sessionDirectoryURL: Self.meetingAgentSessionRootURL
                .appendingPathComponent(meeting.id, isDirectory: true),
            extensionURLs: resources.extensions,
            skillURLs: resources.skills,
            sessionName: meeting.title
        )
    }

    private func meetingAnalysisRuntimeConfiguration(meeting: Meeting) -> PiAgentRuntimeConfiguration {
        let resources = PiAgentResourceResolver().resolve()
        let runID = UUID().uuidString
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-analysis-\(runID)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return PiAgentRuntimeConfiguration(
            workingDirectoryURL: workingDirectory,
            sessionDirectoryURL: Self.meetingAgentSessionRootURL
                .appendingPathComponent("Analysis", isDirectory: true)
                .appendingPathComponent(meeting.id, isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true),
            extensionURLs: resources.extensions,
            skillURLs: resources.skills,
            sessionName: "\(meeting.title) AI 分析"
        )
    }

    private static func meetingAgentSessionStatsDescription(_ stats: PiAgentSessionStats) -> String {
        if let tokens = stats.contextTokens, let window = stats.contextWindow {
            let percent = stats.contextPercent.map { Int($0.rounded()) } ?? 0
            return "Pi 上下文：\(tokens.formatted()) / \(window.formatted()) tokens（\(percent)%）；工具 \(stats.toolCalls) 次"
        }
        return "Pi 累计 tokens：\(stats.totalTokens.formatted())；工具 \(stats.toolCalls) 次"
    }

    private func retranscribeMeetingFromRecording(
        meetingID: Meeting.ID,
        audioFilePath: String,
        asrSource: ModelSource,
        isUserInitiated: Bool = true
    ) async {
        if isUserInitiated {
            recordingRetranscriptionMeetingID = meetingID
        }
        defer {
            if isUserInitiated {
                recordingRetranscriptionMeetingID = nil
                recordingRetranscriptionTask = nil
            }
        }
        updateMeeting(id: meetingID) { meeting in
            meeting.status = .processing
            meeting.minutesGenerationError = nil
            meeting.diarizationStatus = .notStarted
        }
        statusMessage = "正在读取录音并准备重新转写。"

        var completedSegments = 0
        var skippedTurns = 0
        var failedTurns = 0
        var emptyTextTurns = 0
        var firstTranscriptionError: String?
        var originalSegments: [TranscriptSegment] = []
        var turnCount = 0
        do {
            try Task.checkCancellation()
            let meeting = meetings.first(where: { $0.id == meetingID })
            let inputs = meeting.map { FinalTrackTranscriptionPlan.inputs(for: $0) }
                ?? [FinalTrackTranscriptionInput(track: .mixed, audioFilePath: audioFilePath)]
            guard !inputs.isEmpty else {
                throw WAVAudioSegmentReaderError.fileTooSmall
            }
            var chunksByTrack: [(FinalTrackTranscriptionInput, [AudioChunk])] = []
            for input in inputs {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: input.audioFilePath)
                _ = try MeetingAudioFileRepair.repairLegacyZeroHeaderIfNeeded(url: url)
                let audioDurationMs = try WAVAudioSegmentReader.durationMs(from: url)
                guard audioDurationMs > 0 else {
                    continue
                }
                let chunks = try WAVAudioSegmentReader.readChunks(from: url, chunkDurationMs: 10_000)
                guard !chunks.isEmpty else {
                    continue
                }
                chunksByTrack.append((input, chunks))
            }
            guard !chunksByTrack.isEmpty else {
                throw WAVAudioSegmentReaderError.fileTooSmall
            }
            turnCount = chunksByTrack.reduce(0) { $0 + $1.1.count }
            try Task.checkCancellation()

            originalSegments = segmentsByMeeting[meetingID, default: []]
            clearTranscriptSegments(meetingID: meetingID)
            // 会议级人工 mapping 是独立事实；重新转写不能清掉。
            try Task.checkCancellation()

            var sequence = 0
            for (input, chunks) in chunksByTrack {
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    sequence += 1
                    let speechQuality = SpeechQualityGate.analyze(chunk)
                    if !speechQuality.shouldTranscribe {
                        skippedTurns += 1
                        continue
                    }
                    statusMessage = "\(finalDiarizationTrackName(input.track))重新转写中：\(index + 1)/\(chunks.count)。"
                    do {
                        let asr = try await transcribeRecordingChunk(chunk, using: asrSource)
                        try Task.checkCancellation()
                        let text = asr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            emptyTextTurns += 1
                            skippedTurns += 1
                            continue
                        }
                        let segment = try appendASRSegment(
                            asr,
                            meetingID: meetingID,
                            sequence: sequence,
                            speaker: disabledSpeakerResolution(),
                            sourceTrack: input.track,
                            deduplicate: false
                        )
                        if !segment.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            completedSegments += 1
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            throw CancellationError()
                        }
                        failedTurns += 1
                        if firstTranscriptionError == nil {
                            firstTranscriptionError = errorDescription(from: error)
                        }
                        skippedTurns += 1
                        statusMessage = "\(finalDiarizationTrackName(input.track))片段 \(index + 1)/\(chunks.count) 转写失败，已跳过：\(errorDescription(from: error))"
                    }
                }
            }

            if completedSegments > 0 {
                updateMeeting(id: meetingID) { meeting in
                    meeting.status = .done
                    meeting.diarizationStatus = .notStarted
                }
                let skippedMessage = skippedTurns > 0 ? "，跳过 \(skippedTurns) 个空白或失败片段" : ""
                statusMessage = "录音重新转写完成：生成 \(completedSegments) 个片段\(skippedMessage)。"
            } else {
                if !originalSegments.isEmpty {
                    restoreTranscriptSegments(originalSegments)
                }
                updateMeeting(id: meetingID) { meeting in
                    meeting.status = .failed
                    meeting.diarizationStatus = .notStarted
                }
                statusMessage = recordingRetranscriptionEmptyResultMessage(
                    skippedTurns: skippedTurns,
                    failedTurns: failedTurns,
                    emptyTextTurns: emptyTextTurns,
                    firstTranscriptionError: firstTranscriptionError,
                    restoredOriginalCount: originalSegments.count
                )
            }
            refreshExportPreview()
        } catch is CancellationError {
            if completedSegments == 0, !originalSegments.isEmpty {
                restoreTranscriptSegments(originalSegments)
            }
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .done
                meeting.diarizationStatus = .notStarted
            }
            refreshExportPreview()
            let segmentMessage = completedSegments > 0 ? "，已保留 \(completedSegments) 个已完成片段" : ""
            let totalMessage = turnCount > 0 ? "，共 \(turnCount) 个待处理片段" : ""
            let restoreMessage = completedSegments == 0 && !originalSegments.isEmpty ? "，已恢复原有 \(originalSegments.count) 个片段" : ""
            statusMessage = "已停止录音重新转写\(segmentMessage)\(totalMessage)\(restoreMessage)。"
        } catch {
            if completedSegments == 0, !originalSegments.isEmpty {
                restoreTranscriptSegments(originalSegments)
            }
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .failed
                meeting.diarizationStatus = .notStarted
            }
            let restoreMessage = completedSegments == 0 && !originalSegments.isEmpty ? " 已恢复原有 \(originalSegments.count) 个片段。" : ""
            statusMessage = "录音重新转写失败：\(errorDescription(from: error))\(restoreMessage)"
        }

    }

    private func runFinalSpeakerProcessing(meetingID: Meeting.ID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        guard let voiceprintSource = defaultModelSource(type: .voiceprint),
              voiceprintSource.baseURL == "sidecar://diarization" else {
            updateMeeting(id: meetingID) { $0.diarizationStatus = .notStarted }
            statusMessage = "未启用会小纪内置声纹模型，已跳过会后说话人处理。"
            return
        }
        let tracks = finalDiarizationTracks(for: meeting)
        guard !tracks.isEmpty else {
            updateMeeting(id: meetingID) { $0.diarizationStatus = .notStarted }
            return
        }

        updateMeeting(id: meetingID) { $0.diarizationStatus = .temporary }
        statusMessage = "录音已保存，正在按音轨进行说话人分离与声纹识别。"

        let huggingFaceToken = DiarizationTokenResolver.resolve(
            source: voiceprintSource,
            environment: ProcessInfo.processInfo.environment
        )

        let transport: PersistentJSONLSidecarTransport
        do {
            transport = try makeFinalDiarizationTransport(huggingFaceToken: huggingFaceToken)
        } catch {
            recordFinalDiarizationFailure(meetingID: meetingID, tracks: tracks, error: error)
            return
        }
        defer { Task { await transport.shutdown() } }

        let client = DiarizationSidecarClient(transport: transport)
        var collectedTurns: [DiarizationTurn] = []
        var embeddingCandidatesBySpeakerKey: [String: [VoiceprintResult]] = [:]
        var succeededTracks = 0
        var failureMessages: [String] = []

        do {
            statusMessage = "正在加载本地说话人分离与声纹模型。首次使用可能需要下载模型权重。"
            _ = try await client.preload(huggingFaceToken: huggingFaceToken)
        } catch {
            recordFinalDiarizationFailure(meetingID: meetingID, tracks: tracks, error: error)
            return
        }

        for (track, path) in tracks {
            let runID = "final_\(meetingID)_\(track.rawValue)"
            upsertDiarizationRun(DiarizationRun(
                id: runID,
                meetingID: meetingID,
                scope: .full,
                status: .running,
                audioFilePath: path
            ))
            do {
                statusMessage = "正在分离\(finalDiarizationTrackName(track))。"
                let turns = try await client.diarizeFile(
                    path: path,
                    speakerConstraint: diarizationSpeakerPreset.constraint
                )
                let scopedTurns = turns.map { turn in
                    DiarizationTurn(
                        startMs: turn.startMs,
                        endMs: turn.endMs,
                        speakerKey: "\(track.rawValue):\(turn.speakerKey)",
                        confidence: turn.confidence
                    )
                }
                for speakerKey in Set(turns.map(\.speakerKey)) {
                    let scopedKey = "\(track.rawValue):\(speakerKey)"
                    let windows = DiarizationSpeakerMatcher.embeddingWindows(
                        for: speakerKey,
                        turns: turns
                    )
                    for window in windows {
                        if let embedding = try? await client.embedSpeaker(
                            path: path,
                            startMs: window.startMs,
                            endMs: window.endMs
                        ) {
                            embeddingCandidatesBySpeakerKey[scopedKey, default: []].append(embedding)
                        }
                    }
                }
                collectedTurns.append(contentsOf: scopedTurns)
                succeededTracks += 1
                upsertDiarizationRun(DiarizationRun(
                    id: runID,
                    meetingID: meetingID,
                    scope: .full,
                    status: .succeeded,
                    audioFilePath: path,
                    turns: scopedTurns
                ))
            } catch {
                let message = errorDescription(from: error)
                failureMessages.append("\(finalDiarizationTrackName(track))：\(message)")
                upsertDiarizationRun(DiarizationRun(
                    id: runID,
                    meetingID: meetingID,
                    scope: .full,
                    status: .failed,
                    audioFilePath: path,
                    errorMessage: message
                ))
            }
        }

        guard succeededTracks > 0 else {
            updateMeeting(id: meetingID) { $0.diarizationStatus = .failed }
            statusMessage = "说话人分离与声纹识别失败：\(failureMessages.joined(separator: "；"))"
            return
        }

        if !collectedTurns.isEmpty {
            let existingMappings = diarizationMappingsByMeeting[meetingID, default: []]
            let automaticMappings = DiarizationSpeakerMatcher.buildMappings(
                meetingID: meetingID,
                turns: collectedTurns,
                embeddingCandidatesBySpeakerKey: embeddingCandidatesBySpeakerKey,
                people: people,
                samples: voiceprintSamples
            )
            let mappings = DiarizationSpeakerMatcher.preservingManualMappings(
                existing: existingMappings,
                automatic: automaticMappings
            )
            let result = DiarizationApplication.apply(
                turns: collectedTurns,
                to: segmentsByMeeting[meetingID, default: []],
                mappings: mappings
            )
            replaceTranscriptSegments(meetingID: meetingID, with: result.segments)
            replaceDiarizationSpeakerMappings(meetingID: meetingID, with: result.mappings)
        }

        updateMeeting(id: meetingID) { $0.diarizationStatus = .final }
        refreshExportPreview()
        let failureSuffix = failureMessages.isEmpty ? "" : "；部分音轨失败：\(failureMessages.joined(separator: "；"))"
        let turnSuffix = collectedTurns.isEmpty ? "未检测到可归属的说话人片段" : "已生成 \(collectedTurns.count) 个说话人片段并完成声纹匹配"
        statusMessage = "会后说话人处理完成：\(turnSuffix)\(failureSuffix)。"
    }

    private func finalDiarizationTrackName(_ track: AudioCaptureTrack) -> String {
        switch track {
        case .microphone:
            return "麦克风音轨"
        case .computer:
            return "电脑音频音轨"
        case .mixed:
            return "混合音轨"
        }
    }

    private func finalDiarizationTracks(for meeting: Meeting) -> [(AudioCaptureTrack, String)] {
        let separateTracks: [(AudioCaptureTrack, String)] = [
            (AudioCaptureTrack.microphone, meeting.microphoneAudioFilePath),
            (AudioCaptureTrack.computer, meeting.computerAudioFilePath)
        ].compactMap { track, path -> (AudioCaptureTrack, String)? in
            guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
            return (track, path)
        }
        if !separateTracks.isEmpty {
            return separateTracks
        }
        guard let path = meeting.audioFilePath, FileManager.default.fileExists(atPath: path) else {
            return []
        }
        return [(.mixed, path)]
    }

    private func makeFinalDiarizationTransport(
        huggingFaceToken: String?
    ) throws -> PersistentJSONLSidecarTransport {
        let fileManager = FileManager.default
        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let homeDirectoryURL = fileManager.homeDirectoryForCurrentUser
        let bundleResourcesURL = Bundle.main.resourceURL
        let projectRootURL = DiarizationSidecarRuntimeResolver.resolveProjectRoot(
            currentDirectoryURL: currentDirectoryURL,
            homeDirectoryURL: homeDirectoryURL
        )
        guard let scriptURL = DiarizationSidecarRuntimeResolver.resolveSidecarScriptURL(
            currentDirectoryURL: currentDirectoryURL,
            homeDirectoryURL: homeDirectoryURL,
            bundleResourcesURL: bundleResourcesURL
        ), let setupScriptURL = DiarizationSidecarRuntimeResolver.resolveSetupScriptURL(
            currentDirectoryURL: currentDirectoryURL,
            homeDirectoryURL: homeDirectoryURL,
            bundleResourcesURL: bundleResourcesURL
        ) else {
            throw FinalDiarizationSetupError(message: "未找到说话人分离 sidecar 源文件。请重新安装会小纪。")
        }

        let isBundled = bundleResourcesURL.map { scriptURL.path.hasPrefix($0.path) } ?? false
        let defaultEnvironmentRoot = DiarizationSidecarRuntimeResolver.sidecarEnvironmentRootURL()
        let environment = DiarizationSidecarRuntimeResolver.resolvePythonEnvironment(
            projectRootURL: projectRootURL,
            homeDirectoryURL: homeDirectoryURL,
            allowProjectFallback: !isBundled
        )
        let environmentRoot = environment?.rootURL ?? defaultEnvironmentRoot
        let missingPythonMessage = DiarizationSidecarRuntimeResolver.missingPythonEnvironmentMessage(
            environmentRootURL: environmentRoot,
            setupScriptURL: setupScriptURL
        )
        let launch = DiarizationSidecarLaunchConfiguration(
            scriptURL: scriptURL,
            backend: .production,
            huggingFaceToken: huggingFaceToken,
            pythonExecutableURL: environment?.executableURL,
            workingDirectoryURL: environmentRoot,
            missingPythonMessage: missingPythonMessage,
            sidecarErrorMessageTransform: { message in
                DiarizationSidecarRuntimeResolver.missingDependencyMessage(
                    message,
                    environmentRootURL: environmentRoot,
                    setupScriptURL: setupScriptURL
                ) ?? message
            }
        )
        return PersistentJSONLSidecarTransport(configuration: launch)
    }

    private func recordFinalDiarizationFailure(
        meetingID: Meeting.ID,
        tracks: [(AudioCaptureTrack, String)],
        error: Error
    ) {
        let message = errorDescription(from: error)
        for (track, path) in tracks {
            upsertDiarizationRun(DiarizationRun(
                id: "final_\(meetingID)_\(track.rawValue)",
                meetingID: meetingID,
                scope: .full,
                status: .failed,
                audioFilePath: path,
                errorMessage: message
            ))
        }
        updateMeeting(id: meetingID) { $0.diarizationStatus = .failed }
        statusMessage = "说话人分离与声纹识别未启动：\(message)"
    }

    private func transcribeRecordingChunk(_ chunk: AudioChunk, using source: ModelSource) async throws -> ASRSegment {
        if source.baseURL.hasPrefix("mock://") {
            return try await MockASRClient(text: "录音重新转写片段").transcribe(chunk: chunk)
        }
        return try await OpenAICompatibleASRClient(
            source: source,
            uploader: URLSessionDataUploader(session: HTTPSessionFactory.asr())
        ).transcribe(chunk: chunk)
    }

    private func recordingRetranscriptionEmptyResultMessage(
        skippedTurns: Int,
        failedTurns: Int,
        emptyTextTurns: Int,
        firstTranscriptionError: String?,
        restoredOriginalCount: Int
    ) -> String {
        let detail: String
        if let firstTranscriptionError {
            detail = "ASR 转写全部失败，首个错误：\(firstTranscriptionError)"
        } else if emptyTextTurns > 0 {
            detail = "ASR 对 \(emptyTextTurns) 个片段返回空文本"
        } else if skippedTurns > 0 {
            detail = "所有片段被判定为空白、低质量或转写失败"
        } else {
            detail = "录音没有生成可转写片段"
        }
        let failedMessage = failedTurns > 0 ? "，失败片段 \(failedTurns) 个" : ""
        let restoreMessage = restoredOriginalCount > 0 ? "，已恢复原有 \(restoredOriginalCount) 个片段" : ""
        return "录音重新转写未生成有效片段：\(detail)\(failedMessage)\(restoreMessage)。"
    }

    private func clearTranscriptSegments(meetingID: Meeting.ID) {
        let existingSegments = segmentsByMeeting[meetingID, default: []]
        segmentsByMeeting[meetingID] = []
        for segment in existingSegments {
            do {
                try store?.deleteSegment(id: segment.id)
            } catch {
                statusMessage = "旧转写片段删除失败：\(error.localizedDescription)"
            }
        }
        refreshExportPreview()
    }

    private func restoreTranscriptSegments(_ segments: [TranscriptSegment]) {
        guard let meetingID = segments.first?.meetingID else {
            return
        }
        let restored = segments.sorted { $0.startMs < $1.startMs }
        segmentsByMeeting[meetingID] = restored
        for segment in restored {
            persistSegment(segment)
        }
        refreshExportPreview()
    }

    private func appendASRSegment(
        _ asr: ASRSegment,
        meetingID: Meeting.ID,
        sequence: Int,
        speaker: LiveSpeakerResolution? = nil,
        sourceTrack: AudioCaptureTrack? = nil,
        timelineOffsetMs: Int = 0,
        deduplicate: Bool = true
    ) throws -> TranscriptSegment {
        let shiftedASR = RecordingTimelineContinuation.apply(offsetMs: timelineOffsetMs, to: asr)
        let fallbackLabel = "未知发言人 \(sequence)"
        let label = speaker?.label ?? fallbackLabel
        let text = shiftedASR.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = segmentsByMeeting[meetingID, default: []]

        // 实时 ASR 会重复回传同一窗口的前缀或整段幻觉短语；
        // 与最近 N 段（不区分 speaker）做重复检测，命中则丢弃或吸收进上一段。
        let recentAutoSegments = segments.suffix(LiveTranscriptDeduplicator.defaultRecentComparisonWindow)
            .filter { !$0.isManual }
        let recentTexts: [String] = recentAutoSegments.map { seg in
            let final = seg.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return final.isEmpty ? seg.rawText : final
        }

        if deduplicate, !recentTexts.isEmpty {
            let appendText = LiveTranscriptDeduplicator.appendableText(
                recentTexts: recentTexts,
                currentText: text
            )
            guard let appendText, !appendText.isEmpty else {
                // 整段被判定重复：拉伸上一段 endMs 保持时间线连续，不新增段落
                if let previousSegment = segments.last, !previousSegment.isManual {
                    var updatedPrevious = previousSegment
                    updatedPrevious.endMs = max(updatedPrevious.endMs, shiftedASR.endMs)
                    try persistSegmentOrThrow(updatedPrevious)
                    segments[segments.count - 1] = updatedPrevious
                    segmentsByMeeting[meetingID] = segments
                    refreshExportPreview()
                    return updatedPrevious
                }
                // 无历史段可拉伸 → 直接丢弃，返回一个不落库的占位段
                return TranscriptSegment(
                    id: "segment_\(meetingID)_asr_dropped_\(sequence)_\(UUID().uuidString)",
                    meetingID: meetingID,
                    startMs: shiftedASR.startMs,
                    endMs: shiftedASR.endMs,
                    speakerLabel: label,
                    autoSpeakerLabel: speaker?.autoLabel ?? label,
                    sourceTrack: sourceTrack,
                    personID: speaker?.personID,
                    personName: speaker?.personName,
                    confidence: speaker?.confidence ?? 0,
                    rawText: "",
                    processedText: "",
                    finalText: ""
                )
            }
            let segment = TranscriptSegment(
                id: "segment_\(meetingID)_asr_\(sequence)_\(UUID().uuidString)",
                meetingID: meetingID,
                startMs: shiftedASR.startMs,
                endMs: shiftedASR.endMs,
                speakerLabel: label,
                autoSpeakerLabel: speaker?.autoLabel ?? label,
                sourceTrack: sourceTrack,
                personID: speaker?.personID,
                personName: speaker?.personName,
                confidence: speaker?.confidence ?? 0,
                rawText: appendText,
                processedText: appendText,
                finalText: appendText
            )
            try persistSegmentOrThrow(segment)
            segments.append(segment)
            segmentsByMeeting[meetingID] = segments
            refreshExportPreview()
            return segment
        }

        let segment = TranscriptSegment(
            id: "segment_\(meetingID)_asr_\(sequence)_\(UUID().uuidString)",
            meetingID: meetingID,
            startMs: shiftedASR.startMs,
            endMs: shiftedASR.endMs,
            speakerLabel: label,
            autoSpeakerLabel: speaker?.autoLabel ?? label,
            sourceTrack: sourceTrack,
            personID: speaker?.personID,
            personName: speaker?.personName,
            confidence: speaker?.confidence ?? 0,
            rawText: text,
            processedText: text,
            finalText: text
        )
        try persistSegmentOrThrow(segment)
        segments.append(segment)
        segmentsByMeeting[meetingID] = segments
        refreshExportPreview()
        return segment
    }

    private func handleLiveChunk(_ chunk: AudioChunk) {
        guard (activeCapture != nil || isStoppingCapture), activeRecordingMeetingID != nil else {
            return
        }
        do {
            try meetingAudioWriters?.appendMixed(chunk)
            if let elapsedMs = meetingAudioWriters?.mixedDurationMs,
               elapsedMs / 1_000 != recordingElapsedMs / 1_000 {
                recordingElapsedMs = elapsedMs
            }
        } catch {
            statusMessage = "会议音频保存失败：\(error.localizedDescription)"
        }
        for transcribableChunk in liveChunkAccumulator.appendAll(chunk) {
            enqueueLiveTranscriptionChunk(transcribableChunk)
        }
    }

    private func handleTrackChunk(_ track: AudioCaptureTrack, _ chunk: AudioChunk) {
        do {
            try meetingAudioWriters?.appendTrack(track, chunk: chunk)
        } catch {
            statusMessage = "会议分轨音频保存失败：\(error.localizedDescription)"
        }
    }

    private func flushLiveChunkAccumulator() {
        for transcribableChunk in liveChunkAccumulator.flushAll() {
            enqueueLiveTranscriptionChunk(transcribableChunk)
        }
    }

    private func enqueueLiveTranscriptionChunk(_ chunk: AudioChunk) {
        guard let meetingID = activeRecordingMeetingID else {
            return
        }
        var timelineChunk = chunk
        timelineChunk.startMs += liveRecordingOffsetMs
        timelineChunk.endMs += liveRecordingOffsetMs
        pendingTranscriptionWriteCounts[meetingID, default: 0] += 1
        Task {
            defer {
                pendingTranscriptionWriteCounts[meetingID, default: 1] -= 1
                if pendingTranscriptionWriteCounts[meetingID] == 0 {
                    pendingTranscriptionWriteCounts[meetingID] = nil
                }
            }
            do {
                guard let pendingTranscriptionQueue else {
                    throw PendingTranscriptionQueueError.invalidConfiguration
                }
                _ = try await pendingTranscriptionQueue.enqueue(
                    meetingID: meetingID,
                    chunk: timelineChunk
                )
                startPendingTranscriptionWorker(meetingID: meetingID)
            } catch {
                unresolvedTranscriptionCounts[meetingID, default: 0] += 1
                if selectedMeetingID == meetingID {
                    statusMessage = "实时转写片段保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func startPendingTranscriptionWorker(meetingID: Meeting.ID) {
        guard pendingTranscriptionWorkers[meetingID] == nil else {
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPendingTranscriptionWorker(meetingID: meetingID)
            self.pendingTranscriptionWorkers[meetingID] = nil
            await self.finishRecoveredTranscriptionIfNeeded(meetingID: meetingID)
        }
        pendingTranscriptionWorkers[meetingID] = task
    }

    private func runPendingTranscriptionWorker(meetingID: Meeting.ID) async {
        guard let pendingTranscriptionQueue else {
            unresolvedTranscriptionCounts[meetingID, default: 0] += 1
            return
        }

        while !Task.isCancelled {
            let item: PendingTranscriptionItem
            do {
                guard let next = try await pendingTranscriptionQueue.next(meetingID: meetingID) else {
                    break
                }
                item = next
            } catch {
                let records = await pendingTranscriptionQueue.pendingRecords(meetingID: meetingID)
                unresolvedTranscriptionCounts[meetingID] = max(1, records.count)
                markPendingTranscriptionBlocked(
                    meetingID: meetingID,
                    message: "待转写音频恢复失败：\(error.localizedDescription)"
                )
                break
            }

            if Self.isNearSilentChunk(item.chunk) {
                do {
                    try await pendingTranscriptionQueue.markSilent(id: item.record.id)
                } catch {
                    let records = await pendingTranscriptionQueue.pendingRecords(meetingID: meetingID)
                    unresolvedTranscriptionCounts[meetingID] = max(1, records.count)
                    markPendingTranscriptionBlocked(
                        meetingID: meetingID,
                        message: "静音片段清理失败，待识别音频已保留：\(error.localizedDescription)"
                    )
                    break
                }
                continue
            }

            guard let asrSource = defaultModelSource(type: .asr),
                  asrSource.baseURL.hasPrefix("mock://") || !asrSource.baseURL.contains("example.com") else {
                let shouldContinue = await recordPendingTranscriptionFailure(
                    item: item,
                    queue: pendingTranscriptionQueue,
                    message: "未配置可用的默认 ASR。"
                )
                if !shouldContinue { break }
                continue
            }

            do {
                let asr = try await transcribeRecordingChunk(item.chunk, using: asrSource)
                guard !asr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    let shouldContinue = await recordPendingTranscriptionFailure(
                        item: item,
                        queue: pendingTranscriptionQueue,
                        message: "ASR 未返回文字。"
                    )
                    if !shouldContinue { break }
                    continue
                }
                let segment = try appendASRSegment(
                    asr,
                    meetingID: meetingID,
                    sequence: item.chunk.sequence,
                    speaker: disabledSpeakerResolution()
                )
                try await pendingTranscriptionQueue.markSucceeded(id: item.record.id)
                unresolvedTranscriptionCounts[meetingID] = 0
                if selectedMeetingID == meetingID {
                    statusMessage = "已处理实时音频片段：\(segment.rawText)"
                }
            } catch {
                let shouldContinue = await recordPendingTranscriptionFailure(
                    item: item,
                    queue: pendingTranscriptionQueue,
                    message: errorDescription(from: error),
                    allowRetry: Self.shouldAutomaticallyRetryASR(after: error)
                )
                if !shouldContinue { break }
            }
        }
    }

    private func recordPendingTranscriptionFailure(
        item: PendingTranscriptionItem,
        queue: PendingTranscriptionQueue,
        message: String,
        allowRetry: Bool = true
    ) async -> Bool {
        do {
            let disposition = try await queue.markFailed(
                id: item.record.id,
                allowRetry: allowRetry
            )
            switch disposition {
            case .retryable(let attemptCount):
                if selectedMeetingID == item.record.meetingID {
                    statusMessage = "实时转写失败，正在重试（\(attemptCount)/\(PendingTranscriptionQueue.defaultMaximumAttempts)）：\(message)"
                }
                try? await Task.sleep(for: .milliseconds(400 * attemptCount))
                return true
            case .exhausted:
                let records = await queue.pendingRecords(meetingID: item.record.meetingID)
                unresolvedTranscriptionCounts[item.record.meetingID] = records.count
                let failureSummary = allowRetry ? "实时转写连续失败" : "实时转写已暂停自动重试"
                markPendingTranscriptionBlocked(
                    meetingID: item.record.meetingID,
                    message: "\(failureSummary)，待识别音频已保留：\(message)"
                )
                return false
            }
        } catch {
            unresolvedTranscriptionCounts[item.record.meetingID, default: 0] += 1
            markPendingTranscriptionBlocked(
                meetingID: item.record.meetingID,
                message: "待转写音频状态保存失败：\(error.localizedDescription)"
            )
            return false
        }
    }

    private func markPendingTranscriptionBlocked(meetingID: Meeting.ID, message: String) {
        postprocessingMeetingIDs.remove(meetingID)
        updateMeeting(id: meetingID) { meeting in
            meeting.status = .failed
        }
        if selectedMeetingID == meetingID {
            statusMessage = message
        }
    }

    static func shouldAutomaticallyRetryASR(after error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        guard let urlError = error as? URLError else {
            return true
        }
        return urlError.code != .timedOut && urlError.code != .cancelled
    }

    private func disabledSpeakerResolution() -> LiveSpeakerResolution {
        LiveSpeakerResolution(
            label: "未分配发言人",
            autoLabel: "未分配发言人",
            personID: nil,
            personName: nil,
            confidence: 0,
            embedding: nil
        )
    }

    /// 静音判定：整块 RMS 低于 `silenceRMSThreshold`（≈ -50 dBFS）即视为空白，
    /// 用于跳过 ASR 避免大量幻觉重复。
    static let silenceRMSThreshold: Float = 0.003
    static func isNearSilentChunk(_ chunk: AudioChunk) -> Bool {
        !SpeechQualityGate.analyze(chunk).shouldTranscribe
    }

    private func makeCaptureSession(for source: CaptureSource) -> AudioCaptureSession {
        let microphoneDeviceID = selectedMicrophoneDeviceID.isEmpty ? nil : selectedMicrophoneDeviceID
        switch Self.normalizedCaptureSource(source) {
        case .microphone:
            return MicrophoneCapture(deviceID: microphoneDeviceID)
        case .screenAudio:
            return ScreenAudioCapture()
        case .mixed:
            return MixedAudioCapture(microphoneDeviceID: microphoneDeviceID)
        case .appAudio, .systemAudio, .imported:
            // normalizedCaptureSource 已兼容旧数据，永远不会到这里。
            return ScreenAudioCapture()
        }
    }

    private func refreshMicrophoneDevices(preferredDeviceID: String?) {
        let devices = MicrophoneDeviceCatalog.availableDevices()
        let selectedID = MicrophoneSelectionPolicy.preferredDeviceID(
            devices: devices,
            persistedDeviceID: preferredDeviceID?.isEmpty == false ? preferredDeviceID : nil,
            systemDefaultDeviceID: MicrophoneDeviceCatalog.systemDefaultDeviceID(),
            isBluetoothOutput: MicrophoneDeviceCatalog.isBluetoothDefaultOutput()
        )
        microphoneDevices = devices
        selectedMicrophoneDeviceID = selectedID ?? ""
        if let selectedID, store != nil {
            persistAppSetting(AppSettingKey.microphoneDeviceID, value: selectedID)
        }
    }

    private func makeAudioCaptureCallbacks() -> AudioCaptureCallbacks {
        let callbackBuffer = captureCallbackBuffer
        return AudioCaptureCallbacks(
            onChunk: { [weak self] chunk in
                callbackBuffer.append(.mixed(chunk))
                Task { @MainActor in
                    self?.drainCaptureCallbackBuffer()
                }
            },
            onTrackChunk: { [weak self] track, chunk in
                callbackBuffer.append(.track(track, chunk))
                Task { @MainActor in
                    self?.drainCaptureCallbackBuffer()
                }
            },
            onLevel: { [weak self] level in
                Task { @MainActor in
                    self?.inputLevel = Double(level)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.statusMessage = "采集错误：\(self.errorDescription(from: error))"
                }
            }
        )
    }

    private func drainCaptureCallbackBuffer() {
        for event in captureCallbackBuffer.drain() {
            switch event {
            case .mixed(let chunk):
                handleLiveChunk(chunk)
            case .track(let track, let chunk):
                handleTrackChunk(track, chunk)
            }
        }
    }

    private func warmUpRealtimeModels() async throws {
        let asrSource: ModelSource
        do {
            asrSource = try RealtimeASRWarmupPreflight.validate(asr: defaultModelSource(type: .asr))
        } catch {
            switch error {
            case RealtimeModelWarmupError.missingASR,
                 RealtimeModelWarmupError.invalidASRBaseURL:
                throw RecordingStartupError.asrWarmup(errorDescription(from: error))
            default:
                throw RecordingStartupError.asrWarmup(error.localizedDescription)
            }
        }

        let warmupChunk = AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 300,
            samples: Array(repeating: 0, count: 4_800),
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )

        do {
            if asrSource.baseURL.hasPrefix("mock://") {
                _ = try await MockASRClient(text: "").transcribe(chunk: warmupChunk)
            } else {
                    _ = try await OpenAICompatibleASRClient(
                        source: asrSource,
                        uploader: URLSessionDataUploader(session: HTTPSessionFactory.asr())
                    ).transcribe(chunk: warmupChunk)
            }
        } catch {
            throw RecordingStartupError.asrWarmup(error.localizedDescription)
        }
    }

    private func errorDescription(from error: Error) -> String {
        if let captureError = error as? AudioCaptureError {
            return captureError.displayMessage
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func errorTypeDescription(from error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    private func prepareMeetingAudioWriter() throws {
        guard let activeRecordingMeetingID else {
            throw RecordingWriterError.missingMeeting
        }
        let audioURL = meetingAudioURL(meetingID: activeRecordingMeetingID, fileName: "recording.wav")
        let microphoneURL = selectedCaptureSource == .mixed ? meetingAudioURL(meetingID: activeRecordingMeetingID, fileName: "microphone.wav") : nil
        let computerURL = selectedCaptureSource == .mixed ? meetingAudioURL(meetingID: activeRecordingMeetingID, fileName: "computer.wav") : nil
        meetingAudioWriters = try MeetingAudioTrackWriters(
            mixedURL: audioURL,
            microphoneURL: microphoneURL,
            computerURL: computerURL
        )
        updateMeeting(id: activeRecordingMeetingID) { meeting in
            meeting.audioFilePath = audioURL.path
            meeting.microphoneAudioFilePath = microphoneURL?.path
            meeting.computerAudioFilePath = computerURL?.path
            meeting.diarizationStatus = .notStarted
        }
    }

    private func finishMeetingAudioWriter() {
        do {
            try meetingAudioWriters?.finish()
        } catch {
            statusMessage = "会议音频文件保存失败：\(error.localizedDescription)"
        }
        meetingAudioWriters = nil
    }

    private func waitForPendingLiveTranscription(meetingID: Meeting.ID) async {
        while pendingTranscriptionWriteCounts[meetingID, default: 0] > 0
            || pendingTranscriptionWorkers[meetingID] != nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let pendingTranscriptionQueue else {
            unresolvedTranscriptionCounts[meetingID, default: 0] += 1
            return
        }
        let records = await pendingTranscriptionQueue.pendingRecords(meetingID: meetingID)
        unresolvedTranscriptionCounts[meetingID] = records.count
    }

    private func finishRecoveredTranscriptionIfNeeded(meetingID: Meeting.ID) async {
        guard activeRecordingMeetingID != meetingID,
              pendingTranscriptionWriteCounts[meetingID, default: 0] == 0,
              let pendingTranscriptionQueue,
              await pendingTranscriptionQueue.isDrained(meetingID: meetingID),
              let meeting = meetings.first(where: { $0.id == meetingID }),
              meeting.endedAt != nil,
              meeting.status == .processing || meeting.status == .failed else {
            return
        }
        unresolvedTranscriptionCounts[meetingID] = 0
        startPostprocessing(meetingID: meetingID)
    }

    private func suspendPendingTranscriptionsAfterRestart() async {
        guard let pendingTranscriptionQueue else { return }
        let records = await pendingTranscriptionQueue.pendingRecords()
        for meetingID in Set(records.map(\.meetingID)) where meetings.contains(where: { $0.id == meetingID }) {
            let pendingCount = records.lazy.filter { $0.meetingID == meetingID }.count
            unresolvedTranscriptionCounts[meetingID] = pendingCount
            postprocessingMeetingIDs.remove(meetingID)
            recentlyCompletedMeetingIDs.remove(meetingID)
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .failed
            }
            _ = setPostprocessRecoveryPending(false, meetingID: meetingID)
            if selectedMeetingID == meetingID {
                statusMessage = "发现 \(pendingCount) 个上次遗留的待转写片段，已暂停自动恢复，避免占用模型服务。"
            }
        }
    }

    private func resumeBackgroundProcessingIfNeeded() async {
        await suspendPendingTranscriptionsAfterRestart()
        let pendingMeetingIDs: Set<Meeting.ID>
        if let pendingTranscriptionQueue {
            pendingMeetingIDs = Set(await pendingTranscriptionQueue.pendingRecords().map(\.meetingID))
        } else {
            pendingMeetingIDs = []
        }
        let activeProcessingMeetingIDs = Set(
            meetings.lazy.filter { $0.status == .processing }.map(\.id)
        )
        let staleRecoveryMeetingIDs = pendingPostprocessRecoveryMeetingIDs.subtracting(
            activeProcessingMeetingIDs.union(pendingMeetingIDs)
        )
        for meetingID in staleRecoveryMeetingIDs {
            _ = setPostprocessRecoveryPending(false, meetingID: meetingID)
        }
        let recoverableMeetingIDs = meetings.lazy
            .filter { meeting in
                self.pendingPostprocessRecoveryMeetingIDs.contains(meeting.id)
                    && meeting.status == .processing
                    && meeting.endedAt != nil
                    && !pendingMeetingIDs.contains(meeting.id)
            }
            .map(\.id)
        for meetingID in recoverableMeetingIDs {
            startPostprocessing(meetingID: meetingID)
        }

        let interruptedUnknownProcessingIDs = meetings.lazy
            .filter { meeting in
                meeting.status == .processing
                    && meeting.endedAt != nil
                    && !pendingMeetingIDs.contains(meeting.id)
                    && !self.pendingPostprocessRecoveryMeetingIDs.contains(meeting.id)
            }
            .map(\.id)
        for meetingID in interruptedUnknownProcessingIDs {
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .failed
            }
        }
    }

    private var hasActiveRecordingWork: Bool {
        activeRecordingMeetingID != nil
            || activeCapture != nil
            || isCaptureTransitioning
            || recordingStartupState == .starting
            || recordingStartupState == .recording
            || recordingStartupState == .paused
    }

    @discardableResult
    private func ensurePersistenceAvailable(action: String) -> Bool {
        guard store != nil else {
            statusMessage = "本地数据库不可用，不能\(action)。请先恢复数据库后再继续。"
            return false
        }
        return true
    }

    private static func normalizedCaptureSource(_ source: CaptureSource) -> CaptureSource {
        switch source {
        case .appAudio, .systemAudio:
            return .screenAudio
        case .imported:
            return .microphone
        case .microphone, .screenAudio, .mixed:
            return source
        }
    }

    private func meetingAudioURL(meetingID: Meeting.ID, fileName: String) -> URL {
        meetingAudioDirectoryURL(meetingID: meetingID).appendingPathComponent(fileName)
    }

    private static var pendingTranscriptionRootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("会小纪", isDirectory: true)
            .appendingPathComponent("PendingASR", isDirectory: true)
    }

    private static var defaultMeetingAgentWorkspaceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private static var meetingAgentSessionRootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("会小纪", isDirectory: true)
            .appendingPathComponent("PiSessions", isDirectory: true)
    }

    private static func normalizedMeetingAgentWorkspacePath(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return defaultMeetingAgentWorkspaceURL.path
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return defaultMeetingAgentWorkspaceURL.path
        }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    }

    private func meetingAudioDirectoryURL(meetingID: Meeting.ID) -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return applicationSupport
            .appendingPathComponent("会小纪", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true)
    }

    private func safeFilename(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "会议纪要" : cleaned
    }

    private func deleteMeetingAudioDirectory(for meeting: Meeting) -> Error? {
        let directoryURL = meetingAudioDirectoryURL(meetingID: meeting.id)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return nil
        }
        do {
            try FileManager.default.removeItem(at: directoryURL)
            return nil
        } catch {
            return error
        }
    }

    func finalizeStoppedMeeting(meetingID: Meeting.ID) {
        let unresolvedCount = unresolvedTranscriptionCounts[meetingID, default: 0]
        if unresolvedCount > 0 {
            postprocessingMeetingIDs.remove(meetingID)
            _ = setPostprocessRecoveryPending(false, meetingID: meetingID)
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .failed
            }
            if selectedMeetingID == meetingID {
                statusMessage = "录音已保存，但有 \(unresolvedCount) 个实时片段未完成转写；已保留待恢复数据，不会生成会议纪要。"
            }
            return
        }
        startPostprocessing(meetingID: meetingID)
    }

    func startPostprocessing(meetingID: Meeting.ID) {
        guard meetings.contains(where: { $0.id == meetingID }),
              postprocessingTasks[meetingID] == nil else {
            return
        }
        guard pendingPostprocessRecoveryMeetingIDs.contains(meetingID)
                || setPostprocessRecoveryPending(true, meetingID: meetingID) else {
            postprocessingMeetingIDs.remove(meetingID)
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .failed
            }
            if selectedMeetingID == meetingID {
                statusMessage = "会议纪要生成未启动：无法保存恢复状态。"
            }
            return
        }

        updateMeeting(id: meetingID) { meeting in
            meeting.status = .processing
        }
        postprocessingMeetingIDs.insert(meetingID)
        recentlyCompletedMeetingIDs.remove(meetingID)
        let queuedModelName = defaultModelSource(type: .agent).flatMap { $0.selectedModel ?? $0.name } ?? "未配置"
        appendDebugLog(
            category: "纪要",
            message: "自动纪要生成已加入队列：模型=\(queuedModelName)；等待转写完成后生成。",
            meetingID: meetingID
        )
        if selectedMeetingID == meetingID {
            let sourceMessage = meetings.first(where: { $0.id == meetingID })?.captureSource == .imported
                ? "转写记录已导入"
                : "录音已保存"
            statusMessage = "\(sourceMessage)，会议纪要已加入生成队列，将按顺序生成并更新标题。"
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let completed = await self.runPostprocess(meetingID: meetingID)
            self.finishPostprocessing(meetingID: meetingID, completed: completed)
        }
        postprocessingTasks[meetingID] = task
    }

    func waitForPostprocessing(meetingID: Meeting.ID) async {
        while postprocessingTasks[meetingID] != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func generateStandardMeetingMinutes(
        meeting: Meeting,
        segments: [TranscriptSegment],
        source: ModelSource,
        prompt: String,
        additionalPrompt: String = "",
        notes: [MeetingNoteContent] = []
    ) async throws -> MeetingMinutesArtifact {
        var lastErrorDescription = "未知错误"

        for attempt in 1...Self.standardMinutesGenerationAttempts {
            do {
                return try await meetingMinutesGenerator.generate(
                    meeting: meeting,
                    segments: segments,
                    source: source,
                    vocabulary: .empty,
                    prompt: prompt,
                    additionalPrompt: additionalPrompt,
                    notes: notes
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastErrorDescription = errorDescription(from: error)
                guard attempt < Self.standardMinutesGenerationAttempts else { break }
                appendDebugLog(
                    category: "纪要",
                    message: "标准纪要生成第 \(attempt) 次失败：失败原因=\(lastErrorDescription)；错误类型=\(errorTypeDescription(from: error))；将自动重试。",
                    meetingID: meeting.id
                )
                if selectedMeetingID == meeting.id {
                    statusMessage = "标准会议纪要第 \(attempt) 次生成失败，正在自动重试（\(attempt + 1)/\(Self.standardMinutesGenerationAttempts)）。"
                }
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }

        throw StandardMinutesGenerationFailure(
            attempts: Self.standardMinutesGenerationAttempts,
            reason: lastErrorDescription
        )
    }

    private func markStandardMinutesGenerationFailed(
        meetingID: Meeting.ID,
        error: Error,
        source: ModelSource? = nil,
        mode: String = "自动"
    ) {
        let reason = errorDescription(from: error)
        let modelName = source.flatMap { $0.selectedModel ?? $0.name } ?? "未知"
        updateMeeting(id: meetingID) {
            $0.status = .failed
            $0.minutesGenerationError = reason
        }
        _ = setPostprocessRecoveryPending(false, meetingID: meetingID)
        recentlyCompletedMeetingIDs.remove(meetingID)
        appendDebugLog(
            category: "纪要",
            message: "标准纪要生成失败：阶段=标准会议纪要；方式=\(mode)；模型=\(modelName)；失败原因=\(reason)；错误类型=\(errorTypeDescription(from: error))。",
            meetingID: meetingID
        )
        if selectedMeetingID == meetingID {
            refreshExportPreview()
            statusMessage = "标准会议纪要生成失败：\(reason) 可重新生成。"
        }
    }

    private func finishPostprocessing(meetingID: Meeting.ID, completed: Bool) {
        postprocessingTasks[meetingID] = nil
        postprocessingMeetingIDs.remove(meetingID)
        guard completed,
              meetings.contains(where: { $0.id == meetingID }) else {
            return
        }
        _ = setPostprocessRecoveryPending(false, meetingID: meetingID)
        recentlyCompletedMeetingIDs.insert(meetingID)
    }

    @discardableResult
    private func runPostprocess(meetingID: Meeting.ID) async -> Bool {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            return false
        }
        let segments = segmentsByMeeting[meetingID, default: []].sorted(by: { $0.startMs < $1.startMs })
        let notes: [MeetingNoteContent]
        do {
            notes = try loadMeetingNoteContents(meetingID: meetingID, includeOriginalData: true)
        } catch {
            let reason = errorDescription(from: error)
            updateMeeting(id: meetingID) {
                $0.status = .failed
                $0.minutesGenerationError = "读取会议笔记失败：\(reason)"
            }
            appendDebugLog(
                category: "纪要",
                message: "自动纪要生成失败：阶段=读取会议笔记；失败原因=\(reason)；错误类型=\(errorTypeDescription(from: error))。",
                meetingID: meetingID
            )
            return false
        }
        guard !segments.isEmpty else {
            updateMeeting(id: meetingID) { meeting in
                meeting.status = .done
                meeting.minutesGenerationError = nil
            }
            if selectedMeetingID == meetingID {
                statusMessage = "会议没有可用转写内容，未生成会议纪要。"
                refreshExportPreview()
            }
            return true
        }
        guard let source = defaultModelSource(type: .agent),
              source.baseURL.hasPrefix("mock://") || !source.baseURL.contains("example.com") else {
            let reason = "未配置可用 Agent 模型"
            appendDebugLog(
                category: "纪要",
                message: "自动纪要生成失败：阶段=模型配置；失败原因=\(reason)。",
                meetingID: meetingID
            )
            if meeting.captureSource == .imported {
                updateMeeting(id: meetingID) {
                    $0.status = .failed
                    $0.minutesGenerationError = "未配置可用 Agent 模型。"
                }
            } else {
                updateMeeting(id: meetingID) {
                    $0.status = .done
                    $0.minutesGenerationError = nil
                }
            }
            if selectedMeetingID == meetingID {
                statusMessage = meeting.captureSource == .imported
                    ? "标准会议纪要生成失败：未配置可用 Agent 模型。"
                    : "未配置可用 Agent 模型，已保留原始转写，可稍后手动生成原始会议纪要。"
                refreshExportPreview()
            }
            return meeting.captureSource != .imported
        }

        setMeetingNoteImageVisionStatus(notes, status: .processing)

        do {
            let artifact = try await generateStandardMeetingMinutes(
                meeting: meeting,
                segments: segments,
                source: source,
                prompt: meetingMinutesPrompt,
                notes: notes
            )
            guard !Task.isCancelled,
                  meetings.contains(where: { $0.id == meetingID }) else {
                return false
            }
            meetingMinutesArtifacts[meetingID] = artifact
            persistMeetingNoteVisionResults(artifact.noteVisionResults)
            updateMeeting(id: meetingID) {
                $0.status = .done
                $0.minutesGenerationError = nil
            }
            appendDebugLog(category: "纪要", message: "自动纪要生成完成。", meetingID: meetingID)
            var generatedTitle: String?
            var titleUpdateError: Error?
            do {
                generatedTitle = try persistGeneratedMeetingTitle(
                    meeting: meeting,
                    artifact: artifact
                )
            } catch {
                titleUpdateError = error
            }
            if selectedMeetingID == meetingID {
                refreshExportPreview()
                if let titleUpdateError {
                    statusMessage = "会议纪要已生成，但标题更新失败：\(titleUpdateError.localizedDescription)。"
                } else {
                    let titleMessage = generatedTitle.map { "，标题已更新为“\($0)”" } ?? ""
                    statusMessage = "会议纪要已生成\(titleMessage)，可导出 MD 或 HTML。"
                }
            }
        } catch is CancellationError {
            return false
        } catch {
            setMeetingNoteImageVisionStatus(notes, status: .failed, error: error.localizedDescription)
            markStandardMinutesGenerationFailed(meetingID: meetingID, error: error, source: source, mode: "自动")
            return false
        }
        return true
    }

    private func persistGeneratedMeetingTitle(
        meeting: Meeting,
        artifact: MeetingMinutesArtifact
    ) throws -> String? {
        guard MeetingTitleGeneration.shouldReplace(title: meeting.title),
              artifact.document.meetingName != meeting.title,
              let store,
              let persisted = try store.updateGeneratedMeetingTitle(
                  id: meeting.id,
                  expectedTitle: meeting.title,
                  title: artifact.document.meetingName
              ),
              let index = meetings.firstIndex(where: { $0.id == meeting.id }) else {
            return nil
        }
        meetings[index] = persisted
        refreshVisibleMeetings()
        return persisted.title
    }

    @discardableResult
    func addPerson() -> VoiceprintPerson.ID? {
        guard ensurePersistenceAvailable(action: "新增人员"), let store else {
            return nil
        }
        let defaultName = Self.uniqueDefaultName(
            prefix: "新同事",
            existing: people.map(\.displayName)
        )
        let person = VoiceprintPerson(
            id: UUID().uuidString,
            displayName: defaultName
        )
        do {
            try store.upsertPerson(person)
            people.insert(person, at: 0)
            libraryStatusMessage = "已新增人员。"
            return person.id
        } catch {
            libraryStatusMessage = "人员新增失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func savePerson(_ value: VoiceprintPerson) -> Bool {
        guard ensurePersistenceAvailable(action: "保存人员"), let store else {
            return false
        }
        var person = value
        person.displayName = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        person.jobTitle = person.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        person.responsibilities = person.responsibilities.trimmingCharacters(in: .whitespacesAndNewlines)
        person.zentaoAccount = person.zentaoAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        person.zentaoUserID = person.zentaoUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        person.aliases = Self.cleanedList(person.aliases, excluding: person.displayName)
            .filter { !LibraryPlaceholderPolicy.isGeneratedPersonName($0) }
        person.roleTags = Self.cleanedList(person.roleTags)
        guard !person.displayName.isEmpty else {
            libraryStatusMessage = "人员姓名不能为空。"
            return false
        }
        if let previous = people.first(where: { $0.id == person.id }),
           previous.displayName != person.displayName,
           !LibraryPlaceholderPolicy.isGeneratedPersonName(previous.displayName) {
            person.aliases = Self.cleanedList(person.aliases + [previous.displayName], excluding: person.displayName)
        }
        if let conflict = vocabularyConflict(
            canonicalName: person.displayName,
            aliases: person.aliases,
            excludingPersonID: person.id,
            excludingTerminologyID: nil,
            isActive: person.isActive
        ) {
            libraryStatusMessage = conflict
            return false
        }
        if person.isActive,
           !person.zentaoAccount.isEmpty,
           let duplicate = people.first(where: {
               $0.id != person.id && $0.isActive
                   && $0.zentaoAccount.caseInsensitiveCompare(person.zentaoAccount) == .orderedSame
           }) {
            libraryStatusMessage = "禅道账号已映射给“\(duplicate.displayName)”。"
            return false
        }
        do {
            try store.upsertPerson(person)
            if let index = people.firstIndex(where: { $0.id == person.id }) {
                people[index] = person
            } else {
                people.insert(person, at: 0)
            }
            if currentUserPersonID == person.id, !person.isActive {
                _ = setCurrentUserPerson(nil)
            }
            libraryStatusMessage = "人员“\(person.displayName)”已保存。"
            return true
        } catch {
            libraryStatusMessage = "人员保存失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setCurrentUserPerson(_ personID: VoiceprintPerson.ID?) -> Bool {
        guard ensurePersistenceAvailable(action: "设置当前用户"), let store else {
            return false
        }
        if let personID,
           !people.contains(where: { $0.id == personID && $0.isActive }) {
            libraryStatusMessage = "只能将启用中的人员设为当前用户。"
            return false
        }
        do {
            try store.setAppSetting(AppSettingKey.currentUserPersonID, value: personID ?? "")
            currentUserPersonID = personID
            if let personID, let person = people.first(where: { $0.id == personID }) {
                libraryStatusMessage = "已将“\(person.displayName)”设为当前用户。"
            } else {
                libraryStatusMessage = "已取消当前用户标记。"
            }
            return true
        } catch {
            libraryStatusMessage = "当前用户保存失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deletePerson(_ personID: VoiceprintPerson.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "删除人员"), let store else {
            return false
        }
        do {
            try store.deletePerson(id: personID)
            people.removeAll { $0.id == personID }
            voiceprintSamples.removeAll { $0.personID == personID }
            if currentUserPersonID == personID {
                currentUserPersonID = nil
                try? store.setAppSetting(AppSettingKey.currentUserPersonID, value: "")
            }
            libraryStatusMessage = "人员已删除。"
            return true
        } catch {
            libraryStatusMessage = "人员删除失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addTerminologyEntry() -> TerminologyEntry.ID? {
        guard ensurePersistenceAvailable(action: "新增常用词"), let store else {
            return nil
        }
        let defaultName = Self.uniqueDefaultName(
            prefix: "新专有名词",
            existing: terminologyEntries.map(\.canonicalName)
        )
        let entry = TerminologyEntry(
            id: UUID().uuidString,
            canonicalName: defaultName
        )
        do {
            try store.upsertTerminologyEntry(entry)
            terminologyEntries.append(entry)
            terminologyEntries.sort { $0.canonicalName.localizedStandardCompare($1.canonicalName) == .orderedAscending }
            libraryStatusMessage = "已新增常用词。"
            return entry.id
        } catch {
            libraryStatusMessage = "常用词新增失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func saveTerminologyEntry(_ value: TerminologyEntry) -> Bool {
        guard ensurePersistenceAvailable(action: "保存常用词"), let store else {
            return false
        }
        var entry = value
        entry.canonicalName = entry.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.category = entry.category.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.notes = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.aliases = Self.cleanedList(entry.aliases, excluding: entry.canonicalName)
            .filter { !LibraryPlaceholderPolicy.isGeneratedTerminologyName($0) }
        guard !entry.canonicalName.isEmpty else {
            libraryStatusMessage = "标准名称不能为空。"
            return false
        }
        if let previous = terminologyEntries.first(where: { $0.id == entry.id }),
           previous.canonicalName != entry.canonicalName,
           !LibraryPlaceholderPolicy.isGeneratedTerminologyName(previous.canonicalName) {
            entry.aliases = Self.cleanedList(entry.aliases + [previous.canonicalName], excluding: entry.canonicalName)
        }
        if let conflict = vocabularyConflict(
            canonicalName: entry.canonicalName,
            aliases: entry.aliases,
            excludingPersonID: nil,
            excludingTerminologyID: entry.id,
            isActive: entry.isActive
        ) {
            libraryStatusMessage = conflict
            return false
        }
        do {
            try store.upsertTerminologyEntry(entry)
            if let index = terminologyEntries.firstIndex(where: { $0.id == entry.id }) {
                terminologyEntries[index] = entry
            } else {
                terminologyEntries.append(entry)
            }
            terminologyEntries.sort { $0.canonicalName.localizedStandardCompare($1.canonicalName) == .orderedAscending }
            libraryStatusMessage = "常用词“\(entry.canonicalName)”已保存。"
            return true
        } catch {
            libraryStatusMessage = "常用词保存失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteTerminologyEntry(_ entryID: TerminologyEntry.ID) -> Bool {
        guard ensurePersistenceAvailable(action: "删除常用词"), let store else {
            return false
        }
        do {
            try store.deleteTerminologyEntry(id: entryID)
            terminologyEntries.removeAll { $0.id == entryID }
            libraryStatusMessage = "常用词已删除。"
            return true
        } catch {
            libraryStatusMessage = "常用词删除失败：\(error.localizedDescription)"
            return false
        }
    }

    private var meetingMinutesVocabulary: MeetingMinutesVocabulary {
        MeetingMinutesVocabulary(
            terminologyEntries: terminologyEntries,
            people: people
        )
    }

    private func vocabularyConflict(
        canonicalName: String,
        aliases: [String],
        excludingPersonID: VoiceprintPerson.ID?,
        excludingTerminologyID: TerminologyEntry.ID?,
        isActive: Bool
    ) -> String? {
        guard isActive else { return nil }
        let candidateTokens = Set(
            Self.cleanedList([canonicalName] + aliases).map { $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "zh_CN")
            ) }
        )
        for person in people where person.isActive && person.id != excludingPersonID {
            let existing = Set(Self.cleanedList([person.displayName] + person.aliases).map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            })
            if let duplicate = candidateTokens.intersection(existing).first {
                return "称呼“\(duplicate)”已属于人员“\(person.displayName)”。"
            }
        }
        for entry in terminologyEntries where entry.isActive && entry.id != excludingTerminologyID {
            let existing = Set(Self.cleanedList([entry.canonicalName] + entry.aliases).map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            })
            if let duplicate = candidateTokens.intersection(existing).first {
                return "称呼“\(duplicate)”已属于常用词“\(entry.canonicalName)”。"
            }
        }
        return nil
    }

    private static func cleanedList(_ values: [String], excluding excluded: String? = nil) -> [String] {
        let normalizedExcluded = excluded?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.caseInsensitiveCompare(normalizedExcluded ?? "") != .orderedSame else {
                return nil
            }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private static func uniqueDefaultName(prefix: String, existing: [String]) -> String {
        let names = Set(existing)
        var index = 1
        while names.contains("\(prefix) \(index)") {
            index += 1
        }
        return "\(prefix) \(index)"
    }

    private func removeGeneratedPlaceholderAliasesIfNeeded() {
        guard let store else { return }
        var removedCount = 0
        do {
            for index in people.indices {
                let aliases = people[index].aliases.filter {
                    !LibraryPlaceholderPolicy.isGeneratedPersonName($0)
                }
                guard aliases != people[index].aliases else { continue }
                removedCount += people[index].aliases.count - aliases.count
                people[index].aliases = aliases
                try store.upsertPerson(people[index])
            }
            for index in terminologyEntries.indices {
                let aliases = terminologyEntries[index].aliases.filter {
                    !LibraryPlaceholderPolicy.isGeneratedTerminologyName($0)
                }
                guard aliases != terminologyEntries[index].aliases else { continue }
                removedCount += terminologyEntries[index].aliases.count - aliases.count
                terminologyEntries[index].aliases = aliases
                try store.upsertTerminologyEntry(terminologyEntries[index])
            }
            if removedCount > 0 {
                libraryStatusMessage = "已清理 \(removedCount) 个系统占位称呼。"
            }
        } catch {
            libraryStatusMessage = "系统占位称呼清理失败：\(error.localizedDescription)"
        }
    }

    private func findOrCreatePerson(named displayName: String) -> VoiceprintPerson {
        if let existingPerson = people.first(where: { $0.displayName == displayName }) {
            return existingPerson
        }
        let person = VoiceprintPerson(id: UUID().uuidString, displayName: displayName)
        people.insert(person, at: 0)
        persistPerson(person)
        return person
    }

    private func updateSelectedMeeting(_ update: (inout Meeting) -> Void) {
        guard let selectedMeetingID else {
            return
        }
        updateMeeting(id: selectedMeetingID, update: update)
    }

    private func updateMeeting(id: Meeting.ID, update: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }
        let previous = meetings[index]
        var candidate = previous
        update(&candidate)
        guard candidate != previous else {
            return
        }
        guard let store else {
            statusMessage = "本地数据库不可用，会议修改未保存。"
            return
        }
        do {
            candidate.handoffStatus = .ignored
            candidate.handoffStartedAt = nil
            candidate.handoffCompletedAt = nil
            candidate.handoffContentHash = nil
            candidate.handoffError = nil
            try store.upsertMeeting(candidate)
            meetings[index] = candidate
            if previous.status != candidate.status
                || previous.isArchived != candidate.isArchived
                || previous.minutesGenerationError != candidate.minutesGenerationError {
                appendDebugLog(
                    category: "状态",
                    message: "会议状态：\(previous.status.rawValue)/归档=\(previous.isArchived) -> \(candidate.status.rawValue)/归档=\(candidate.isArchived)。",
                    meetingID: id
                )
            }
            refreshVisibleMeetings()
        } catch {
            statusMessage = "会议保存失败：\(error.localizedDescription)"
        }
    }

    private func updateSegment(segmentID: TranscriptSegment.ID, update: (inout TranscriptSegment) -> Void) {
        guard let selectedMeetingID,
              var segments = segmentsByMeeting[selectedMeetingID],
              let index = segments.firstIndex(where: { $0.id == segmentID }) else {
            return
        }
        let previous = segments[index]
        var candidate = previous
        update(&candidate)
        guard candidate != previous else {
            return
        }
        do {
            try persistSegmentOrThrow(candidate)
            segments[index] = candidate
            segmentsByMeeting[selectedMeetingID] = segments
        } catch {
            statusMessage = "片段保存失败：\(error.localizedDescription)"
        }
    }

    private func replaceSegment(_ segment: TranscriptSegment, refreshPreview: Bool = true) {
        guard var segments = segmentsByMeeting[segment.meetingID],
              let index = segments.firstIndex(where: { $0.id == segment.id }) else {
            return
        }
        segments[index] = segment
        segmentsByMeeting[segment.meetingID] = segments
        persistSegment(segment)
        if refreshPreview {
            refreshExportPreview()
        }
    }

    private func replaceSegments(_ replacementSegments: [TranscriptSegment], originalSegmentIDs: Set<TranscriptSegment.ID>) -> Bool {
        guard let meetingID = replacementSegments.first?.meetingID,
              var segments = segmentsByMeeting[meetingID] else {
            return false
        }
        let originalSegments = segments.filter { originalSegmentIDs.contains($0.id) }
        let decision = TranscriptSegmentReplacementPolicy.validate(
            replacementSegments: replacementSegments,
            originalSegments: originalSegments
        )
        guard decision.isAccepted else {
            statusMessage = "自动校正结果未替换原记录：\(decision.reason ?? "结果不完整，已保留原记录。")"
            refreshExportPreview()
            return false
        }
        segments.removeAll { originalSegmentIDs.contains($0.id) }
        segments.append(contentsOf: replacementSegments)
        segments.sort { $0.startMs < $1.startMs }
        segmentsByMeeting[meetingID] = segments
        for id in originalSegmentIDs where !replacementSegments.contains(where: { $0.id == id }) {
            do {
                try store?.deleteSegment(id: id)
            } catch {
                statusMessage = "旧片段删除失败：\(error.localizedDescription)"
            }
        }
        for segment in replacementSegments {
            persistSegment(segment)
        }
        refreshExportPreview()
        return true
    }

    private func persistDefaults(_ snapshot: AppPersistenceSnapshot) throws {
        for meeting in snapshot.meetings {
            try store?.upsertMeeting(meeting)
        }
        for segments in snapshot.segmentsByMeeting.values {
            for segment in segments {
                try store?.upsertSegment(segment)
            }
        }
        for person in snapshot.people {
            try store?.upsertPerson(person)
        }
        for entry in snapshot.terminologyEntries {
            try store?.upsertTerminologyEntry(entry)
        }
        for sample in snapshot.voiceprintSamples {
            try store?.upsertVoiceprintSample(sample)
        }
        for runs in snapshot.diarizationRunsByMeeting.values {
            for run in runs {
                try store?.upsertDiarizationRun(run)
            }
        }
        for mappings in snapshot.diarizationMappingsByMeeting.values {
            for mapping in mappings {
                try store?.upsertDiarizationSpeakerMapping(mapping)
            }
        }
        for source in snapshot.modelSources {
            try store?.upsertModelSource(source)
        }
        for (key, value) in snapshot.appSettings {
            try store?.setAppSetting(key, value: value)
        }
    }

    private func persistMeeting(_ meeting: Meeting) {
        do {
            try store?.upsertMeeting(meeting)
        } catch {
            statusMessage = "会议保存失败：\(error.localizedDescription)"
        }
    }

    private func recoverInterruptedMeetingsIfNeeded() {
        guard store != nil else {
            return
        }

        for index in meetings.indices {
            let meeting = meetings[index]
            guard meeting.endedAt == nil,
                  meeting.status == .recording || meeting.status == .paused,
                  let startedAt = meeting.startedAt else {
                continue
            }

            let audioDurationMs = [
                meeting.audioFilePath,
                meeting.microphoneAudioFilePath,
                meeting.computerAudioFilePath
            ]
            .compactMap { path -> Int? in
                guard let path,
                      FileManager.default.fileExists(atPath: path) else {
                    return nil
                }
                return try? WAVAudioSegmentReader.durationMs(from: URL(fileURLWithPath: path))
            }
            .max() ?? 0

            let duration = audioDurationMs > 0
                ? TimeInterval(audioDurationMs) / 1_000
                : MeetingRecordingTimeline.fallbackDuration
            let recovered = MeetingRecordingTimeline.recovered(
                meeting,
                endingAt: startedAt.addingTimeInterval(duration)
            )
            guard recovered != meeting else {
                continue
            }
            meetings[index] = recovered
            persistMeeting(recovered)
        }
    }

    private func refreshVisibleMeetings() {
        visibleMeetings = Self.visibleMeetings(
            from: meetings,
            limit: visibleMeetingLimit
        )
        let resolvedSelection = MeetingCollectionPolicy.resolvedSelection(
            currentID: selectedMeetingID,
            allMeetingIDs: Set(meetings.map(\.id))
        )
        guard resolvedSelection != selectedMeetingID else {
            return
        }
        selectedMeetingID = resolvedSelection
        if selectedMeetingID == nil {
            refreshExportPreview()
        }
    }

    private func contentLockMessage(for meetingID: Meeting.ID) -> String {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            return "会议不存在。"
        }
        if meeting.isArchived {
            return "会议已归档，请先恢复后再编辑。"
        }
        if isMeetingMinutesActive(meetingID) {
            return "会议纪要正在排队或生成，请等待完成后再编辑。"
        }
        if activeRecordingMeetingID == meetingID {
            return "会议正在录音，请先停止录音。"
        }
        return "当前会议暂不可编辑。"
    }

    private static func visibleMeetings(from meetings: [Meeting], limit: Int) -> [Meeting] {
        MeetingCollectionPolicy.sidebarMeetings(from: meetings, limit: limit)
    }

    private func persistSegment(_ segment: TranscriptSegment) {
        do {
            try persistSegmentOrThrow(segment)
        } catch {
            statusMessage = "片段保存失败：\(error.localizedDescription)"
        }
    }

    private func persistSegmentOrThrow(_ segment: TranscriptSegment) throws {
        guard let store else {
            throw AppStatePersistenceError.unavailable
        }
        try store.upsertSegment(segment)
    }

    private func persistPerson(_ person: VoiceprintPerson) {
        do {
            try store?.upsertPerson(person)
        } catch {
            statusMessage = "声纹人员保存失败：\(error.localizedDescription)"
        }
    }

    private func persistVoiceprintSample(_ sample: VoiceprintSample) {
        do {
            try store?.upsertVoiceprintSample(sample)
        } catch {
            statusMessage = "声纹样本保存失败：\(error.localizedDescription)"
        }
    }

    private func enrollVoiceprintSampleIfPossible(person: VoiceprintPerson, segment: TranscriptSegment) {
        enrollVoiceprintSamplesIfPossible(person: person, segments: [segment])
    }

    private func enrollVoiceprintSamplesIfPossible(person: VoiceprintPerson, segments: [TranscriptSegment]) {
        guard !segments.isEmpty else {
            return
        }
        guard let meeting = meetings.first(where: { $0.id == segments[0].meetingID }) else {
            return
        }
        let requests = segments.compactMap { segment -> (TranscriptSegment, String)? in
            guard let path = voiceprintAudioPath(for: segment, meeting: meeting) else {
                return nil
            }
            return (segment, path)
        }
        guard !requests.isEmpty else {
            statusMessage = "人工修正已保存，但没有找到对应录音，暂时无法加入声纹库。"
            return
        }

        statusMessage = "正在把人工确认的 \(requests.count) 段声音加入声纹库。"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let source = self.defaultModelSource(type: .voiceprint),
                      source.baseURL == "sidecar://diarization" else {
                    self.statusMessage = "人工修正已保存，但声纹模型未启用，暂时无法加入声纹库。"
                    return
                }
                let token = DiarizationTokenResolver.resolve(
                    source: source,
                    environment: ProcessInfo.processInfo.environment
                )
                let transport = try self.makeFinalDiarizationTransport(huggingFaceToken: token)
                defer { Task { await transport.shutdown() } }
                let client = DiarizationSidecarClient(transport: transport)
                _ = try await client.preload(huggingFaceToken: token)

                var enrolledCount = 0
                var failures: [String] = []
                for (segment, path) in requests {
                    do {
                        let result = try await client.embedSpeaker(
                            path: path,
                            startMs: segment.startMs,
                            endMs: segment.endMs
                        )
                        let sample = try VoiceprintEnrollment.makeSample(
                            person: person,
                            segment: segment,
                            embedding: result.embedding,
                            confidence: result.confidence,
                            manualEnrollment: true
                        )
                        self.upsertVoiceprintSample(sample)
                        enrolledCount += 1
                    } catch {
                        failures.append("\(segment.id)：\(self.errorDescription(from: error))")
                    }
                }

                if failures.isEmpty {
                    self.statusMessage = "人工修正已保存，已将 \(enrolledCount) 段声音加入声纹库。"
                } else {
                    self.statusMessage = "人工修正已保存，已将 \(enrolledCount)/\(requests.count) 段声音加入声纹库；其余片段入库失败：\(failures.joined(separator: "；"))"
                }
            } catch {
                self.statusMessage = "人工修正已保存，但声纹样本入库失败：\(self.errorDescription(from: error))"
            }
        }
    }

    private func voiceprintAudioPath(for segment: TranscriptSegment, meeting: Meeting) -> String? {
        let preferredPaths: [String?]
        switch segment.sourceTrack {
        case .microphone:
            preferredPaths = [meeting.microphoneAudioFilePath, meeting.audioFilePath, meeting.computerAudioFilePath]
        case .computer:
            preferredPaths = [meeting.computerAudioFilePath, meeting.audioFilePath, meeting.microphoneAudioFilePath]
        case .mixed:
            preferredPaths = [meeting.audioFilePath, meeting.microphoneAudioFilePath, meeting.computerAudioFilePath]
        case nil:
            preferredPaths = [meeting.audioFilePath, meeting.microphoneAudioFilePath, meeting.computerAudioFilePath]
        }
        return preferredPaths
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func upsertVoiceprintSample(_ sample: VoiceprintSample) {
        if let index = voiceprintSamples.firstIndex(where: { $0.id == sample.id }) {
            voiceprintSamples[index] = sample
        } else {
            voiceprintSamples.append(sample)
        }
        persistVoiceprintSample(sample)
    }

    private func replaceTranscriptSegments(meetingID: Meeting.ID, with replacement: [TranscriptSegment]) {
        let previous = segmentsByMeeting[meetingID, default: []]
        let replacementIDs = Set(replacement.map(\.id))
        for segment in previous where !replacementIDs.contains(segment.id) {
            do {
                try store?.deleteSegment(id: segment.id)
            } catch {
                statusMessage = "旧转写片段清理失败：\(error.localizedDescription)"
            }
        }
        let sorted = replacement.sorted { left, right in
            if left.startMs == right.startMs { return left.endMs < right.endMs }
            return left.startMs < right.startMs
        }
        segmentsByMeeting[meetingID] = sorted
        for segment in sorted {
            persistSegment(segment)
        }
    }

    private func replaceDiarizationSpeakerMappings(
        meetingID: Meeting.ID,
        with mappings: [DiarizationSpeakerMapping]
    ) {
        diarizationMappingsByMeeting[meetingID] = mappings
        do {
            try store?.deleteDiarizationSpeakerMappings(meetingID: meetingID)
            for mapping in mappings {
                try store?.upsertDiarizationSpeakerMapping(mapping)
            }
        } catch {
            statusMessage = "说话人映射保存失败：\(error.localizedDescription)"
        }
    }

    private func upsertDiarizationRun(_ run: DiarizationRun) {
        var runs = diarizationRunsByMeeting[run.meetingID, default: []]
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        diarizationRunsByMeeting[run.meetingID] = runs
        do {
            try store?.upsertDiarizationRun(run)
        } catch {
            statusMessage = "说话人分离结果保存失败：\(error.localizedDescription)"
        }
    }

    private func upsertDiarizationSpeakerMapping(_ mapping: DiarizationSpeakerMapping) {
        var mappings = diarizationMappingsByMeeting[mapping.meetingID, default: []]
        if let index = mappings.firstIndex(where: { $0.speakerKey == mapping.speakerKey }) {
            mappings[index] = mapping
        } else {
            mappings.append(mapping)
        }
        diarizationMappingsByMeeting[mapping.meetingID] = mappings
        do {
            try store?.upsertDiarizationSpeakerMapping(mapping)
        } catch {
            statusMessage = "说话人映射保存失败：\(error.localizedDescription)"
        }
    }

    private func resetDiarizationSpeakerMappings(meetingID: Meeting.ID) {
        diarizationMappingsByMeeting[meetingID] = []
        do {
            try store?.deleteDiarizationSpeakerMappings(meetingID: meetingID)
        } catch {
            statusMessage = "旧说话人映射清理失败：\(error.localizedDescription)"
        }
    }

    private func persistModelSource(_ source: ModelSource) {
        do {
            try store?.upsertModelSource(source)
        } catch {
            statusMessage = "模型配置保存失败：\(error.localizedDescription)"
        }
    }

    private func persistAppSetting(_ key: String, value: String) {
        do {
            try store?.setAppSetting(key, value: value)
        } catch {
            statusMessage = "设置保存失败：\(error.localizedDescription)"
        }
    }

    private func persistKnowledgeBaseConfiguration() {
        do {
            let data = try JSONEncoder().encode(knowledgeBaseConfiguration)
            persistAppSetting(
                AppSettingKey.difyKnowledgeBaseConfiguration,
                value: String(decoding: data, as: UTF8.self)
            )
        } catch {
            libraryStatusMessage = "知识库配置保存失败：\(error.localizedDescription)"
        }
    }

    private static func decodeKnowledgeBaseConfiguration(_ rawValue: String?) -> DifyKnowledgeBaseConfiguration {
        guard let rawValue, !rawValue.isEmpty,
              let configuration = try? JSONDecoder().decode(
                DifyKnowledgeBaseConfiguration.self,
                from: Data(rawValue.utf8)
              )
        else {
            return DifyKnowledgeBaseConfiguration(baseURL: "http://127.0.0.1:15080/v1")
        }
        return configuration
    }

    @discardableResult
    private func setPostprocessRecoveryPending(_ pending: Bool, meetingID: Meeting.ID) -> Bool {
        let previous = pendingPostprocessRecoveryMeetingIDs
        if pending {
            pendingPostprocessRecoveryMeetingIDs.insert(meetingID)
        } else {
            pendingPostprocessRecoveryMeetingIDs.remove(meetingID)
        }
        do {
            guard let store else {
                throw AppStatePersistenceError.unavailable
            }
            let value = String(
                decoding: try JSONEncoder().encode(pendingPostprocessRecoveryMeetingIDs.sorted()),
                as: UTF8.self
            )
            try store.setAppSetting(AppSettingKey.pendingPostprocessMeetingIDs, value: value)
            return true
        } catch {
            pendingPostprocessRecoveryMeetingIDs = previous
            statusMessage = "会议纪要恢复状态保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func pruneStalePostprocessRecoveryMarkers() {
        let recoverableMeetingIDs = Set(
            meetings.lazy
                .filter { $0.status == .processing && $0.endedAt != nil }
                .map(\.id)
        )
        let retainedMeetingIDs = pendingPostprocessRecoveryMeetingIDs.intersection(recoverableMeetingIDs)
        guard retainedMeetingIDs != pendingPostprocessRecoveryMeetingIDs else {
            return
        }
        let previousMeetingIDs = pendingPostprocessRecoveryMeetingIDs
        do {
            guard let store else {
                throw AppStatePersistenceError.unavailable
            }
            let value = String(
                decoding: try JSONEncoder().encode(retainedMeetingIDs.sorted()),
                as: UTF8.self
            )
            try store.setAppSetting(AppSettingKey.pendingPostprocessMeetingIDs, value: value)
            pendingPostprocessRecoveryMeetingIDs = retainedMeetingIDs
        } catch {
            pendingPostprocessRecoveryMeetingIDs = previousMeetingIDs
            statusMessage = "过期会议纪要恢复状态清理失败：\(error.localizedDescription)"
        }
    }

    private static func decodePostprocessRecoveryMeetingIDs(_ value: String?) -> Set<Meeting.ID> {
        guard let value,
              let data = value.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Meeting.ID].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func migrateExampleASRToLocalDefaultIfNeeded() {
        guard let index = modelSources.firstIndex(where: { $0.type == .asr && $0.isDefault }),
              modelSources[index].baseURL.contains("example.com") else {
            return
        }
        modelSources[index].name = "本地 OMLX 转写服务"
        modelSources[index].baseURL = "http://127.0.0.1:18001/v1"
        modelSources[index].apiKey = "1234"
        modelSources[index].selectedModel = "Qwen3-ASR-1.7B-8bit"
        modelSources[index].availableModels = ["Qwen3-ASR-1.7B-8bit"]
        persistModelSource(modelSources[index])
        statusMessage = "已把默认 ASR 切换为本地 OMLX 转写服务。"
    }

    private func seedMeetingMinutesModelIfNeeded(_ shouldSeed: Bool) {
        guard shouldSeed else { return }
        if modelSources.contains(where: { $0.type == .meetingMinutes }) {
            persistAppSetting(AppSettingKey.meetingMinutesModelSeeded, value: "true")
            return
        }
        guard let template = modelSources.first(where: {
            $0.type == .postprocess
                && !$0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.selectedModel?.isEmpty == false
        }) else {
            return
        }

        let source = ModelSource(
            id: "meeting-minutes-default",
            type: .meetingMinutes,
            name: "会议纪要模型",
            baseURL: template.baseURL,
            apiKey: template.apiKey,
            selectedModel: template.selectedModel,
            availableModels: template.availableModels,
            isDefault: true,
            enabled: true,
            lastTestOK: template.lastTestOK,
            lastTestMessage: template.lastTestMessage,
            lastTestAt: template.lastTestAt
        )
        do {
            guard let store else { throw AppStatePersistenceError.unavailable }
            try store.upsertModelSource(source)
            try store.setAppSetting(AppSettingKey.meetingMinutesModelSeeded, value: "true")
            modelSources.append(source)
            statusMessage = "已根据现有文本模型创建独立会议纪要模型配置。"
        } catch {
            statusMessage = "会议纪要模型初始化失败：\(error.localizedDescription)"
        }
    }

    private func applyExclusiveASRSelection(source: ModelSource) {
        for index in modelSources.indices where modelSources[index].type == .asr {
            if modelSources[index].id == source.id {
                modelSources[index] = source
                modelSources[index].enabled = true
                modelSources[index].isDefault = true
            } else {
                modelSources[index].enabled = false
                modelSources[index].isDefault = false
            }
            persistModelSource(modelSources[index])
        }
    }

    private func enforceSingleEnabledASRSourceIfNeeded() {
        let asrSources = modelSources.filter { $0.type == .asr }
        guard !asrSources.isEmpty else {
            return
        }
        let selectedID = asrSources.first(where: { $0.isDefault && $0.enabled })?.id
            ?? asrSources.first(where: \.isDefault)?.id
            ?? asrSources.first(where: \.enabled)?.id
        guard let selectedID else {
            return
        }

        var changed = false
        for index in modelSources.indices where modelSources[index].type == .asr {
            let shouldSelect = modelSources[index].id == selectedID
            if modelSources[index].enabled != shouldSelect || modelSources[index].isDefault != shouldSelect {
                modelSources[index].enabled = shouldSelect
                modelSources[index].isDefault = shouldSelect
                persistModelSource(modelSources[index])
                changed = true
            }
        }
        if changed {
            statusMessage = "已修正转写模型配置：仅启用当前默认服务。"
        }
    }

    private func restoreVoiceprintModelSourcesIfNeeded() {
        let restored = VoiceprintModelMigration.restoreBundledSidecar(modelSources)
        guard restored != modelSources else { return }
        modelSources = restored
        for source in restored where source.type == .voiceprint {
            persistModelSource(source)
        }
        statusMessage = "已恢复会小纪内置说话人分离与声纹模型配置。"
    }

    private func disableExamplePostprocessSourceIfNeeded() {
        let exampleIDs = modelSources
            .filter { source in
                source.type == .postprocess
                    && (source.baseURL.contains("llm.example.com") || source.selectedModel == "meeting-polish-v1")
            }
            .map(\.id)
        guard !exampleIDs.isEmpty else {
            return
        }
        modelSources.removeAll { exampleIDs.contains($0.id) }
        for id in exampleIDs {
            do {
                try store?.deleteModelSource(id: id)
            } catch {
                statusMessage = "示例后处理服务清理失败：\(error.localizedDescription)"
                return
            }
        }
        statusMessage = "已移除示例后处理服务，请新增并配置真实 OpenAI 兼容服务后再启用。"
    }

    private func raiseUnsafeVoiceprintThresholdsIfNeeded() {
        var changed = false
        for index in people.indices where people[index].threshold < VoiceprintMatchingPolicy.minimumPersonThreshold {
            people[index].threshold = VoiceprintMatchingPolicy.minimumPersonThreshold
            persistPerson(people[index])
            changed = true
        }
        if changed {
        }
    }

    private static func defaultSnapshot() -> AppPersistenceSnapshot {
        AppPersistenceSnapshot(
            meetings: [],
            segmentsByMeeting: [:],
            people: [],
            terminologyEntries: [],
            voiceprintSamples: [],
            modelSources: [],
            appSettings: [
                AppSettingKey.postprocessPrompt: PostprocessPrompt.defaultMouthFillerCleanup,
                AppSettingKey.meetingMinutesPrompt: PostprocessPrompt.meetingMinutes,
                AppSettingKey.meetingMinutesPromptVersion: PostprocessPrompt.meetingMinutesPromptVersion,
                AppSettingKey.meetingAnalysisPrompt: PostprocessPrompt.meetingAnalysis,
                AppSettingKey.diarizationSpeakerPreset: DiarizationSpeakerPreset.automatic.rawValue,
                AppSettingKey.pendingPostprocessMeetingIDs: "[]",
                AppSettingKey.meetingMinutesModelSeeded: "false",
                AppSettingKey.difyKnowledgeBaseConfiguration: "",
                AppSettingKey.currentUserPersonID: "",
                AppSettingKey.meetingAgentWorkspacePath: ""
            ]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

private enum RecordingWriterError: LocalizedError {
    case missingMeeting

    var errorDescription: String? {
        "找不到当前录音会议。"
    }
}

private extension AudioCaptureError {
    var displayMessage: String {
        switch self {
        case .permissionDenied(let message),
             .unsupported(let message),
             .startFailed(let message):
            return message
        case .stopped:
            return "采集已停止"
        }
    }
}

extension CaptureSource {
    static let recordingPickerSources: [CaptureSource] = [.microphone, .screenAudio, .mixed]

    var displayName: String {
        switch self {
        case .microphone:
            return "麦克风"
        case .screenAudio:
            return "电脑音频"
        case .appAudio, .systemAudio:
            return "电脑音频（兼容旧记录）"
        case .mixed:
            return "麦克风 + 电脑音频"
        case .imported:
            return "外部导入"
        }
    }
}

extension MeetingStatus {
    var displayName: String {
        switch self {
        case .draft:
            return "未开始"
        case .permissionChecking:
            return "权限检查中"
        case .recording:
            return "录音中"
        case .paused:
            return "已暂停"
        case .processing:
            return "处理中"
        case .done:
            return "已完成"
        case .failed:
            return "失败"
        }
    }
}

extension ModelSourceType {
    var displayName: String {
        switch self {
        case .asr:
            return "转写"
        case .voiceprint:
            return "声纹"
        case .postprocess:
            return "后处理"
        case .meetingMinutes:
            return "会议纪要"
        case .agent:
            return "Agent"
        }
    }
}

enum MeetingMinutesExportFormat {
    case markdown
    case html

    var displayName: String {
        switch self {
        case .markdown: "MD"
        case .html: "HTML"
        }
    }

    var pathExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .html: .html
        }
    }

    func content(from artifact: MeetingMinutesArtifact) -> String {
        switch self {
        case .markdown: artifact.markdown
        case .html: artifact.html
        }
    }

    func content(from artifact: MeetingAnalysisArtifact) -> String {
        switch self {
        case .markdown: artifact.markdown
        case .html: artifact.html
        }
    }
}

private struct LiveSpeakerResolution {
    var label: String
    var autoLabel: String
    var personID: String?
    var personName: String?
    var confidence: Double
    var embedding: [Double]?
}
