import AItingjiCore
import Testing

@Test
func microphoneCaptureRequiresOnlyMicrophonePermission() {
    let requirement = CapturePermissionRequirement(source: .microphone)

    #expect(requirement.requiresMicrophone)
    #expect(!requirement.requiresScreenRecording)
}

@Test
func computerAudioCaptureRequiresOnlyScreenRecordingPermission() {
    for source in [CaptureSource.screenAudio, .systemAudio, .appAudio] {
        let requirement = CapturePermissionRequirement(source: source)

        #expect(!requirement.requiresMicrophone)
        #expect(requirement.requiresScreenRecording)
    }
}

@Test
func mixedCaptureRequiresMicrophoneAndScreenRecordingPermission() {
    let requirement = CapturePermissionRequirement(source: .mixed)

    #expect(requirement.requiresMicrophone)
    #expect(requirement.requiresScreenRecording)
}

@Test
func permissionGuidanceExplainsMissingMicrophoneAccess() {
    let guidance = CapturePermissionGuidance(
        requirement: CapturePermissionRequirement(source: .microphone),
        microphone: .denied,
        screenRecording: .authorized
    )

    #expect(!guidance.canStartCapture)
    #expect(guidance.missingPermissions == [.microphone])
    #expect(guidance.summary == "请先授权麦克风。")
    #expect(guidance.actions.contains("打开系统设置 -> 隐私与安全性 -> 麦克风，允许会小纪使用麦克风。"))
}

@Test
func permissionGuidanceExplainsMissingScreenRecordingAccessAndRestart() {
    let guidance = CapturePermissionGuidance(
        requirement: CapturePermissionRequirement(source: .screenAudio),
        microphone: .authorized,
        screenRecording: .denied
    )

    #expect(!guidance.canStartCapture)
    #expect(guidance.missingPermissions == [.screenRecording])
    #expect(guidance.summary == "请先授权屏幕录制。")
    #expect(guidance.actions.contains("打开系统设置 -> 隐私与安全性 -> 屏幕录制，允许会小纪采集电脑音频。"))
    #expect(guidance.actions.contains("授权后请退出并重新打开会小纪。"))
}

@Test
func permissionGuidanceAllowsCaptureWhenRequiredPermissionsAuthorized() {
    let guidance = CapturePermissionGuidance(
        requirement: CapturePermissionRequirement(source: .mixed),
        microphone: .authorized,
        screenRecording: .authorized
    )

    #expect(guidance.canStartCapture)
    #expect(guidance.missingPermissions.isEmpty)
    #expect(guidance.summary == "录音权限已就绪。")
}
