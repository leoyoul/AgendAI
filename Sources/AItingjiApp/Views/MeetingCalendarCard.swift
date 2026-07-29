import AItingjiCore
import SwiftUI

struct MeetingCalendarCard: View {
    let meeting: Meeting
    let item: MeetingCalendarLayoutItem
    let date: Date
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(statusColor)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if item.continuesFromPreviousDay {
                            Image(systemName: "arrow.left")
                                .font(.caption2)
                        }
                        Text(meeting.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        if item.continuesIntoNextDay {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                        }
                    }

                    Text(timeText)
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)

                    if let statusText {
                        Text(statusText)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(statusColor.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(statusColor.opacity(0.38), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(meeting.title)
        .accessibilityLabel(accessibilityText)
    }

    private var timeText: String {
        if item.continuesFromPreviousDay,
           let startedAt = meeting.startedAt {
            return "续接 · \(startedAt.formatted(.dateTime.month().day().hour().minute()))"
        }

        let start = minuteText(item.startMinute)
        if meeting.endedAt == nil,
           !item.continuesIntoNextDay,
           meeting.status == .recording {
            return "\(start)-进行中"
        }
        return "\(start)-\(minuteText(item.endMinute))"
    }

    private var statusText: String? {
        if meeting.isArchived {
            return "已归档"
        }
        switch meeting.status {
        case .recording, .paused, .processing, .failed:
            return meeting.status.displayName
        default:
            return nil
        }
    }

    private var statusColor: Color {
        if meeting.isArchived {
            return .green
        }
        switch meeting.status {
        case .recording:
            return .red
        case .paused:
            return .orange
        case .processing, .permissionChecking:
            return .blue
        case .failed:
            return .red
        case .done:
            return .green
        case .draft:
            return .secondary
        }
    }

    private var accessibilityText: String {
        let dateText = date.formatted(.dateTime.year().month().day())
        let status = statusText.map { "，\($0)" } ?? ""
        let segmentText = "\(minuteText(item.startMinute))-\(minuteText(item.endMinute))"
        let originalStartText = meeting.startedAt?.formatted(.dateTime.year().month().day().hour().minute()) ?? "此前"
        let continuation = item.continuesFromPreviousDay
            ? "，续接自\(originalStartText)"
            : ""
        return "\(meeting.title)，\(dateText)，\(timeText)，本段\(segmentText)\(continuation)\(status)"
    }

    private func minuteText(_ minute: Int) -> String {
        let clamped = min(24 * 60, max(0, minute))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
