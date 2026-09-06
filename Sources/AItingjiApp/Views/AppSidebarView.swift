import AItingjiCore
import SwiftUI

struct AppSidebarView: View {
    @Environment(AppState.self) private var appState
    @Bindable var updateCoordinator: AppUpdateCoordinator

    let selectedDestination: WorkspaceDestination
    let onSelectDestination: (WorkspaceDestination) -> Void
    let onSelectMeeting: (Meeting.ID) -> Void
    let onCreateMeeting: () -> Void
    let onArchiveMeeting: (Meeting.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                updateCoordinator.checkForUpdatesManually(log: appState.recordUpdateLog)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("会小纪")
                        .font(.title2.bold())
                        .foregroundStyle(updateCoordinator.brandState.hasUpdate ? .orange : .primary)
                    Text(updateCoordinator.brandState.versionLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(updateCoordinator.brandState.hasUpdate ? .orange : .secondary)
                        .frame(height: 16, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(updateCoordinator.isChecking || updateCoordinator.installationPromptRequired || !updateCoordinator.updatesAreEnabled)
            .help("检查更新")
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                Button {
                    onCreateMeeting()
                } label: {
                    Label("新建会议", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!appState.isPersistenceAvailable)

                ForEach(WorkspaceDestination.sidebarDestinations) { destination in
                    Button {
                        onSelectDestination(destination)
                    } label: {
                        Label(destination.title, systemImage: destination.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedDestination == destination
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
            }
            .padding(.horizontal, 8)

            Divider()
                .padding(.top, 10)

            Text("会议记录")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            MeetingListView(
                highlightedMeetingID: selectedDestination.meetingID,
                onSelectMeeting: onSelectMeeting,
                onArchiveMeeting: onArchiveMeeting
            )
        }
        .background(.regularMaterial)
    }

}
