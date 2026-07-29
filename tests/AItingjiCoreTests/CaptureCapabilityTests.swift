import AItingjiCore
import Testing

@Test
func coreAudioTapCapabilityReportsMinimumMacOS() {
    let capability = CoreAudioTapCapture().capability()

    #expect(capability.minimumMacOS == "14.2")
    #expect(!capability.note.isEmpty)
}

@Test
func permissionServiceCanReadScreenRecordingStatus() {
    let status = PermissionService().screenRecordingStatus()

    #expect([.authorized, .denied].contains(status))
}
