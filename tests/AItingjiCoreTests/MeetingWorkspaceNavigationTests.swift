import AItingjiCore
import Foundation
import Testing

@Suite("Meeting workspace navigation")
struct MeetingWorkspaceNavigationTests {
    private let displayedWeekDate = Date(timeIntervalSince1970: 1_789_000_000)

    @Test("defaults to calendar without a meeting detail")
    func defaultsToCalendar() {
        let navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)

        #expect(navigation.destination == .calendar)
        #expect(navigation.lastNonMeetingDestination == .calendar)
        #expect(navigation.detailMeetingID == nil)
    }

    @Test("opening and leaving a meeting preserves the previous workspace")
    func preservesLastNonMeetingDestination() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        let didSelectModels = navigation.selectDestination(.models)
        let didOpenMeeting = navigation.openMeeting("meeting-1")

        #expect(didSelectModels)
        #expect(didOpenMeeting)
        #expect(navigation.destination == .meeting("meeting-1"))
        #expect(navigation.detailMeetingID == "meeting-1")
        #expect(navigation.lastNonMeetingDestination == .models)

        navigation.detailMeetingID = nil
        #expect(navigation.destination == .models)
        #expect(navigation.displayedWeekDate == displayedWeekDate)
    }

    @Test("opening a meeting from Agent settings returns to Agent settings")
    func agentSettingsReturnsAfterMeeting() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        _ = navigation.selectDestination(.agentSettings)
        _ = navigation.openMeeting("meeting-from-agent-settings")

        navigation.detailMeetingID = nil

        #expect(navigation.destination == .agentSettings)
        #expect(navigation.lastNonMeetingDestination == .agentSettings)
    }

    @Test("opening an archived meeting returns to archive")
    func archivedMeetingReturnsToArchive() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        let didSelectArchive = navigation.selectDestination(.archive)
        let didOpenMeeting = navigation.openMeeting("archived")
        #expect(didSelectArchive)
        #expect(didOpenMeeting)
        #expect(navigation.lastNonMeetingDestination == .archive)

        navigation.detailMeetingID = nil

        #expect(navigation.destination == .archive)
        #expect(navigation.detailMeetingID == nil)
    }

    @Test("returning to calendar keeps the displayed week")
    func returnsToCalendarWithoutChangingWeek() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        _ = navigation.openMeeting("meeting-1")

        navigation.returnToCalendar()

        #expect(navigation.destination == .calendar)
        #expect(navigation.detailMeetingID == nil)
        #expect(navigation.displayedWeekDate == displayedWeekDate)
    }

    @Test("recording does not prevent switching workspaces or meetings")
    func allowsConcurrentNavigation() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        _ = navigation.openMeeting("current")

        let didSelectModels = navigation.selectDestination(.models)
        let didOpenOther = navigation.openMeeting("other")

        #expect(didSelectModels)
        #expect(didOpenOther)
        #expect(navigation.destination == .meeting("other"))
        navigation.returnToCalendar()
        #expect(navigation.destination == .calendar)
    }

    @Test("create opens the new meeting and deleting it returns to calendar")
    func createAndDeleteCurrentMeeting() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        _ = navigation.selectDestination(.models)

        navigation.didCreateMeeting("new")
        #expect(navigation.destination == .meeting("new"))

        navigation.didDeleteMeeting("new")
        #expect(navigation.destination == .calendar)
        #expect(navigation.lastNonMeetingDestination == .calendar)
        #expect(navigation.detailMeetingID == nil)
    }

    @Test("deleting another meeting does not change the destination")
    func deletingAnotherMeetingDoesNotNavigate() {
        var navigation = MeetingWorkspaceNavigation(displayedWeekDate: displayedWeekDate)
        _ = navigation.openMeeting("current")

        navigation.didDeleteMeeting("other")

        #expect(navigation.destination == .meeting("current"))
    }
}
