import AItingjiCore
import SwiftUI

struct MeetingListView: View {
    @Environment(AppState.self) private var appState

    let highlightedMeetingID: Meeting.ID?
    let onSelectMeeting: (Meeting.ID) -> Void
    let onArchiveMeeting: (Meeting.ID) -> Void

    var body: some View {
        List {
            ForEach(appState.visibleMeetings) { meeting in
                MeetingSidebarRow(
                    meeting: meeting,
                    isHighlighted: meeting.id == highlightedMeetingID,
                    activity: MeetingSidebarActivityPresentation(
                        isRecording: appState.isMeetingRecording(meeting.id),
                        isPostprocessing: appState.isMeetingMinutesActive(meeting.id),
                        isRecentlyCompleted: appState.recentlyCompletedMeetingIDs.contains(meeting.id)
                    ),
                    isMutationLocked: appState.isMeetingProtectedFromMutation(meeting.id)
                        || !appState.isPersistenceAvailable,
                    onSelect: { onSelectMeeting(meeting.id) },
                    onArchive: { onArchiveMeeting(meeting.id) }
                )
                .listRowBackground(
                    meeting.id == highlightedMeetingID
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
            }

            if appState.visibleMeetings.isEmpty {
                Text("暂无会议")
                    .foregroundStyle(.secondary)
            }

            if appState.visibleMeetings.count < appState.unarchivedMeetingCount {
                Button("加载更多") {
                    appState.loadMoreMeetings()
                }
                .disabled(!appState.isPersistenceAvailable)
            }
        }
        .listStyle(.sidebar)
    }

}

private struct MeetingSidebarRow: View {
    let meeting: Meeting
    let isHighlighted: Bool
    let activity: MeetingSidebarActivityPresentation
    let isMutationLocked: Bool
    let onSelect: () -> Void
    let onArchive: () -> Void

    @State private var isHovering = false
    @State private var showsArchiveButton = false
    @State private var hoverGeneration = UUID()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            activityIndicator
                .frame(width: 14, height: 24)

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(listTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(meeting.status.displayName) · \(meeting.captureSource.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onArchive) {
                Image(systemName: "archivebox")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .opacity(showsArchiveButton ? 1 : 0)
            .allowsHitTesting(showsArchiveButton)
            .accessibilityHidden(!showsArchiveButton)
            .disabled(isMutationLocked)
            .help("归档会议")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovering = hovering
            let generation = UUID()
            hoverGeneration = generation
            if hovering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard hoverGeneration == generation, isHovering else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        showsArchiveButton = true
                    }
                }
            } else {
                showsArchiveButton = false
            }
        }
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch activity {
        case .recording:
            Image(systemName: "record.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityLabel("正在录音")
        case .postprocessing:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("会议纪要排队或生成中")
        case .recentlyCompleted:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("会议纪要已生成")
        case .none:
            Color.clear
        }
    }

    private var listTime: String {
        (meeting.startedAt ?? meeting.createdAt).formatted(
            Date.FormatStyle.dateTime.year().month().day().hour().minute()
        )
    }
}
