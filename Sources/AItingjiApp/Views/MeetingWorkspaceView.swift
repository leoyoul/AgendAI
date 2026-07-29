import AItingjiCore
import SwiftUI

struct MeetingWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Binding var navigation: MeetingWorkspaceNavigation
    let onSelectMeeting: (Meeting.ID) -> Void

    var body: some View {
        Group {
            if let meetingID = navigation.detailMeetingID,
               let meeting = appState.meetings.first(where: { $0.id == meetingID }) {
                MeetingDetailView(meeting: meeting, onOpenMeeting: onSelectMeeting)
                    .id(meeting.id)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                _ = navigation.selectDestination(returnDestination)
                            } label: {
                                Label(returnTitle, systemImage: "chevron.left")
                            }
                        }
                    }
            } else {
                WeekCalendarView(
                    meetings: appState.meetings,
                    activeMeetingID: appState.calendarActiveMeetingID,
                    displayedWeekDate: $navigation.displayedWeekDate,
                    onSelectMeeting: onSelectMeeting
                )
            }
        }
    }

    private var returnDestination: WorkspaceDestination {
        navigation.lastNonMeetingDestination.meetingID == nil
            ? navigation.lastNonMeetingDestination
            : .calendar
    }

    private var returnTitle: String {
        switch returnDestination {
        case .calendar:
            "本周会议"
        case .agentSettings, .models, .knowledgeBase, .vocabulary, .people, .archive, .debugLog:
            "返回\(returnDestination.title)"
        case .meeting:
            "本周会议"
        }
    }
}
