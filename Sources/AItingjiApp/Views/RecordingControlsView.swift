import AItingjiCore
import AppKit
import SwiftUI

struct RecordingControlsView: View {
    @Environment(AppState.self) private var appState
    let meetingID: Meeting.ID

    var body: some View {
        @Bindable var appState = appState
        let isCurrentRecording = appState.isMeetingRecording(meetingID)
        let isAnotherMeetingRecording = appState.hasActiveRecording && !isCurrentRecording
        let control = RecordingControlPresentation(
            state: isAnotherMeetingRecording ? .idle : appState.recordingStartupState
        )
        let isContentLocked = appState.isMeetingContentLocked(meetingID)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("录音控制", systemImage: "waveform")
                    .font(.title2.bold())
                Text(control.statusText)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(for: control.state).opacity(0.12), in: Capsule())
                    .foregroundStyle(statusColor(for: control.state))
                Spacer()
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let error = appState.recordingStartupError {
                RecordingStartupErrorCard(
                    message: error,
                    canSwitchToMicrophone: appState.canSwitchFailedStartToMicrophone,
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    },
                    onSwitchToMicrophone: {
                        appState.switchFailedStartToMicrophone()
                    }
                )
            }

            if isAnotherMeetingRecording {
                Label("另一场会议正在录音；可继续查看和导出当前会议。", systemImage: "record.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Picker("采集来源", selection: $appState.selectedCaptureSource) {
                        ForEach(CaptureSource.recordingPickerSources, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .onChange(of: appState.selectedCaptureSource) { _, newValue in
                        appState.updateSelectedCaptureSource(newValue)
                    }
                    .frame(width: 260)
                    .disabled(isContentLocked || !appState.isPersistenceAvailable || appState.hasActiveRecording)

                    if selectedSourceIncludesMicrophone {
                        Picker("麦克风", selection: $appState.selectedMicrophoneDeviceID) {
                            ForEach(appState.microphoneDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .onChange(of: appState.selectedMicrophoneDeviceID) { _, newValue in
                            appState.updateSelectedMicrophoneDevice(newValue)
                        }
                        .frame(width: 280)
                        .disabled(
                            appState.microphoneDevices.isEmpty
                                || isContentLocked
                                || !appState.isPersistenceAvailable
                                || appState.hasActiveRecording
                        )

                        Button {
                            appState.refreshMicrophoneDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新麦克风设备")
                        .disabled(isContentLocked || appState.hasActiveRecording)
                    }

                    Spacer()
                }

                if selectedSourceIncludesMicrophone,
                   appState.selectedMicrophoneDevice?.isBluetooth == true {
                    Label("蓝牙麦克风可能让耳机切换到通话模式；建议选择 Mac 内置麦克风。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 12) {
                    Button {
                        appState.startRecordingPreview()
                    } label: {
                        Label(control.primaryActionTitle, systemImage: control.primaryActionSystemImage)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !control.canStartOrResume
                            || isAnotherMeetingRecording
                            || isContentLocked
                            || !appState.isPersistenceAvailable
                            || appState.isCaptureTransitioning
                    )

                    Button {
                        appState.pauseRecordingPreview()
                    } label: {
                        Label("暂停", systemImage: "pause.circle")
                    }
                    .disabled(
                        !isCurrentRecording
                            || !control.canPause
                            || isContentLocked
                            || !appState.isPersistenceAvailable
                            || appState.isCaptureTransitioning
                    )

                    Button {
                        appState.stopRecordingPreview()
                    } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .disabled(
                        !isCurrentRecording
                            || !control.canStop
                            || isContentLocked
                            || !appState.isPersistenceAvailable
                            || appState.isCaptureTransitioning
                    )

                    Button {
                        appState.transcribeMockAudioWithDefaultASR()
                    } label: {
                        Label("模拟转写一次", systemImage: "text.badge.plus")
                    }
                    .disabled(
                        isContentLocked
                            || appState.hasActiveRecording
                            || !appState.isPersistenceAvailable
                            || appState.isCaptureTransitioning
                    )

                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("输入音量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(appState.inputLevel * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: appState.inputLevel)
                    .tint(.green)
            }
        }
        .panelStyle()
    }

    private var selectedSourceIncludesMicrophone: Bool {
        appState.selectedCaptureSource == .microphone || appState.selectedCaptureSource == .mixed
    }

    private func statusColor(for state: RecordingStartupState) -> Color {
        switch state {
        case .idle:
            return .secondary
        case .starting:
            return .orange
        case .recording:
            return .green
        case .paused:
            return .blue
        case .failed:
            return .red
        }
    }
}

private struct RecordingStartupErrorCard: View {
    let message: String
    let canSwitchToMicrophone: Bool
    let onCopy: () -> Void
    let onSwitchToMicrophone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("录音未开始")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button("复制报错", action: onCopy)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                if canSwitchToMicrophone {
                    Button("改用麦克风录制", action: onSwitchToMicrophone)
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }
}
