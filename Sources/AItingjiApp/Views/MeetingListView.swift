import AItingjiCore
import SwiftUI

struct MeetingListView: View {
    @Environment(AppState.self) private var appState
    @SceneStorage("meetingListSearchText") private var searchText = ""

    let highlightedMeetingID: Meeting.ID?
    let onSelectMeeting: (Meeting.ID) -> Void
    let onArchiveMeeting: (Meeting.ID) -> Void

    var body: some View {
        List {
            ForEach(filteredMeetings) { meeting in
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
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            if filteredMeetings.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "暂无会议" : "没有匹配的会议",
                    systemImage: searchText.isEmpty ? "calendar" : "magnifyingglass",
                    description: searchText.isEmpty ? nil : Text("尝试搜索会议标题或状态")
                )
                .listRowBackground(Color.clear)
            }

            if searchText.isEmpty && appState.visibleMeetings.count < appState.unarchivedMeetingCount {
                Button("加载更多") {
                    appState.loadMoreMeetings()
                }
                .disabled(!appState.isPersistenceAvailable)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索会议")
    }

    private var filteredMeetings: [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.visibleMeetings }
        return appState.visibleMeetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.status.displayName.localizedCaseInsensitiveContains(query)
                || meeting.captureSource.displayName.localizedCaseInsensitiveContains(query)
        }
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
                .frame(width: AppLayoutMetrics.Sidebar.iconSlotWidth, height: 24)

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: AppLayoutMetrics.Sidebar.meetingContentSpacing) {
                    Text(meeting.title)
                        .font(AppTypography.meetingTitle)
                        .lineLimit(2)
                        .lineSpacing(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Text(listTime)
                        Text("·")
                        Text("\(meeting.status.displayName) · \(meeting.captureSource.displayName)")
                    }
                        .font(AppTypography.meetingMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(meeting.title)
            .accessibilityLabel("会议：\(meeting.title)")

            Button(action: onArchive) {
                Image(systemName: "archivebox")
                    .frame(
                        width: AppLayoutMetrics.Sidebar.archiveButtonSize,
                        height: AppLayoutMetrics.Sidebar.archiveButtonSize
                    )
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
        .padding(.horizontal, AppLayoutMetrics.Sidebar.horizontalPadding)
        .padding(.vertical, AppLayoutMetrics.Sidebar.meetingRowVerticalPadding)
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
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("打开会议", systemImage: "arrow.right.circle")
            }

            Divider()

            Button {
                onArchive()
            } label: {
                Label("归档会议", systemImage: "archivebox")
            }
            .disabled(isMutationLocked)
        }
    }

    @ViewBuilder
    private var activityIndicator: some View {
        let presentation = MeetingRecordIconPresentation(activity: activity)
        Image(systemName: presentation.systemImage)
            .font(AppTypography.meetingIcon)
            .foregroundStyle(iconColor(for: presentation))
            .frame(width: AppLayoutMetrics.Sidebar.iconSlotWidth, height: 24)
            .symbolEffect(.pulse, options: .repeating, isActive: presentation.isPulsing)
            .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func iconColor(for presentation: MeetingRecordIconPresentation) -> Color {
        switch presentation {
        case .standard: .secondary
        case .recording: .red
        case .processing: .blue
        case .recentlyCompleted: .accentColor
        }
    }

    private var listTime: String {
        (meeting.startedAt ?? meeting.createdAt).formatted(
            Date.FormatStyle.dateTime.year().month().day().hour().minute()
        )
    }
}
