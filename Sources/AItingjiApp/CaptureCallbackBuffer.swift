import AItingjiCore
import Foundation

enum CaptureCallbackEvent: Equatable, Sendable {
    case mixed(AudioChunk)
    case track(AudioCaptureTrack, AudioChunk)
}

final class CaptureCallbackBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CaptureCallbackEvent] = []

    func append(_ event: CaptureCallbackEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    func drain() -> [CaptureCallbackEvent] {
        lock.withLock {
            defer { events.removeAll(keepingCapacity: true) }
            return events
        }
    }

    func reset() {
        lock.withLock {
            events.removeAll(keepingCapacity: true)
        }
    }
}
