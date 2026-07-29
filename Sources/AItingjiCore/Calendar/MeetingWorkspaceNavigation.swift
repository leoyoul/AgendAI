import Foundation

public enum WorkspaceDestination: Equatable, Hashable, Sendable {
    case calendar
    case agentSettings
    case models
    case vocabulary
    case people
    case knowledgeBase
    case archive
    case debugLog
    case meeting(Meeting.ID)

    public static var model: Self { .models }

    public var meetingID: Meeting.ID? {
        guard case .meeting(let meetingID) = self else {
            return nil
        }
        return meetingID
    }
}

public struct MeetingWorkspaceNavigation: Equatable, Sendable {
    public var destination: WorkspaceDestination
    public var lastNonMeetingDestination: WorkspaceDestination
    public var displayedWeekDate: Date

    public var detailMeetingID: Meeting.ID? {
        get { destination.meetingID }
        set {
            if let newValue {
                rememberCurrentNonMeetingDestination()
                destination = .meeting(newValue)
            } else if destination.meetingID != nil {
                destination = lastNonMeetingDestination
            }
        }
    }

    public init(displayedWeekDate: Date) {
        destination = .calendar
        lastNonMeetingDestination = .calendar
        self.displayedWeekDate = displayedWeekDate
    }

    @discardableResult
    public mutating func selectDestination(_ destination: WorkspaceDestination) -> Bool {
        if destination.meetingID == nil {
            lastNonMeetingDestination = destination
        }
        self.destination = destination
        return true
    }

    @discardableResult
    public mutating func openMeeting(
        _ meetingID: Meeting.ID
    ) -> Bool {
        rememberCurrentNonMeetingDestination()
        destination = .meeting(meetingID)
        return true
    }

    public mutating func didCreateMeeting(_ meetingID: Meeting.ID) {
        rememberCurrentNonMeetingDestination()
        destination = .meeting(meetingID)
    }

    public mutating func didDeleteMeeting(_ meetingID: Meeting.ID) {
        guard detailMeetingID == meetingID else {
            return
        }
        destination = .calendar
        lastNonMeetingDestination = .calendar
    }

    public mutating func returnToCalendar() {
        destination = .calendar
        lastNonMeetingDestination = .calendar
    }

    private mutating func rememberCurrentNonMeetingDestination() {
        if destination.meetingID == nil {
            lastNonMeetingDestination = destination
        }
    }
}
