import AItingjiCore
import Foundation

@main
struct AItingjiCaptureSmoke {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("usage: AItingjiCaptureSmoke <microphone|screen-audio|mixed> [seconds]")
            Foundation.exit(2)
        }

        let source = arguments[1]
        let seconds = arguments.count >= 3 ? Double(arguments[2]) ?? 5 : 5

        do {
            switch source {
            case "microphone":
                print("microphone_permission=\(PermissionService().microphoneStatus().rawValue)")
                try await run(session: MicrophoneCapture(), seconds: seconds)
            case "screen-audio":
                print("screen_recording_permission=\(PermissionService().screenRecordingStatus().rawValue)")
                try await run(session: ScreenAudioCapture(), seconds: seconds)
            case "mixed":
                print("microphone_permission=\(PermissionService().microphoneStatus().rawValue)")
                print("screen_recording_permission=\(PermissionService().screenRecordingStatus().rawValue)")
                try await run(session: MixedAudioCapture(), seconds: seconds)
            default:
                print("unknown source: \(source)")
                Foundation.exit(2)
            }
        } catch {
            print("capture_failed=\(error)")
            Foundation.exit(1)
        }
    }

    private static func run(session: AudioCaptureSession, seconds: Double) async throws {
        let stats = CaptureStats()
        try await session.start(
            callbacks: AudioCaptureCallbacks(
                onChunk: { chunk in
                    Task {
                        await stats.addChunk(chunk)
                    }
                },
                onLevel: { level in
                    Task {
                        await stats.addLevel(level)
                    }
                },
                onError: { error in
                    print("capture_error=\(error)")
                }
            )
        )
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await session.stop()

        let snapshot = await stats.snapshot()
        print("source=\(session.source.rawValue)")
        print("chunks=\(snapshot.chunks)")
        print("non_empty_chunks=\(snapshot.nonEmptyChunks)")
        print("samples=\(snapshot.samples)")
        print("peak=\(snapshot.peak)")

        guard snapshot.chunks > 0, snapshot.nonEmptyChunks > 0, snapshot.samples > 0 else {
            Foundation.exit(1)
        }
    }
}

private actor CaptureStats {
    private var chunks = 0
    private var nonEmptyChunks = 0
    private var samples = 0
    private var peak: Float = 0

    func addChunk(_ chunk: AudioChunk) {
        chunks += 1
        samples += chunk.samples.count
        if !chunk.samples.isEmpty {
            nonEmptyChunks += 1
        }
        let chunkPeak = chunk.samples.map { abs($0) }.max() ?? 0
        peak = max(peak, chunkPeak)
    }

    func addLevel(_ level: Float) {
        peak = max(peak, level)
    }

    func snapshot() -> (chunks: Int, nonEmptyChunks: Int, samples: Int, peak: Float) {
        (chunks, nonEmptyChunks, samples, peak)
    }
}
