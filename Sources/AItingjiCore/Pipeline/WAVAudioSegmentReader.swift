import Foundation

public enum WAVAudioSegmentReaderError: Error, Equatable, Sendable {
    case fileTooSmall
    case unsupportedFormat
    case missingDataChunk
}

public enum WAVAudioSegmentReader {
    public static func durationMs(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let metadata = try parsePCM16MonoWAV(data)
        let sampleRate = metadata.sampleRate
        let dataChunk = metadata.dataChunk
        let bytesPerSample = 2
        let frameCount = dataChunk.size / bytesPerSample
        return Int(Double(frameCount) / Double(sampleRate) * 1_000)
    }

    public static func readChunk(
        from url: URL,
        startMs: Int,
        endMs: Int,
        sequence: Int
    ) throws -> AudioChunk {
        let data = try Data(contentsOf: url)
        let metadata = try parsePCM16MonoWAV(data)
        return try readChunk(from: data, metadata: metadata, startMs: startMs, endMs: endMs, sequence: sequence)
    }

    public static func readChunks(
        from url: URL,
        chunkDurationMs: Int,
        startingSequence: Int = 1
    ) throws -> [AudioChunk] {
        precondition(chunkDurationMs > 0)
        let data = try Data(contentsOf: url)
        let metadata = try parsePCM16MonoWAV(data)
        let bytesPerSample = 2
        let frameCount = metadata.dataChunk.size / bytesPerSample
        guard frameCount > 0 else {
            return []
        }

        let durationMs = Int(Double(frameCount) / Double(metadata.sampleRate) * 1_000)
        var chunks: [AudioChunk] = []
        var startMs = 0
        var sequence = startingSequence
        while startMs < durationMs {
            let endMs = min(durationMs, startMs + chunkDurationMs)
            chunks.append(
                try readChunk(
                    from: data,
                    metadata: metadata,
                    startMs: startMs,
                    endMs: endMs,
                    sequence: sequence
                )
            )
            startMs = endMs
            sequence += 1
        }
        return chunks
    }

    private static func readChunk(
        from data: Data,
        metadata: WAVMetadata,
        startMs: Int,
        endMs: Int,
        sequence: Int
    ) throws -> AudioChunk {
        let dataChunk = metadata.dataChunk
        let sampleRate = metadata.sampleRate
        let channels = metadata.channels
        let bytesPerSample = 2
        let frameCount = dataChunk.size / bytesPerSample
        let clampedStartMs = max(0, startMs)
        let clampedEndMs = max(clampedStartMs, endMs)
        let startFrame = min(frameCount, clampedStartMs * sampleRate / 1000)
        let endFrame = min(frameCount, clampedEndMs * sampleRate / 1000)
        let startByte = dataChunk.offset + startFrame * bytesPerSample
        let endByte = dataChunk.offset + endFrame * bytesPerSample
        let samples = stride(from: startByte, to: endByte, by: bytesPerSample).map { offset in
            Float(data.readInt16LE(at: offset)) / Float(Int16.max)
        }

        return AudioChunk(
            sequence: sequence,
            startMs: clampedStartMs,
            endMs: clampedStartMs + Int(Double(samples.count) / Double(sampleRate) * 1000),
            samples: samples,
            format: AudioFormatDescription(sampleRate: Double(sampleRate), channels: channels)
        )
    }

    private struct WAVMetadata {
        var sampleRate: Int
        var channels: Int
        var dataChunk: (offset: Int, size: Int)
    }

    private static func parsePCM16MonoWAV(_ data: Data) throws -> WAVMetadata {
        guard data.count >= 44 else {
            throw WAVAudioSegmentReaderError.fileTooSmall
        }
        guard String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw WAVAudioSegmentReaderError.unsupportedFormat
        }

        let audioFormat = data.readUInt16LE(at: 20)
        let channels = Int(data.readUInt16LE(at: 22))
        let sampleRate = Int(data.readUInt32LE(at: 24))
        let bitsPerSample = Int(data.readUInt16LE(at: 34))
        guard audioFormat == 1, channels == 1, sampleRate > 0, bitsPerSample == 16 else {
            throw WAVAudioSegmentReaderError.unsupportedFormat
        }

        return WAVMetadata(
            sampleRate: sampleRate,
            channels: channels,
            dataChunk: try findDataChunk(in: data)
        )
    }

    private static func findDataChunk(in data: Data) throws -> (offset: Int, size: Int) {
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(data.readUInt32LE(at: offset + 4))
            let contentOffset = offset + 8
            guard contentOffset + chunkSize <= data.count else {
                break
            }
            if chunkID == "data" {
                return (contentOffset, chunkSize)
            }
            offset = contentOffset + chunkSize + (chunkSize % 2)
        }
        throw WAVAudioSegmentReaderError.missingDataChunk
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        self.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        self.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func readInt16LE(at offset: Int) -> Int16 {
        self.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: Int16.self).littleEndian
        }
    }
}
