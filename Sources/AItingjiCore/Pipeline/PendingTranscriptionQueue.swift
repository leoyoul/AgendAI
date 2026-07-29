import Foundation

public struct PendingTranscriptionRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let meetingID: Meeting.ID
    public let sequence: Int
    public let startMs: Int
    public let endMs: Int
    public let attemptCount: Int
    public let audioFileURL: URL
}

public struct PendingTranscriptionItem: Equatable, Sendable {
    public let record: PendingTranscriptionRecord
    public let chunk: AudioChunk
}

public enum PendingTranscriptionFailureDisposition: Equatable, Sendable {
    case retryable(attemptCount: Int)
    case exhausted(attemptCount: Int)
}

public enum PendingTranscriptionQueueError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unknownItem(String)
    case missingAudioFile(String)
}

public actor PendingTranscriptionQueue {
    public static let defaultMaximumInMemoryChunks = 6
    public static let defaultMaximumAttempts = 3

    private struct Metadata: Codable, Equatable, Sendable {
        var id: String
        var meetingID: Meeting.ID
        var sequence: Int
        var startMs: Int
        var endMs: Int
        var attemptCount: Int
    }

    private struct StoredRecord: Sendable {
        var metadata: Metadata
        var audioFileURL: URL

        var publicRecord: PendingTranscriptionRecord {
            PendingTranscriptionRecord(
                id: metadata.id,
                meetingID: metadata.meetingID,
                sequence: metadata.sequence,
                startMs: metadata.startMs,
                endMs: metadata.endMs,
                attemptCount: metadata.attemptCount,
                audioFileURL: audioFileURL
            )
        }
    }

    private let rootDirectoryURL: URL
    private let maximumInMemoryChunks: Int
    private let maximumAttempts: Int
    private var recordsByID: [String: StoredRecord]
    private var cachedChunksByID: [String: AudioChunk] = [:]
    private var inFlightIDs: Set<String> = []

    public init(
        rootDirectoryURL: URL,
        maximumInMemoryChunks: Int = defaultMaximumInMemoryChunks,
        maximumAttempts: Int = defaultMaximumAttempts
    ) throws {
        guard maximumInMemoryChunks >= 0, maximumAttempts > 0 else {
            throw PendingTranscriptionQueueError.invalidConfiguration
        }
        self.rootDirectoryURL = rootDirectoryURL
        self.maximumInMemoryChunks = maximumInMemoryChunks
        self.maximumAttempts = maximumAttempts
        try FileManager.default.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        recordsByID = try Self.loadRecords(from: rootDirectoryURL)
    }

    @discardableResult
    public func enqueue(meetingID: Meeting.ID, chunk: AudioChunk) throws -> PendingTranscriptionRecord {
        let id = UUID().uuidString.lowercased()
        let meetingDirectoryURL = rootDirectoryURL.appendingPathComponent(
            Self.meetingDirectoryName(meetingID),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: meetingDirectoryURL, withIntermediateDirectories: true)
        let baseName = Self.audioBaseName(
            id: id,
            sequence: chunk.sequence,
            startMs: chunk.startMs,
            endMs: chunk.endMs
        )
        let audioFileURL = meetingDirectoryURL
            .appendingPathComponent(baseName)
            .appendingPathExtension("wav")
        let metadata = Metadata(
            id: id,
            meetingID: meetingID,
            sequence: chunk.sequence,
            startMs: chunk.startMs,
            endMs: chunk.endMs,
            attemptCount: 0
        )

        do {
            try WAVEncoder.encode(chunk: chunk).write(to: audioFileURL, options: .atomic)
            try Self.write(metadata, beside: audioFileURL)
        } catch {
            try? FileManager.default.removeItem(at: audioFileURL)
            try? FileManager.default.removeItem(at: Self.metadataURL(for: audioFileURL))
            throw error
        }

        let stored = StoredRecord(metadata: metadata, audioFileURL: audioFileURL)
        recordsByID[id] = stored
        if cachedChunksByID.count < maximumInMemoryChunks {
            cachedChunksByID[id] = chunk
        }
        return stored.publicRecord
    }

    public func pendingRecords(meetingID: Meeting.ID? = nil) -> [PendingTranscriptionRecord] {
        sortedRecords(meetingID: meetingID).map(\.publicRecord)
    }

    public func next(meetingID: Meeting.ID) throws -> PendingTranscriptionItem? {
        let meetingRecords = sortedRecords(meetingID: meetingID)
        guard !meetingRecords.contains(where: { inFlightIDs.contains($0.metadata.id) }) else {
            return nil
        }
        guard let stored = meetingRecords.first(where: { $0.metadata.attemptCount < maximumAttempts }) else {
            return nil
        }
        let id = stored.metadata.id
        guard FileManager.default.fileExists(atPath: stored.audioFileURL.path) else {
            throw PendingTranscriptionQueueError.missingAudioFile(id)
        }

        let chunk: AudioChunk
        if let cached = cachedChunksByID[id] {
            chunk = cached
        } else {
            let durationMs = try WAVAudioSegmentReader.durationMs(from: stored.audioFileURL)
            var recovered = try WAVAudioSegmentReader.readChunk(
                from: stored.audioFileURL,
                startMs: 0,
                endMs: durationMs,
                sequence: stored.metadata.sequence
            )
            recovered.startMs = stored.metadata.startMs
            recovered.endMs = stored.metadata.endMs
            chunk = recovered
            cacheIfPossible(chunk, id: id)
        }
        inFlightIDs.insert(id)
        return PendingTranscriptionItem(record: stored.publicRecord, chunk: chunk)
    }

    public func markSucceeded(id: String) throws {
        try removeCompletedItem(id: id)
    }

    public func markSilent(id: String) throws {
        try removeCompletedItem(id: id)
    }

    @discardableResult
    public func markFailed(
        id: String,
        allowRetry: Bool = true
    ) throws -> PendingTranscriptionFailureDisposition {
        guard var stored = recordsByID[id] else {
            throw PendingTranscriptionQueueError.unknownItem(id)
        }
        stored.metadata.attemptCount = allowRetry
            ? stored.metadata.attemptCount + 1
            : maximumAttempts
        try Self.write(stored.metadata, beside: stored.audioFileURL)
        recordsByID[id] = stored
        inFlightIDs.remove(id)
        if stored.metadata.attemptCount >= maximumAttempts {
            return .exhausted(attemptCount: stored.metadata.attemptCount)
        }
        return .retryable(attemptCount: stored.metadata.attemptCount)
    }

    public func resetFailedAttempts(meetingID: Meeting.ID) throws {
        for stored in sortedRecords(meetingID: meetingID) where stored.metadata.attemptCount > 0 {
            var reset = stored
            reset.metadata.attemptCount = 0
            try Self.write(reset.metadata, beside: reset.audioFileURL)
            recordsByID[reset.metadata.id] = reset
            inFlightIDs.remove(reset.metadata.id)
        }
    }

    public func isDrained(meetingID: Meeting.ID) -> Bool {
        !recordsByID.values.contains { $0.metadata.meetingID == meetingID }
    }

    public func hasExhaustedRetries(meetingID: Meeting.ID) -> Bool {
        recordsByID.values.contains {
            $0.metadata.meetingID == meetingID && $0.metadata.attemptCount >= maximumAttempts
        }
    }

    public func hasProcessableItems(meetingID: Meeting.ID) -> Bool {
        recordsByID.values.contains {
            $0.metadata.meetingID == meetingID && $0.metadata.attemptCount < maximumAttempts
        }
    }

    public func removeAll(meetingID: Meeting.ID) throws {
        let ids = recordsByID.values
            .filter { $0.metadata.meetingID == meetingID }
            .map { $0.metadata.id }
        for id in ids {
            try removeCompletedItem(id: id)
        }
    }

    public var inMemoryChunkCount: Int {
        cachedChunksByID.count
    }

    private func removeCompletedItem(id: String) throws {
        guard let stored = recordsByID[id] else {
            throw PendingTranscriptionQueueError.unknownItem(id)
        }
        try FileManager.default.removeItem(at: stored.audioFileURL)
        try? FileManager.default.removeItem(at: Self.metadataURL(for: stored.audioFileURL))
        recordsByID.removeValue(forKey: id)
        cachedChunksByID.removeValue(forKey: id)
        inFlightIDs.remove(id)
        let meetingDirectoryURL = stored.audioFileURL.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: meetingDirectoryURL.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: meetingDirectoryURL)
        }
    }

    private func cacheIfPossible(_ chunk: AudioChunk, id: String) {
        guard cachedChunksByID.count < maximumInMemoryChunks else {
            return
        }
        cachedChunksByID[id] = chunk
    }

    private func sortedRecords(meetingID: Meeting.ID?) -> [StoredRecord] {
        recordsByID.values
            .filter { meetingID == nil || $0.metadata.meetingID == meetingID }
            .sorted { lhs, rhs in
                if lhs.metadata.sequence != rhs.metadata.sequence {
                    return lhs.metadata.sequence < rhs.metadata.sequence
                }
                if lhs.metadata.startMs != rhs.metadata.startMs {
                    return lhs.metadata.startMs < rhs.metadata.startMs
                }
                return lhs.metadata.id < rhs.metadata.id
            }
    }

    private static func loadRecords(from rootDirectoryURL: URL) throws -> [String: StoredRecord] {
        let fileManager = FileManager.default
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var records: [String: StoredRecord] = [:]
        for directoryURL in directoryURLs {
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let meetingID = meetingID(fromDirectoryName: directoryURL.lastPathComponent) else {
                continue
            }
            let audioURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "wav" }
            for audioFileURL in audioURLs {
                guard let filenameMetadata = metadata(fromAudioFileURL: audioFileURL, meetingID: meetingID) else {
                    continue
                }
                let metadataURL = metadataURL(for: audioFileURL)
                let metadata: Metadata
                if let data = try? Data(contentsOf: metadataURL),
                   let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
                   decoded.id == filenameMetadata.id,
                   decoded.meetingID == meetingID {
                    metadata = decoded
                } else {
                    metadata = filenameMetadata
                    try write(metadata, beside: audioFileURL)
                }
                records[metadata.id] = StoredRecord(metadata: metadata, audioFileURL: audioFileURL)
            }
        }
        return records
    }

    private static func write(_ metadata: Metadata, beside audioFileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL(for: audioFileURL), options: .atomic)
    }

    private static func metadataURL(for audioFileURL: URL) -> URL {
        audioFileURL.deletingPathExtension().appendingPathExtension("json")
    }

    private static func audioBaseName(id: String, sequence: Int, startMs: Int, endMs: Int) -> String {
        "\(id)--\(sequence)--\(startMs)--\(endMs)"
    }

    private static func metadata(fromAudioFileURL url: URL, meetingID: Meeting.ID) -> Metadata? {
        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
        guard parts.count == 4,
              let sequence = Int(parts[1]),
              let startMs = Int(parts[2]),
              let endMs = Int(parts[3]) else {
            return nil
        }
        return Metadata(
            id: parts[0],
            meetingID: meetingID,
            sequence: sequence,
            startMs: startMs,
            endMs: endMs,
            attemptCount: 0
        )
    }

    private static func meetingDirectoryName(_ meetingID: Meeting.ID) -> String {
        let encoded = Data(meetingID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "meeting_\(encoded)"
    }

    private static func meetingID(fromDirectoryName name: String) -> Meeting.ID? {
        guard name.hasPrefix("meeting_") else {
            return nil
        }
        var encoded = String(name.dropFirst("meeting_".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder > 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
