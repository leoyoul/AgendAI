import Foundation

public struct FinalTrackTranscriptionInput: Equatable, Sendable {
    public var track: AudioCaptureTrack
    public var audioFilePath: String

    public init(track: AudioCaptureTrack, audioFilePath: String) {
        self.track = track
        self.audioFilePath = audioFilePath
    }
}

public enum FinalTrackTranscriptionPlan {
    /// 双轨齐全时绝不再使用混合轨转写；缺少任一轨时才回退到完整录音。
    public static func inputs(for meeting: Meeting, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [FinalTrackTranscriptionInput] {
        let separateTracks = [
            (AudioCaptureTrack.microphone, meeting.microphoneAudioFilePath),
            (AudioCaptureTrack.computer, meeting.computerAudioFilePath)
        ].compactMap { track, path -> FinalTrackTranscriptionInput? in
            guard let path, fileExists(path) else { return nil }
            return FinalTrackTranscriptionInput(track: track, audioFilePath: path)
        }
        if separateTracks.count == 2 {
            return separateTracks
        }
        guard let path = meeting.audioFilePath, fileExists(path) else {
            return separateTracks
        }
        return [FinalTrackTranscriptionInput(track: .mixed, audioFilePath: path)]
    }
}
