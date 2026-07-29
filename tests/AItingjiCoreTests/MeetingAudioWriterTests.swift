import AItingjiCore
import Foundation
import Testing

@Test
func meetingAudioWriterReportsWrittenAudioDurationForResumeTimeline() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-duration-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1_500,
            samples: Array(repeating: 0.1, count: 24_000),
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )

    #expect(writer.durationMs == 1_500)
    try writer.finish()
    try? FileManager.default.removeItem(at: url)
}

@Test
func meetingAudioTrackWritersCreateMixedMicrophoneAndComputerFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-tracks-\(UUID().uuidString)", isDirectory: true)
    let mixedURL = directory.appendingPathComponent("recording.wav")
    let microphoneURL = directory.appendingPathComponent("microphone.wav")
    let computerURL = directory.appendingPathComponent("computer.wav")
    let writers = try MeetingAudioTrackWriters(
        mixedURL: mixedURL,
        microphoneURL: microphoneURL,
        computerURL: computerURL
    )
    let chunk = AudioChunk(
        sequence: 0,
        startMs: 0,
        endMs: 1,
        samples: [0.0, 0.5, -0.5],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    try writers.appendMixed(chunk)
    try writers.appendTrack(.microphone, chunk: chunk)
    try writers.appendTrack(.computer, chunk: chunk)
    try writers.finish()

    #expect(FileManager.default.fileExists(atPath: mixedURL.path))
    #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
    #expect(FileManager.default.fileExists(atPath: computerURL.path))
    try? FileManager.default.removeItem(at: directory)
}

@Test
func meetingAudioWriterCreatesAppendable16kMonoWAV() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1,
            samples: [0.0, 0.5, -0.5],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    try writer.finish()

    let data = try Data(contentsOf: url)

    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }.littleEndian == 16_000)
    #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self) }.littleEndian == 1)
    #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }.littleEndian == 6)
    try? FileManager.default.removeItem(at: url)
}

@Test
func meetingAudioWriterKeepsWAVHeaderReadableBeforeFinish() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-live-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1,
            samples: [0.0, 0.25, -0.25, 0.5],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )

    let data = try Data(contentsOf: url)

    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }.littleEndian == 8)
    try writer.finish()
    try? FileManager.default.removeItem(at: url)
}

@Test
func meetingAudioWriterReplacesExistingInvalidFileWithReadableWAV() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-existing-invalid-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    try Data("not-a-readable-wav".utf8).write(to: url)

    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1,
            samples: [0.0, 0.5],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )

    let data = try Data(contentsOf: url)

    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }.littleEndian == 4)
    try writer.finish()
    try? FileManager.default.removeItem(at: url)
}

@Test
func meetingAudioWriterFlushMakesFilePlayableAndAllowsContinuedAppends() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-flush-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1,
            samples: [0.1, -0.1],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    // pause 场景：只 flush，不 finish
    try writer.flush()

    let beforeData = try Data(contentsOf: url)
    // WAV subchunk2 size 位于 offset 40，两个采样 * 2 字节 = 4
    let bytesBefore = beforeData.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian
    }
    #expect(bytesBefore == 4)

    // resume 场景：继续 append 应该照旧生效
    try writer.append(
        AudioChunk(
            sequence: 1,
            startMs: 1,
            endMs: 2,
            samples: [0.2, 0.3, -0.2],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    try writer.finish()

    let afterData = try Data(contentsOf: url)
    let bytesAfter = afterData.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian
    }
    #expect(bytesAfter == 10)
    try? FileManager.default.removeItem(at: url)
}

@Test
func meetingAudioTrackWritersFlushSyncsAllTracks() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-tracks-flush-\(UUID().uuidString)", isDirectory: true)
    let mixedURL = directory.appendingPathComponent("recording.wav")
    let microphoneURL = directory.appendingPathComponent("microphone.wav")
    let computerURL = directory.appendingPathComponent("computer.wav")
    let writers = try MeetingAudioTrackWriters(
        mixedURL: mixedURL,
        microphoneURL: microphoneURL,
        computerURL: computerURL
    )
    let chunk = AudioChunk(
        sequence: 0,
        startMs: 0,
        endMs: 1,
        samples: [0.0, 0.5, -0.5],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )
    try writers.appendMixed(chunk)
    try writers.appendTrack(.microphone, chunk: chunk)
    try writers.appendTrack(.computer, chunk: chunk)
    try writers.flush()

    for path in [mixedURL, microphoneURL, computerURL] {
        let data = try Data(contentsOf: path)
        #expect(data.count >= 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    }
    try writers.finish()
    try? FileManager.default.removeItem(at: directory)
}
