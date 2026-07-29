import AItingjiCore
import Testing

@Test
func screenRecordingRequestSkipsSystemPromptWhenAlreadyAuthorized() {
    let decision = ScreenRecordingPermissionRequestPolicy.evaluate(status: .authorized)

    #expect(decision == .alreadyAuthorized("屏幕录制已授权，不需要再次授权。"))
}

@Test
func screenRecordingRequestCanPromptWhenPermissionIsMissing() {
    #expect(ScreenRecordingPermissionRequestPolicy.evaluate(status: .denied) == .requestSystemPrompt)
    #expect(ScreenRecordingPermissionRequestPolicy.evaluate(status: .notDetermined) == .requestSystemPrompt)
    #expect(ScreenRecordingPermissionRequestPolicy.evaluate(status: .unknown) == .requestSystemPrompt)
}
