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
                        .font(AppTypography.brand)
                        .foregroundStyle(updateCoordinator.brandState.hasUpdate ? .orange : .primary)
                    Text(updateCoordinator.brandState.versionLabel)
                        .font(AppTypography.brandVersion)
                        .foregroundStyle(updateCoordinator.brandState.hasUpdate ? .orange : .secondary)
                        .frame(height: 16, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(updateCoordinator.isChecking || updateCoordinator.installationPromptRequired || !updateCoordinator.updatesAreEnabled)
            .help("检查更新")
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            SidebarNavigationGroup(
                selectedDestination: selectedDestination,
                pendingWorkItemCount: appState.pendingConfirmationWorkItems.count,
                isPersistenceAvailable: appState.isPersistenceAvailable,
                onSelectDestination: onSelectDestination,
                onCreateMeeting: onCreateMeeting
            )

            Divider()
                .padding(.top, 8)

            Text("会议记录")
                .font(AppTypography.section)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppLayoutMetrics.Sidebar.horizontalPadding + 2)
                .padding(.top, 12)
                .padding(.bottom, 4)

            MeetingListView(
                highlightedMeetingID: selectedDestination.meetingID,
                onSelectMeeting: onSelectMeeting,
                onArchiveMeeting: onArchiveMeeting
            )
        }
    }

}
