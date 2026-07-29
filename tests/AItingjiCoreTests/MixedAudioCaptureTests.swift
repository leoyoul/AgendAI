import AItingjiCore
import Foundation
import Testing

@Test
func mixedAudioCaptureStartsBothSourcesAndEmitsMonotonicChunks() async throws {
    let microphone = StubCaptureSession(
        source: .microphone,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 200,
                endMs: 700,
                samples: [0.1, -0.1, 0.2, -0.2],
                format: AudioFormatDescription(sampleRate: 48_000, channels: 2)
            )
        ]
    )
    let screen = StubCaptureSession(
        source: .screenAudio,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 100,
                endMs: 600,
                samples: [0.2],
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = ChunkCollector()
    let trackCollector = TrackChunkCollector()

    try await mixed.start(
        callbacks: AudioCaptureCallbacks(
            onChunk: { chunk in
                Task {
                    await collector.append(chunk)
                }
            },
            onTrackChunk: { track, chunk in
                Task {
                    await trackCollector.append(track: track, chunk: chunk)
                }
            }
        )
    )

    try await Task.sleep(nanoseconds: 50_000_000)
    let chunks = await collector.chunks
    let trackChunks = await trackCollector.trackChunks
    #expect(microphone.startCount == 1)
    #expect(screen.startCount == 1)
    #expect(chunks.map(\.startMs) == [0])
    #expect(chunks.map(\.sequence) == [0])
    #expect(chunks.allSatisfy { $0.format == AudioFormatDescription(sampleRate: 16_000, channels: 1) })
    #expect(Set(trackChunks.map(\.track)) == Set([.microphone, .computer]))
}

@Test
func mixedAudioCaptureMixesOverlappingMicrophoneAndComputerChunksIntoOneTimelineChunk() async throws {
    let microphone = StubCaptureSession(
        source: .microphone,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 0,
                endMs: 1_000,
                samples: Array(repeating: 0.25, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let screen = StubCaptureSession(
        source: .screenAudio,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 0,
                endMs: 1_000,
                samples: Array(repeating: 0.5, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = ChunkCollector()

    try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { chunk in
        Task {
            await collector.append(chunk)
        }
    }))

    try await Task.sleep(nanoseconds: 50_000_000)
    let chunks = await collector.chunks
    #expect(chunks.count == 1)
    #expect(chunks.first?.startMs == 0)
    #expect(chunks.first?.endMs == 1_000)
    #expect(chunks.first?.samples.prefix(10).allSatisfy { abs($0 - 0.375) < 0.001 } == true)
}

@Test
func mixedAudioCaptureAddsHeadroomToAvoidClippedMixedSamples() async throws {
    let microphone = StubCaptureSession(
        source: .microphone,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 0,
                endMs: 1_000,
                samples: Array(repeating: 0.9, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let screen = StubCaptureSession(
        source: .screenAudio,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 0,
                endMs: 1_000,
                samples: Array(repeating: 0.9, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = ChunkCollector()

    try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { chunk in
        Task {
            await collector.append(chunk)
        }
    }))

    try await Task.sleep(nanoseconds: 50_000_000)
    let chunks = await collector.chunks
    #expect(chunks.first?.samples.max() == 0.9)
}

@Test
func mixedAudioCaptureFlushesUnpairedChunksOnStop() async throws {
    let microphone = StubCaptureSession(
        source: .microphone,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 0,
                endMs: 1_000,
                samples: Array(repeating: 0.25, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let screen = StubCaptureSession(source: .screenAudio)
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = ChunkCollector()

    try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { chunk in
        Task {
            await collector.append(chunk)
        }
    }))
    await mixed.stop()

    try await Task.sleep(nanoseconds: 50_000_000)
    let chunks = await collector.chunks
    #expect(chunks.count == 1)
    #expect(chunks.first?.startMs == 0)
    #expect(chunks.first?.endMs == 1_000)
}

@Test
func mixedAudioCaptureStopsAlreadyStartedSourceWhenSecondStartFails() async throws {
    let microphone = StubCaptureSession(source: .microphone)
    let screen = StubCaptureSession(
        source: .screenAudio,
        startError: AudioCaptureError.startFailed("屏幕音频失败")
    )
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)

    await #expect(throws: AudioCaptureError.startFailed("屏幕音频失败")) {
        try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { _ in }))
    }

    #expect(microphone.startCount == 1)
    #expect(microphone.stopCount == 1)
    #expect(screen.startCount == 1)
    #expect(!mixed.isRunning)
}

@Test
func mixedAudioCaptureMixesEvenWhenMicAndScreenStartTimesDiffer() async throws {
    // 麦克风窗口从 0ms 起，屏幕窗口从 200ms 起（模拟两个 AV/SCK 会话启动时间差），
    // 修好时间基后两路应该被识别为同一秒的两路输入并混合成一条 chunk。
    let microphone = StubCaptureSession(
        source: .microphone,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 0,
                endMs: 1_000,
                samples: Array(repeating: 0.25, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let screen = StubCaptureSession(
        source: .screenAudio,
        chunks: [
            AudioChunk(
                sequence: 0,
                startMs: 200,
                endMs: 1_200,
                samples: Array(repeating: 0.5, count: 16_000),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        ]
    )
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = ChunkCollector()

    try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { chunk in
        Task { await collector.append(chunk) }
    }))
    try await Task.sleep(nanoseconds: 60_000_000)
    let chunks = await collector.chunks
    #expect(chunks.count == 1, "Expected two offset streams to still merge, got \(chunks.count) chunks")
    if let first = chunks.first {
        #expect(first.samples.prefix(10).allSatisfy { abs($0 - 0.375) < 0.001 })
    }
}


@Test
func mixedAudioCaptureRetainsEveryInterleavedChunkFromSameWindowBurst() async throws {
    let microphone = ManualCaptureSession(source: .microphone)
    let screen = ManualCaptureSession(source: .screenAudio)
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = LockedChunkCollector()
    let format = AudioFormatDescription(sampleRate: 16_000, channels: 1)

    try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { chunk in
        collector.append(chunk)
    }))

    // 模拟底层回调突发：同一轨先连续到达多个相邻小 buffer，另一轨随后到达。
    // 旧的 [window: chunk] 实现会覆盖同一 window 内更早的单轨数据。
    for startMs in [0, 250, 500, 750] {
        microphone.emit(
            AudioChunk(
                sequence: startMs / 250,
                startMs: startMs,
                endMs: startMs + 250,
                samples: Array(repeating: 0.2, count: 4_000),
                format: format
            )
        )
    }
    for startMs in [0, 250, 500, 750] {
        screen.emit(
            AudioChunk(
                sequence: startMs / 250,
                startMs: startMs,
                endMs: startMs + 250,
                samples: Array(repeating: 0.6, count: 4_000),
                format: format
            )
        )
    }

    let chunks = collector.chunks
    #expect(chunks.count == 4)
    #expect(chunks.map(\.sequence) == [0, 1, 2, 3])
    #expect(chunks.allSatisfy { $0.samples.count == 4_000 })
    #expect(chunks.allSatisfy { $0.samples.allSatisfy { abs($0 - 0.4) < 0.001 } })

    await mixed.stop()
}

@Test
func mixedAudioCaptureFlushesEveryUnpairedChunkFromSameWindowBurst() async throws {
    let microphone = ManualCaptureSession(source: .microphone)
    let screen = ManualCaptureSession(source: .screenAudio)
    let mixed = MixedAudioCapture(microphone: microphone, computerAudio: screen)
    let collector = LockedChunkCollector()
    let format = AudioFormatDescription(sampleRate: 16_000, channels: 1)

    try await mixed.start(callbacks: AudioCaptureCallbacks(onChunk: { chunk in
        collector.append(chunk)
    }))

    for startMs in [0, 250, 500, 750] {
        microphone.emit(
            AudioChunk(
                sequence: startMs / 250,
                startMs: startMs,
                endMs: startMs + 250,
                samples: Array(repeating: 0.25, count: 4_000),
                format: format
            )
        )
    }
    await mixed.stop()

    let chunks = collector.chunks
    #expect(chunks.count == 4)
    #expect(chunks.map(\.sequence) == [0, 1, 2, 3])
    #expect(chunks.map(\.startMs) == [0, 250, 500, 750])
    #expect(chunks.allSatisfy { $0.samples.allSatisfy { abs($0 - 0.25) < 0.001 } })
}

private final class StubCaptureSession: AudioCaptureSession, @unchecked Sendable {
    let source: CaptureSource
    let chunks: [AudioChunk]
    let startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var running = false

    init(source: CaptureSource, chunks: [AudioChunk] = [], startError: Error? = nil) {
        self.source = source
        self.chunks = chunks
        self.startError = startError
    }

    var isRunning: Bool {
        running
    }

    func start(callbacks: AudioCaptureCallbacks) async throws {
        startCount += 1
        if let startError {
            throw startError
        }
        running = true
        for chunk in chunks {
            callbacks.onChunk(chunk)
        }
    }

    func stop() async {
        stopCount += 1
        running = false
    }
}


private final class ManualCaptureSession: AudioCaptureSession, @unchecked Sendable {
    let source: CaptureSource
    private var callbacks: AudioCaptureCallbacks?
    private var running = false

    init(source: CaptureSource) {
        self.source = source
    }

    var isRunning: Bool {
        running
    }

    func start(callbacks: AudioCaptureCallbacks) async throws {
        self.callbacks = callbacks
        running = true
    }

    func stop() async {
        running = false
        callbacks = nil
    }

    func emit(_ chunk: AudioChunk) {
        callbacks?.onChunk(chunk)
    }
}

private final class LockedChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChunks: [AudioChunk] = []

    var chunks: [AudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        return storedChunks
    }

    func append(_ chunk: AudioChunk) {
        lock.lock()
        storedChunks.append(chunk)
        lock.unlock()
    }
}

private actor ChunkCollector {
    private(set) var chunks: [AudioChunk] = []

    func append(_ chunk: AudioChunk) {
        chunks.append(chunk)
    }
}

private actor TrackChunkCollector {
    private(set) var trackChunks: [(track: AudioCaptureTrack, chunk: AudioChunk)] = []

    func append(track: AudioCaptureTrack, chunk: AudioChunk) {
        trackChunks.append((track, chunk))
    }
}
