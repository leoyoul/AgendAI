public enum MeetingCollectionPolicy {
    public static func sidebarMeetings(
        from meetings: [Meeting],
        limit: Int
    ) -> [Meeting] {
        Array(
            meetings
                .filter { !$0.isArchived }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(max(0, limit))
        )
    }

    @discardableResult
    public static func setArchived(
        _ meetingID: Meeting.ID,
        isArchived: Bool,
        in meetings: inout [Meeting],
        persist: (Meeting) throws -> Void
    ) throws -> Bool {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return false
        }
        var updatedMeeting = meetings[index]
        guard updatedMeeting.isArchived != isArchived else {
            return false
        }
        updatedMeeting.isArchived = isArchived
        try persist(updatedMeeting)
        meetings[index] = updatedMeeting
        return true
    }

    public static func insert(
        _ meeting: Meeting,
        into meetings: inout [Meeting],
        persist: (Meeting) throws -> Void
    ) throws {
        try persist(meeting)
        meetings.insert(meeting, at: 0)
    }

    public static func insert(
        _ meeting: Meeting,
        into meetings: inout [Meeting],
        selectedMeetingID: inout Meeting.ID?,
        persist: (Meeting) throws -> Void
    ) throws {
        try insert(meeting, into: &meetings, persist: persist)
        selectedMeetingID = meeting.id
    }

    @discardableResult
    public static func remove(
        _ meetingID: Meeting.ID,
        from meetings: inout [Meeting],
        selectedMeetingID: inout Meeting.ID?,
        persist: (Meeting.ID) throws -> Void
    ) throws -> Bool {
        guard let removedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return false
        }

        try persist(meetingID)
        meetings.remove(at: removedIndex)

        let fallbackID: Meeting.ID?
        if meetings.indices.contains(removedIndex) {
            fallbackID = meetings[removedIndex].id
        } else {
            fallbackID = meetings.last?.id
        }
        selectedMeetingID = resolvedSelection(
            currentID: selectedMeetingID,
            allMeetingIDs: Set(meetings.map(\.id)),
            fallbackID: fallbackID
        )
        return true
    }

    public static func resolvedSelection(
        currentID: Meeting.ID?,
        allMeetingIDs: Set<Meeting.ID>
    ) -> Meeting.ID? {
        resolvedSelection(
            currentID: currentID,
            allMeetingIDs: allMeetingIDs,
            fallbackID: nil
        )
    }

    public static func resolvedSelection(
        currentID: Meeting.ID?,
        allMeetingIDs: Set<Meeting.ID>,
        fallbackID: Meeting.ID?
    ) -> Meeting.ID? {
        if let currentID, allMeetingIDs.contains(currentID) {
            return currentID
        }
        if let fallbackID, allMeetingIDs.contains(fallbackID) {
            return fallbackID
        }
        return nil
    }
}
