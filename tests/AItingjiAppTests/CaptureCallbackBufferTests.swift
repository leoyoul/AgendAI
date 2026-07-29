import AItingjiCore
import Testing
@testable import AItingjiApp

@Suite("Capture callback buffer")
struct CaptureCallbackBufferTests {
    @Test("drain keeps callback order and clears the buffer")
    func drainPreservesOrder() {
        let buffer = CaptureCallbackBuffer()
        let first = chunk(sequence: 1)
        let second = chunk(sequence: 2)

        buffer.append(.track(.microphone, first))
        buffer.append(.mixed(second))

        #expect(buffer.drain() == [.track(.microphone, first), .mixed(second)])
        #expect(buffer.drain().isEmpty)
    }

    @Test("concurrent callbacks are retained")
    func concurrentCallbacksAreRetained() async {
        let buffer = CaptureCallbackBuffer()

        await withTaskGroup(of: Void.self) { group in
            for sequence in 0..<100 {
                group.addTask {
                    buffer.append(.mixed(chunk(sequence: sequence)))
                }
            }
        }

        #expect(buffer.drain().count == 100)
    }

    private func chunk(sequence: Int) -> AudioChunk {
        AudioChunk(
            sequence: sequence,
            startMs: sequence * 1_000,
            endMs: sequence * 1_000 + 1_000,
            samples: [0.1, -0.1],
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    }
}
