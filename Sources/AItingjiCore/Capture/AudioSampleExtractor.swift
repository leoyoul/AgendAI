import AVFoundation
import CoreMedia
import Foundation

public enum AudioSampleExtractor {
    public static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var samples: [Float] = []
        samples.reserveCapacity(frameLength * max(channelCount, 1))

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                samples.append(channelData[channel][frame])
            }
        }
        return samples
    }

    public static func extractSamples(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], format: AudioFormatDescription)? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let sampleRate = streamDescription.pointee.mSampleRate
        let channels = max(1, Int(streamDescription.pointee.mChannelsPerFrame))
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == noErr,
              let dataPointer,
              length > 0 else {
            return nil
        }

        let flags = streamDescription.pointee.mFormatFlags
        let bitsPerChannel = streamDescription.pointee.mBitsPerChannel
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0

        let samples: [Float]
        if isFloat && bitsPerChannel == 32 {
            let count = length / MemoryLayout<Float>.size
            samples = dataPointer.withMemoryRebound(to: Float.self, capacity: count) { pointer in
                Array(UnsafeBufferPointer(start: pointer, count: count))
            }
        } else if isSignedInteger && bitsPerChannel == 16 {
            let count = length / MemoryLayout<Int16>.size
            samples = dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { pointer in
                UnsafeBufferPointer(start: pointer, count: count).map { Float($0) / Float(Int16.max) }
            }
        } else {
            return nil
        }

        return (
            samples,
            AudioFormatDescription(
                sampleRate: sampleRate,
                channels: channels,
                sampleFormat: isFloat ? "pcm_f32" : "pcm_s16"
            )
        )
    }
}
