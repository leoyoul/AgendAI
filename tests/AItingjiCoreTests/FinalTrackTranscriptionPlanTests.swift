import AItingjiCore
import Foundation
import Testing

@Test
func finalTrackTranscriptionUsesSeparateTracksWhenBothExist() {
    let meeting = Meeting(
        id: "m1",
        title: "双轨会议",
        createdAt: Date(),
        audioFilePath: "/recording.wav",
        microphoneAudioFilePath: "/microphone.wav",
        computerAudioFilePath: "/computer.wav"
    )

    let inputs = FinalTrackTranscriptionPlan.inputs(for: meeting) { $0 != "/recording.wav" }

    #expect(inputs == [
        FinalTrackTranscriptionInput(track: .microphone, audioFilePath: "/microphone.wav"),
        FinalTrackTranscriptionInput(track: .computer, audioFilePath: "/computer.wav")
    ])
}

@Test
func finalTrackTranscriptionFallsBackToMixedWhenOneTrackIsMissing() {
    let meeting = Meeting(
        id: "m1",
        title: "旧会议",
        createdAt: Date(),
        audioFilePath: "/recording.wav",
        microphoneAudioFilePath: "/microphone.wav"
    )

    let inputs = FinalTrackTranscriptionPlan.inputs(for: meeting) { $0 == "/recording.wav" || $0 == "/microphone.wav" }

    #expect(inputs == [FinalTrackTranscriptionInput(track: .mixed, audioFilePath: "/recording.wav")])
}
