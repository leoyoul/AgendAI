import Foundation

public enum MeetingAudioFileRepair {
    public static func repairLegacyZeroHeaderIfNeeded(url: URL) throws -> Bool {
        var data = try Data(contentsOf: url)
        guard data.count > 44 else {
            return false
        }
        guard data[0..<4] != Data("RIFF".utf8) else {
            return false
        }
        guard data[0..<44].allSatisfy({ $0 == 0 }) else {
            return false
        }

        let pcmByteCount = data.count - 44
        data.replaceSubrange(0..<44, with: wavHeader(pcmByteCount: UInt32(pcmByteCount)))
        try data.write(to: url, options: .atomic)
        return true
    }

    private static func wavHeader(pcmByteCount: UInt32) -> Data {
        var data = Data()
        let sampleRate = UInt32(16_000)
        let channels = UInt16(1)
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)

        data.appendString("RIFF")
        data.appendLittleEndian(UInt32(36) + pcmByteCount)
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendString("data")
        data.appendLittleEndian(pcmByteCount)
        return data
    }
}
