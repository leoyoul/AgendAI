import AItingjiCore
import SwiftUI

struct PermissionBannerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let guidance = appState.permissionGuidance()
        let requirement = guidance.requirement
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: guidance.canStartCapture ? "checkmark.shield" : "lock.shield")
                .font(.title2)
                .foregroundStyle(guidance.canStartCapture ? .green : .orange)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("权限状态")
                        .font(.headline)
                    Spacer()
                    Button("刷新") {
                        appState.refreshPermissionStatus()
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 8) {
                    if requirement.requiresMicrophone {
                        PermissionStatusPill(title: "麦克风", status: appState.permissionSnapshot.microphone)
                    }
                    if requirement.requiresScreenRecording {
                        PermissionStatusPill(title: "屏幕录制", status: appState.permissionSnapshot.screenRecording)
                    }
                }

                Text(guidance.summary)
                    .font(.subheadline)
                    .foregroundStyle(guidance.canStartCapture ? .secondary : .primary)

                ForEach(guidance.actions, id: \.self) { action in
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !guidance.canStartCapture {
                    HStack(spacing: 10) {
                        if requirement.requiresMicrophone, guidance.missingPermissions.contains(.microphone) {
                            if appState.permissionSnapshot.microphone == .notDetermined {
                                Button("请求麦克风权限") {
                                    appState.requestMicrophonePermission()
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button("打开系统设置 -> 麦克风") {
                                    appState.openPermissionSettings(for: .microphone)
                                }
                            }
                        }

                        if requirement.requiresScreenRecording, guidance.missingPermissions.contains(.screenRecording) {
                            Button("请求屏幕录制权限") {
                                appState.requestScreenRecordingPermission()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("打开系统设置 -> 屏幕录制") {
                                appState.openPermissionSettings(for: .screenRecording)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background((guidance.canStartCapture ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            appState.refreshPermissionStatus()
        }
    }
}

private struct PermissionStatusPill: View {
    let title: String
    let status: CapturePermissionStatus

    var body: some View {
        Text("\(title)：\(status.displayName)")
            .font(.caption.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.14), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

private extension CapturePermissionStatus {
    var displayName: String {
        switch self {
        case .authorized:
            return "已授权"
        case .denied:
            return "未授权"
        case .notDetermined:
            return "未询问"
        case .unknown:
            return "未知"
        }
    }

    var tint: Color {
        switch self {
        case .authorized:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}
