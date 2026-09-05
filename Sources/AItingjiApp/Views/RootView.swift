import AItingjiCore
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Bindable var updateCoordinator: AppUpdateCoordinator
    @State private var navigation = MeetingWorkspaceNavigation(displayedWeekDate: Date())

    var body: some View {
        NavigationSplitView {
            AppSidebarView(
                selectedDestination: navigation.destination,
                onSelectDestination: selectDestination,
                onSelectMeeting: openMeeting,
                onCreateMeeting: createMeeting,
                onArchiveMeeting: archiveMeeting
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            switch navigation.destination {
            case .calendar, .meeting:
                MeetingWorkspaceView(
                    navigation: $navigation,
                    onSelectMeeting: openMeeting
                )
            case .models:
                ModelSettingsView()
            case .agentSettings:
                AgentSettingsView()
            case .knowledgeBase:
                KnowledgeBaseSettingsView()
            case .vocabulary:
                VocabularyView()
            case .people:
                PeopleView()
            case .archive:
                ArchiveMeetingsView(
                    onOpenMeeting: openMeeting,
                    onRestoreMeeting: restoreMeeting,
                    onDeleteMeetings: deleteMeetings
                )
            case .debugLog:
                DebugLogView()
            }
        }
        .onChange(of: navigation.detailMeetingID, initial: true) { _, meetingID in
            guard let meetingID else { return }
            _ = appState.selectMeeting(meetingID)
        }
        .task {
            await updateCoordinator.checkAutomatically(log: appState.recordUpdateLog)
        }
        .alert(item: $updateCoordinator.notice) { notice in
            alert(for: notice)
        }
    }

    private func alert(for notice: AppUpdateNotice) -> Alert {
        switch notice {
        case .updateAvailable(let currentVersion, let release):
            Alert(
                title: Text(verbatim: "发现新版本 \(release.version)"),
                message: Text(verbatim: "当前版本为 \(currentVersion)。下载后请退出会小纪，再用新版本替换旧应用；会议和账户数据会继续保留。"),
                primaryButton: .default(Text("前往下载")) {
                    updateCoordinator.openRelease(release, log: appState.recordUpdateLog)
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        case .upToDate(let currentVersion):
            Alert(
                title: Text("已是最新版"),
                message: Text(verbatim: "当前版本为 \(currentVersion)。"),
                dismissButton: .default(Text("好"))
            )
        case .failure(let message):
            Alert(
                title: Text("检查更新失败"),
                message: Text(verbatim: message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func selectDestination(_ destination: WorkspaceDestination) {
        _ = navigation.selectDestination(destination)
    }

    private func openMeeting(_ meetingID: Meeting.ID) {
        guard appState.meetings.contains(where: { $0.id == meetingID }) else { return }
        _ = navigation.openMeeting(meetingID)
        appState.acknowledgeMeetingCompletion(meetingID)
    }

    private func createMeeting() {
        guard let meetingID = appState.createMeeting() else {
            return
        }
        navigation.didCreateMeeting(meetingID)
    }

    private func deleteMeeting(_ meetingID: Meeting.ID) {
        guard appState.deleteMeeting(meetingID) else {
            return
        }
        navigation.didDeleteMeeting(meetingID)
    }

    private func deleteMeetings(_ meetingIDs: [Meeting.ID]) {
        for meetingID in meetingIDs {
            deleteMeeting(meetingID)
        }
    }

    private func archiveMeeting(_ meetingID: Meeting.ID) {
        _ = appState.archiveMeeting(meetingID)
    }

    private func restoreMeeting(_ meetingID: Meeting.ID) {
        _ = appState.restoreMeeting(meetingID)
    }
}
