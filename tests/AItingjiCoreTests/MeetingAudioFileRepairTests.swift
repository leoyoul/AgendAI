import AItingjiCore
import Foundation
import Testing

@Test
func meetingAudioFileRepairRestoresLegacyZeroWAVHeader() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-repair-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    var legacyData = Data(repeating: 0, count: 44)
    legacyData.append(contentsOf: [0x00, 0x00, 0xff, 0x7f])
    try legacyData.write(to: url)

    let didRepair = try MeetingAudioFileRepair.repairLegacyZeroHeaderIfNeeded(url: url)
    let repaired = try Data(contentsOf: url)

    #expect(didRepair)
    #expect(String(decoding: repaired[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: repaired[8..<12], as: UTF8.self) == "WAVE")
    #expect(repaired.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }.littleEndian == 16_000)
    #expect(repaired.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }.littleEndian == 4)
    try? FileManager.default.removeItem(at: url)
}

@Test
func meetingAudioFileRepairLeavesValidWAVUnchanged() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-repair-valid-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1,
            samples: [0.0, 0.25],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    try writer.finish()
    let before = try Data(contentsOf: url)

    let didRepair = try MeetingAudioFileRepair.repairLegacyZeroHeaderIfNeeded(url: url)
    let after = try Data(contentsOf: url)

    #expect(!didRepair)
    #expect(after == before)
    try? FileManager.default.removeItem(at: url)
}
