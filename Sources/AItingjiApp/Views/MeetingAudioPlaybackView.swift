import AItingjiCore
import AppKit
import AVFoundation
import Combine
import SwiftUI

struct MeetingAudioPlaybackView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    @StateObject private var player = MeetingAudioPlaybackController()
    @State private var showingStopConfirmation = false

    var body: some View {
        let files = audioFiles(for: meeting)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("录音回放", systemImage: "waveform.circle")
                    .font(.title2.bold())
                Spacer()
                if let error = player.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if appState.isRecordingRetranscriptionSelectedMeeting {
                    Button(role: .destructive) {
                        showingStopConfirmation = true
                    } label: {
                        Label("停止重新转写", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        appState.retranscribeSelectedMeetingFromRecording()
                    } label: {
                        Label("按原始轨重新转写", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(
                        meeting.audioFilePath == nil
                            || appState.isPostprocessingSelectedMeeting
                            || appState.hasActiveRecording
                            || !appState.isPersistenceAvailable
                            || appState.isCaptureTransitioning
                    )
                }
            }

            if files.isEmpty {
                ContentUnavailableView("暂无录音文件", systemImage: "waveform.slash")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 10) {
                    ForEach(files) { file in
                        MeetingAudioFileRow(file: file, meetingTitle: meeting.title, player: player)
                    }
                }
            }
        }
        .panelStyle()
        .onChange(of: meeting.id) { _, _ in
            player.stop()
        }
        .onDisappear {
            player.stop()
        }
        .confirmationDialog(
            "停止录音重新转写？",
            isPresented: $showingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("停止重新转写", role: .destructive) {
                appState.stopSelectedRecordingRetranscription()
            }
            Button("继续转写", role: .cancel) {}
        } message: {
            Text("停止后会保留已经生成的转写片段，未处理的录音不会继续识别。")
        }
    }

    private func audioFiles(for meeting: Meeting) -> [MeetingAudioFile] {
        [
            makeFile(id: "mixed", title: "完整录音", systemImage: "waveform", path: meeting.audioFilePath),
            makeFile(id: "microphone", title: "麦克风轨", systemImage: "mic", path: meeting.microphoneAudioFilePath),
            makeFile(id: "computer", title: "电脑音频轨", systemImage: "speaker.wave.2", path: meeting.computerAudioFilePath)
        ].compactMap { $0 }
    }

    private func makeFile(id: String, title: String, systemImage: String, path: String?) -> MeetingAudioFile? {
        guard let path, !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? NSNumber
        let durationMs = try? WAVAudioSegmentReader.durationMs(from: url)
        return MeetingAudioFile(
            id: "\(id)-\(path)",
            title: title,
            systemImage: systemImage,
            url: url,
            exists: FileManager.default.fileExists(atPath: path),
            byteCount: size?.int64Value,
            duration: durationMs.map { TimeInterval($0) / 1_000 }
        )
    }
}

private struct MeetingAudioFileRow: View {
    @Environment(AppState.self) private var appState
    let file: MeetingAudioFile
    let meetingTitle: String
    @ObservedObject var player: MeetingAudioPlaybackController

    var body: some View {
        let isCurrent = player.currentFileID == file.id
        let duration = isCurrent ? player.duration : (file.duration ?? 0)
        let currentTime = isCurrent ? player.currentTime : 0

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Label(file.title, systemImage: file.systemImage)
                    .font(.headline)
                Text(file.exists ? file.summary : "文件不存在")
                    .font(.caption)
                    .foregroundStyle(file.exists ? Color.secondary : Color.red)
                Spacer()
                Button {
                    player.toggle(file)
                } label: {
                    Label(player.actionTitle(for: file), systemImage: player.actionIcon(for: file))
                }
                .disabled(!file.exists)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                } label: {
                    Label("显示", systemImage: "folder")
                }
                .disabled(!file.exists)

                Button {
                    appState.exportMeetingAudioFile(
                        url: file.url,
                        title: file.title,
                        meetingTitle: meetingTitle
                    )
                } label: {
                    Label("导出", systemImage: "square.and.arrow.down")
                }
                .disabled(!file.exists)
            }

            HStack(spacing: 10) {
                Text(formatTime(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { isCurrent ? player.currentTime : 0 },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(duration, 0.01)
                )
                .disabled(!file.exists || !isCurrent)
                Text(formatTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
            }

            Text(file.url.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "00:00"
        }
        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

fileprivate struct MeetingAudioFile: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let url: URL
    let exists: Bool
    let byteCount: Int64?
    let duration: TimeInterval?

    var summary: String {
        [durationText, sizeText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var durationText: String? {
        guard let duration else {
            return nil
        }
        let totalSeconds = Int(duration.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var sizeText: String? {
        guard let byteCount else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

@MainActor
fileprivate final class MeetingAudioPlaybackController: ObservableObject {
    @Published private(set) var currentFileID: String?
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ file: MeetingAudioFile) {
        if currentFileID != file.id || audioPlayer == nil {
            load(file)
        }
        guard let audioPlayer else {
            return
        }
        if audioPlayer.isPlaying {
            pause()
        } else {
            errorMessage = nil
            audioPlayer.play()
            isPlaying = true
            startTimer()
        }
    }

    func actionTitle(for file: MeetingAudioFile) -> String {
        currentFileID == file.id && isPlaying ? "暂停" : "播放"
    }

    func actionIcon(for file: MeetingAudioFile) -> String {
        currentFileID == file.id && isPlaying ? "pause.circle" : "play.circle"
    }

    func seek(to time: TimeInterval) {
        guard let audioPlayer else {
            return
        }
        let nextTime = min(max(0, time), audioPlayer.duration)
        audioPlayer.currentTime = nextTime
        currentTime = nextTime
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentFileID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func load(_ file: MeetingAudioFile) {
        stop()
        do {
            let nextPlayer = try AVAudioPlayer(contentsOf: file.url)
            nextPlayer.prepareToPlay()
            audioPlayer = nextPlayer
            currentFileID = file.id
            currentTime = 0
            duration = nextPlayer.duration
            errorMessage = nil
        } catch {
            errorMessage = "录音打开失败：\(error.localizedDescription)"
        }
    }

    private func pause() {
        audioPlayer?.pause()
        isPlaying = false
        syncProgress()
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncProgress()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func syncProgress() {
        guard let audioPlayer else {
            return
        }
        currentTime = audioPlayer.currentTime
        duration = audioPlayer.duration
        if isPlaying && !audioPlayer.isPlaying {
            isPlaying = false
            currentTime = min(audioPlayer.duration, audioPlayer.currentTime)
            stopTimer()
        }
    }
}
