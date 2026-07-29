import AItingjiCore
import Testing

@Test
func microphonePreflightAllowsCaptureWhenScreenRecordingIsDenied() {
    let result = CaptureStartPreflight.evaluate(
        source: .microphone,
        snapshot: CapturePermissionSnapshot(microphone: .authorized, screenRecording: .denied)
    )

    #expect(result == .allowed)
}

@Test
func computerAudioPreflightBlocksWhenScreenRecordingIsDenied() {
    let result = CaptureStartPreflight.evaluate(
        source: .screenAudio,
        snapshot: CapturePermissionSnapshot(microphone: .authorized, screenRecording: .denied)
    )

    guard case .blocked(let block) = result else {
        Issue.record("Expected computer audio capture to be blocked")
        return
    }
    #expect(block.missingPermissions == [.screenRecording])
    #expect(block.message == "录音未开始：请先授权屏幕录制，授权后退出并重新打开会小纪。")
    #expect(block.canSwitchToMicrophone)
}

@Test
func mixedPreflightBlocksWhenAnyRequiredPermissionIsMissing() {
    let screenMissing = CaptureStartPreflight.evaluate(
        source: .mixed,
        snapshot: CapturePermissionSnapshot(microphone: .authorized, screenRecording: .denied)
    )
    let bothMissing = CaptureStartPreflight.evaluate(
        source: .mixed,
        snapshot: CapturePermissionSnapshot(microphone: .denied, screenRecording: .denied)
    )

    guard case .blocked(let screenBlock) = screenMissing else {
        Issue.record("Expected mixed capture to be blocked when screen recording is missing")
        return
    }
    #expect(screenBlock.missingPermissions == [.screenRecording])
    #expect(screenBlock.canSwitchToMicrophone)

    guard case .blocked(let bothBlock) = bothMissing else {
        Issue.record("Expected mixed capture to be blocked when both permissions are missing")
        return
    }
    #expect(bothBlock.missingPermissions == [.microphone, .screenRecording])
    #expect(bothBlock.message == "录音未开始：请先授权麦克风和屏幕录制，授权后退出并重新打开会小纪。")
    #expect(!bothBlock.canSwitchToMicrophone)
}

@Test
func startupFailureMessagesAreSpecificAndCopyableAsPlainErrorText() {
    #expect(RecordingStartupFailureMessage.permission(missing: [.microphone]) == "录音未开始：请先授权麦克风。")
    #expect(RecordingStartupFailureMessage.asrWarmup("服务不可达") == "录音未开始：ASR 模型预热失败：服务不可达")
    #expect(RecordingStartupFailureMessage.voiceprintWarmup("模型不存在") == "录音未开始：声纹模型预热失败：模型不存在")
    #expect(RecordingStartupFailureMessage.captureStart(source: .microphone, detail: "没有可用麦克风输入设备") == "录音未开始：麦克风采集启动失败：没有可用麦克风输入设备")
    #expect(RecordingStartupFailureMessage.captureStart(source: .screenAudio, detail: "屏幕录制权限未授权") == "录音未开始：电脑音频采集启动失败：屏幕录制权限未授权")
    #expect(RecordingStartupFailureMessage.captureStart(source: .mixed, detail: "屏幕音频失败") == "录音未开始：麦克风+电脑音频采集启动失败：屏幕音频失败")
}
