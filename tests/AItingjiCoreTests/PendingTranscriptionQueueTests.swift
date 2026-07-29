import AItingjiCore
import Foundation
import Testing

@Suite("Pending transcription queue")
struct PendingTranscriptionQueueTests {
    @Test("enqueue persists a readable WAV before exposing the item")
    func persistsWAV() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root)

        let record = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 2))

        #expect(FileManager.default.fileExists(atPath: record.audioFileURL.path))
        #expect(try WAVAudioSegmentReader.durationMs(from: record.audioFileURL) == 100)
        #expect(await queue.pendingRecords(meetingID: "meeting-a").count == 1)
    }

    @Test("memory cache stays bounded while disk queue keeps every chunk")
    func boundedMemoryKeepsLongBacklog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root, maximumInMemoryChunks: 6)

        for sequence in 0..<12 {
            try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: sequence))
        }

        #expect(await queue.inMemoryChunkCount == 6)
        #expect(await queue.pendingRecords(meetingID: "meeting-a").count == 12)
    }

    @Test("items are delivered FIFO and success removes their files")
    func fifoAndSuccessCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 3))
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 1))
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 2))

        let first = try #require(try await queue.next(meetingID: "meeting-a"))
        let firstURL = first.record.audioFileURL
        #expect(first.chunk.sequence == 1)
        try await queue.markSucceeded(id: first.record.id)

        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(try await queue.next(meetingID: "meeting-a")?.chunk.sequence == 2)
    }

    @Test("silent items are removed and drain the meeting")
    func silentCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))
        let item = try #require(try await queue.next(meetingID: "meeting-a"))

        try await queue.markSilent(id: item.record.id)

        #expect(await queue.isDrained(meetingID: "meeting-a"))
    }

    @Test("an in-flight item cannot be dequeued twice")
    func inFlightItemIsUnique() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))

        _ = try #require(try await queue.next(meetingID: "meeting-a"))

        #expect(try await queue.next(meetingID: "meeting-a") == nil)
    }

    @Test("failures retry three times then remain on disk for recovery")
    func failedItemIsRetained() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root, maximumAttempts: 3)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))

        for expectedAttempt in 1...3 {
            let item = try #require(try await queue.next(meetingID: "meeting-a"))
            let disposition = try await queue.markFailed(id: item.record.id)
            if expectedAttempt < 3 {
                #expect(disposition == .retryable(attemptCount: expectedAttempt))
            } else {
                #expect(disposition == .exhausted(attemptCount: expectedAttempt))
                #expect(FileManager.default.fileExists(atPath: item.record.audioFileURL.path))
            }
        }

        #expect(try await queue.next(meetingID: "meeting-a") == nil)
        #expect(await queue.hasExhaustedRetries(meetingID: "meeting-a"))
        #expect(!(await queue.isDrained(meetingID: "meeting-a")))
    }

    @Test("an exhausted item does not block later queued audio")
    func exhaustedItemDoesNotBlockQueue() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root, maximumAttempts: 1)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 1))
        let first = try #require(try await queue.next(meetingID: "meeting-a"))
        _ = try await queue.markFailed(id: first.record.id)

        let second = try #require(try await queue.next(meetingID: "meeting-a"))

        #expect(second.chunk.sequence == 1)
        #expect(await queue.hasExhaustedRetries(meetingID: "meeting-a"))
        #expect(await queue.hasProcessableItems(meetingID: "meeting-a"))
    }

    @Test("restart restores timeline and persistent retry count")
    func restartRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let queue = try PendingTranscriptionQueue(rootDirectoryURL: root)
            _ = try await queue.enqueue(
                meetingID: "meeting/with spaces",
                chunk: chunk(sequence: 8, startMs: 2_400)
            )
            let item = try #require(try await queue.next(meetingID: "meeting/with spaces"))
            _ = try await queue.markFailed(id: item.record.id)
        }

        let restored = try PendingTranscriptionQueue(rootDirectoryURL: root)
        let item = try #require(try await restored.next(meetingID: "meeting/with spaces"))

        #expect(item.record.attemptCount == 1)
        #expect(item.chunk.sequence == 8)
        #expect(item.chunk.startMs == 2_400)
        #expect(item.chunk.endMs == 2_500)
        #expect(item.chunk.samples.count == 1_600)
    }

    @Test("exhausted work can be explicitly reset after fixing ASR")
    func resetFailedAttempts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root, maximumAttempts: 1)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))
        let failed = try #require(try await queue.next(meetingID: "meeting-a"))
        _ = try await queue.markFailed(id: failed.record.id)

        try await queue.resetFailedAttempts(meetingID: "meeting-a")
        let recovered = try #require(try await queue.next(meetingID: "meeting-a"))

        #expect(recovered.record.attemptCount == 0)
    }

    @Test("a timeout-like failure can be blocked without automatic retry")
    func nonRetryableFailureIsExhaustedImmediately() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root, maximumAttempts: 3)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))
        let item = try #require(try await queue.next(meetingID: "meeting-a"))

        let disposition = try await queue.markFailed(id: item.record.id, allowRetry: false)

        #expect(disposition == .exhausted(attemptCount: 3))
        #expect(try await queue.next(meetingID: "meeting-a") == nil)
        #expect(await queue.hasExhaustedRetries(meetingID: "meeting-a"))
    }

    @Test("removing one meeting leaves another meeting untouched")
    func removeMeetingQueue() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: root)
        _ = try await queue.enqueue(meetingID: "meeting-a", chunk: chunk(sequence: 0))
        _ = try await queue.enqueue(meetingID: "meeting-b", chunk: chunk(sequence: 0))

        try await queue.removeAll(meetingID: "meeting-a")

        #expect(await queue.isDrained(meetingID: "meeting-a"))
        #expect(!(await queue.isDrained(meetingID: "meeting-b")))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-transcription-\(UUID().uuidString)", isDirectory: true)
    }

    private func chunk(sequence: Int, startMs: Int? = nil) -> AudioChunk {
        let resolvedStartMs = startMs ?? sequence * 100
        return AudioChunk(
            sequence: sequence,
            startMs: resolvedStartMs,
            endMs: resolvedStartMs + 100,
            samples: Array(repeating: Float(sequence + 1) / 100, count: 1_600),
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    }
}
