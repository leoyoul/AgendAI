import AItingjiCore
import SwiftUI

struct MeetingStatusBadge: View {
    let status: MeetingStatus

    private var tint: Color {
        switch status {
        case .recording:
            .red
        case .paused:
            .orange
        case .processing, .permissionChecking:
            .blue
        case .done:
            .green
        case .failed:
            .red
        case .draft:
            .secondary
        }
    }

    private var systemImage: String {
        switch status {
        case .recording:
            "record.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .processing, .permissionChecking:
            "clock.arrow.circlepath"
        case .done:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        case .draft:
            "circle.dashed"
        }
    }

    var body: some View {
        Label(status.displayName, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.24), lineWidth: 1)
            }
            .symbolEffect(.pulse, options: .repeating, isActive: status == .recording)
            .accessibilityLabel("会议状态：\(status.displayName)")
    }
}
