import AItingjiCore
import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Bindable var updateCoordinator: AppUpdateCoordinator
    @State private var navigation = MeetingWorkspaceNavigation(displayedWeekDate: Date())
    @State private var settingsSelection: WorkspaceDestination = .agentSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didRestoreSidebar = false
    @State private var didApplyLaunchDefaults = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if navigation.destination == .settings {
                SettingsSidebarView(selection: $settingsSelection, onReturn: returnFromSettings)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
            } else {
                AppSidebarView(
                    updateCoordinator: updateCoordinator,
                    selectedDestination: navigation.destination,
                    onSelectDestination: selectDestination,
                    onSelectMeeting: openMeeting,
                    onCreateMeeting: createMeeting,
                    onArchiveMeeting: archiveMeeting
                )
                .navigationSplitViewColumnWidth(min: 232, ideal: 252, max: 280)
            }
        } detail: {
            if navigation.destination == .settings {
                settingsDetail
            } else {
                MeetingWorkspaceView(
                    navigation: $navigation,
                    onSelectMeeting: openMeeting
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(TransparentWindowToolbarModifier())
        .onChange(of: navigation.detailMeetingID, initial: true) { _, meetingID in
            guard let meetingID else { return }
            _ = appState.selectMeeting(meetingID)
        }
        .onAppear {
            applyLaunchDefaultsIfNeeded()
            guard !didRestoreSidebar else { return }
            columnVisibility = .all
            didRestoreSidebar = true
        }
        .task {
            updateCoordinator.start(log: appState.recordUpdateLog)
        }
        .alert("请将会小纪安装到“应用程序”", isPresented: $updateCoordinator.showInstallationPrompt) {
            Button("打开应用程序文件夹") {
                updateCoordinator.revealCurrentAppAndApplications()
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("将会小纪拖到“应用程序”并选择“替换”后，即可接收应用内更新。会议和账户数据不会被替换。")
        }
    }

    private func applyLaunchDefaultsIfNeeded() {
        guard !didApplyLaunchDefaults else { return }
        navigation.resetToLaunchDefaults(today: Date())
        didApplyLaunchDefaults = true
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch settingsSelection {
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
                onOpenMeeting: openArchivedMeeting,
                onRestoreMeeting: restoreMeeting,
                onDeleteMeetings: deleteMeetings
            )
        case .debugLog:
            DebugLogView()
        case .externalSystems:
            ExternalSystemsSettingsView()
        case .calendar, .meeting, .settings:
            EmptyView()
        case .workItemPool:
            EmptyView()
        }
    }

    private func selectDestination(_ destination: WorkspaceDestination) {
        if destination == .settings {
            navigation.enterSettings()
        } else {
            _ = navigation.selectDestination(destination)
        }
    }

    private func returnFromSettings() {
        if let meetingID = navigation.settingsReturnDestination.meetingID,
           !appState.meetings.contains(where: { $0.id == meetingID }) {
            navigation.returnToCalendar()
        } else {
            navigation.leaveSettings()
        }
    }

    private func openArchivedMeeting(_ meetingID: Meeting.ID) {
        navigation.returnToCalendar()
        openMeeting(meetingID)
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

private struct TransparentWindowToolbarModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
                .background(WindowToolbarConfigurator())
        }
    }
}

private struct WindowToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarWindowProbe {
        ToolbarWindowProbe()
    }

    func updateNSView(_ nsView: ToolbarWindowProbe, context: Context) {
        nsView.configureWindowIfAvailable()
    }
}

private final class ToolbarWindowProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfAvailable()
    }

    func configureWindowIfAvailable() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.toolbar?.showsBaselineSeparator = false
    }
}
