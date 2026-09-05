import AItingjiCore
import Foundation

struct AppDebugLogEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: Date
    var category: String
    var message: String
    var meetingID: Meeting.ID?

    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        category: String,
        message: String,
        meetingID: Meeting.ID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.meetingID = meetingID
    }
}

struct MeetingDebugState: Identifiable, Equatable, Sendable {
    var id: Meeting.ID
    var title: String
    var memoryStatus: MeetingStatus
    var persistedStatus: MeetingStatus?
    var memoryArchived: Bool
    var persistedArchived: Bool?
    var automaticMinutesActive: Bool
    var manualMinutesActive: Bool
    var recoveryPending: Bool
    var analysisActive: Bool
    var hasMinutesArtifact: Bool
    var minutesGenerationError: String?

    var hasPersistenceMismatch: Bool {
        guard let persistedStatus, let persistedArchived else { return false }
        return memoryStatus != persistedStatus || memoryArchived != persistedArchived
    }

    var runtimeSummary: String {
        var values: [String] = []
        if automaticMinutesActive { values.append("自动纪要") }
        if manualMinutesActive { values.append("手动纪要") }
        if recoveryPending { values.append("恢复标记") }
        if analysisActive { values.append("AI 分析") }
        return values.isEmpty ? "无运行任务" : values.joined(separator: "、")
    }
}

struct AppDebugLogStore: Sendable {
    private let fileURL: URL
    private let maximumEntries: Int

    init(
        fileURL: URL = Self.defaultFileURL(),
        maximumEntries: Int = 500
    ) {
        self.fileURL = fileURL
        self.maximumEntries = max(1, maximumEntries)
    }

    func load() -> [AppDebugLogEntry] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(AppDebugLogEntry.self, from: Data($0.utf8)) }
            .suffix(maximumEntries)
            .reversed()
    }

    func append(_ entry: AppDebugLogEntry) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var data = try encoder.encode(entry)
        data.append(0x0A)

        if !manager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }

        let entries = load().reversed()
        guard entries.count >= maximumEntries else { return }
        let compacted = try entries.map(encoder.encode).reduce(into: Data()) { result, item in
            result.append(item)
            result.append(0x0A)
        }
        try compacted.write(to: fileURL, options: .atomic)
    }

    static func defaultFileURL() -> URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ai-tingji-debug-events-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        }
        return ApplicationDataDirectory.rootURL
            .appendingPathComponent("DebugLogs", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private static var isRunningTests: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains { $0.contains(".xctest") }
    }
}
