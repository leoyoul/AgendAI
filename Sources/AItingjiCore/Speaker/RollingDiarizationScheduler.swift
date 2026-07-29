import Foundation

public enum RollingDiarizationScheduler {
    public static let minimumRecordingDurationMs = 30_000
    public static let minimumCorrectionIntervalMs = 30_000
    public static let preferredCorrectionIntervalMs = 60_000

    public static func shouldTrigger(
        currentMaxRecordingMs: Int,
        lastCorrectionMs: Int?,
        isRunning: Bool
    ) -> Bool {
        guard isRunning else {
            return false
        }
        guard currentMaxRecordingMs >= minimumRecordingDurationMs else {
            return false
        }
        guard let lastCorrectionMs else {
            return true
        }
        return currentMaxRecordingMs - lastCorrectionMs >= minimumCorrectionIntervalMs
    }

    public static func nextCorrectionPointMs(currentMaxRecordingMs: Int) -> Int {
        max(minimumRecordingDurationMs, min(currentMaxRecordingMs, preferredCorrectionIntervalMs * (currentMaxRecordingMs / preferredCorrectionIntervalMs)))
    }
}
