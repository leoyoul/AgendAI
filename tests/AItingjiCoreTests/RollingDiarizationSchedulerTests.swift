import AItingjiCore
import Testing

@Test
func rollingDiarizationDoesNotTriggerBeforeMinimumWindow() {
    #expect(!RollingDiarizationScheduler.shouldTrigger(
        currentMaxRecordingMs: 29_999,
        lastCorrectionMs: nil,
        isRunning: true
    ))
}

@Test
func rollingDiarizationTriggersAtMinimumWindowWithoutBlockingASR() {
    #expect(RollingDiarizationScheduler.shouldTrigger(
        currentMaxRecordingMs: 30_000,
        lastCorrectionMs: nil,
        isRunning: true
    ))
    #expect(RollingDiarizationScheduler.nextCorrectionPointMs(currentMaxRecordingMs: 45_000) == 30_000)
}

@Test
func rollingDiarizationWaitsForCorrectionInterval() {
    #expect(!RollingDiarizationScheduler.shouldTrigger(
        currentMaxRecordingMs: 59_999,
        lastCorrectionMs: 30_000,
        isRunning: true
    ))
    #expect(RollingDiarizationScheduler.shouldTrigger(
        currentMaxRecordingMs: 60_000,
        lastCorrectionMs: 30_000,
        isRunning: true
    ))
    #expect(!RollingDiarizationScheduler.shouldTrigger(
        currentMaxRecordingMs: 90_000,
        lastCorrectionMs: 60_000,
        isRunning: false
    ))
}
