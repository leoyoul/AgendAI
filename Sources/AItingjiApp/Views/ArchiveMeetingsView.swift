import AItingjiCore
import SwiftUI

struct ArchiveMeetingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMeetingIDs: Set<Meeting.ID> = []
    @State private var showsDeleteConfirmation = false

    let onOpenMeeting: (Meeting.ID) -> Void
    let onRestoreMeeting: (Meeting.ID) -> Void
    let onDeleteMeetings: ([Meeting.ID]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.archivedMeetings.isEmpty {
                ContentUnavailableView("暂无归档会议", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.archivedMeetings) { meeting in
                    archiveRow(meeting)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "删除所选会议？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedMeetingIDs.count) 场会议", role: .destructive) {
                onDeleteMeetings(Array(selectedMeetingIDs))
                selectedMeetingIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会议、转写片段和本地录音将被永久删除。")
        }
        .onChange(of: archivedMeetingIDs) { _, newIDs in
            selectedMeetingIDs.formIntersection(newIDs)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("归档")
                    .font(.title2.bold())
                Text("\(appState.archivedMeetings.count) 场会议")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if allArchivedSelected {
                    selectedMeetingIDs.removeAll()
                } else {
                    selectedMeetingIDs = archivedMeetingIDs
                }
            } label: {
                Label(
                    allArchivedSelected ? "取消全选" : "全选",
                    systemImage: allArchivedSelected
                        ? "checkmark.square.fill"
                        : "checkmark.square"
                )
            }
            .disabled(appState.archivedMeetings.isEmpty)

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("删除所选", systemImage: "trash")
            }
            .disabled(selectedMeetingIDs.isEmpty || isMutationLocked)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func archiveRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { selectedMeetingIDs.contains(meeting.id) },
                    set: { isSelected in
                        if isSelected {
                            selectedMeetingIDs.insert(meeting.id)
                        } else {
                            selectedMeetingIDs.remove(meeting.id)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(meetingTime(meeting))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(meeting.status.displayName) · \(meeting.captureSource.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onRestoreMeeting(meeting.id)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!appState.isPersistenceAvailable)
            .help("恢复会议")

            Button {
                onOpenMeeting(meeting.id)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("查看会议")
        }
        .padding(.vertical, 6)
    }

    private var archivedMeetingIDs: Set<Meeting.ID> {
        Set(appState.archivedMeetings.map(\.id))
    }

    private var allArchivedSelected: Bool {
        !archivedMeetingIDs.isEmpty && selectedMeetingIDs == archivedMeetingIDs
    }

    private var isMutationLocked: Bool {
        !appState.isPersistenceAvailable
            || selectedMeetingIDs.contains(where: appState.isMeetingProtectedFromMutation)
    }

    private func meetingTime(_ meeting: Meeting) -> String {
        (meeting.startedAt ?? meeting.createdAt).formatted(
            Date.FormatStyle.dateTime.year().month().day().hour().minute()
        )
    }
}
