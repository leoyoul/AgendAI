import AItingjiCore
import Foundation
import Testing

@Suite("Meeting collection policy")
struct MeetingCollectionPolicyTests {
    private enum PersistenceError: Error {
        case failed
    }

    @Test("successful creation persists before insertion and selects the meeting")
    func successfulCreationInsertsAndSelects() throws {
        let existing = meeting("existing", createdAt: 1)
        let created = meeting("created", createdAt: 2)
        var meetings = [existing]
        var selectedMeetingID: Meeting.ID? = existing.id
        var persistedID: Meeting.ID?

        try MeetingCollectionPolicy.insert(
            created,
            into: &meetings,
            selectedMeetingID: &selectedMeetingID
        ) { persistedID = $0.id }

        #expect(persistedID == created.id)
        #expect(meetings.map(\.id) == [created.id, existing.id])
        #expect(selectedMeetingID == created.id)
    }

    @Test("sidebar excludes archived meetings before applying pagination")
    func sidebarExcludesArchivedMeetings() {
        var archived = meeting("archived", createdAt: 3)
        archived.isArchived = true
        let visible = MeetingCollectionPolicy.sidebarMeetings(
            from: [meeting("older", createdAt: 1), archived, meeting("newer", createdAt: 2)],
            limit: 1
        )

        #expect(visible.map(\.id) == ["newer"])
    }

    @Test("archiving persists before changing memory")
    func archivingPersistsBeforeMutation() throws {
        var meetings = [meeting("meeting", createdAt: 1)]
        var persistedMeeting: Meeting?

        let changed = try MeetingCollectionPolicy.setArchived(
            "meeting",
            isArchived: true,
            in: &meetings
        ) { persistedMeeting = $0 }

        #expect(changed)
        #expect(persistedMeeting?.isArchived == true)
        #expect(meetings[0].isArchived)
    }

    @Test("failed archive leaves memory unchanged")
    func failedArchiveDoesNotMutateMemory() {
        let original = meeting("meeting", createdAt: 1)
        var meetings = [original]

        #expect(throws: PersistenceError.failed) {
            try MeetingCollectionPolicy.setArchived(
                original.id,
                isArchived: true,
                in: &meetings
            ) { _ in throw PersistenceError.failed }
        }

        #expect(meetings == [original])
    }

    @Test("failed creation leaves meetings and selection unchanged")
    func failedCreationDoesNotMutateMemory() {
        let existing = meeting("existing", createdAt: 1)
        var meetings = [existing]
        var selectedMeetingID: Meeting.ID? = existing.id

        #expect(throws: PersistenceError.failed) {
            try MeetingCollectionPolicy.insert(
                meeting("created", createdAt: 2),
                into: &meetings,
                selectedMeetingID: &selectedMeetingID
            ) { _ in throw PersistenceError.failed }
        }

        #expect(meetings == [existing])
        #expect(selectedMeetingID == existing.id)
    }

    @Test("deleting the selected meeting falls back to the adjacent meeting")
    func deletingSelectionFallsBack() throws {
        var meetings = [meeting("newer", createdAt: 3), meeting("selected", createdAt: 2), meeting("older", createdAt: 1)]
        var selectedMeetingID: Meeting.ID? = "selected"

        let removed = try MeetingCollectionPolicy.remove(
            "selected",
            from: &meetings,
            selectedMeetingID: &selectedMeetingID,
            persist: { _ in }
        )

        #expect(removed)
        #expect(meetings.map(\.id) == ["newer", "older"])
        #expect(selectedMeetingID == "older")
    }

    @Test("failed deletion leaves meetings and selection unchanged")
    func failedDeletionDoesNotMutateMemory() {
        let selected = meeting("selected", createdAt: 1)
        var meetings = [selected]
        var selectedMeetingID: Meeting.ID? = selected.id

        #expect(throws: PersistenceError.failed) {
            try MeetingCollectionPolicy.remove(
                selected.id,
                from: &meetings,
                selectedMeetingID: &selectedMeetingID
            ) { _ in throw PersistenceError.failed }
        }

        #expect(meetings == [selected])
        #expect(selectedMeetingID == selected.id)
    }

    @Test("deleting another meeting preserves the current selection")
    func deletingAnotherMeetingPreservesSelection() throws {
        var meetings = [meeting("selected", createdAt: 2), meeting("other", createdAt: 1)]
        var selectedMeetingID: Meeting.ID? = "selected"

        _ = try MeetingCollectionPolicy.remove(
            "other",
            from: &meetings,
            selectedMeetingID: &selectedMeetingID,
            persist: { _ in }
        )

        #expect(selectedMeetingID == "selected")
    }

    @Test("refresh preserves a selection outside the visible page")
    func refreshPreservesSelectionOutsideVisiblePage() {
        let visibleMeetings = [meeting("visible", createdAt: 2)]
        let allMeetingIDs: Set<Meeting.ID> = [visibleMeetings[0].id, "outside-page"]

        let selection = MeetingCollectionPolicy.resolvedSelection(
            currentID: "outside-page",
            allMeetingIDs: allMeetingIDs
        )

        #expect(selection == "outside-page")
    }

    @Test("refresh falls back only when the selection is absent from the full collection")
    func refreshFallsBackForMissingSelection() {
        let allMeetingIDs: Set<Meeting.ID> = ["fallback", "other"]

        #expect(
            MeetingCollectionPolicy.resolvedSelection(
                currentID: "deleted",
                allMeetingIDs: allMeetingIDs,
                fallbackID: "fallback"
            ) == "fallback"
        )
        #expect(
            MeetingCollectionPolicy.resolvedSelection(
                currentID: "deleted",
                allMeetingIDs: allMeetingIDs
            ) == nil
        )
    }

    private func meeting(_ id: Meeting.ID, createdAt: TimeInterval) -> Meeting {
        Meeting(
            id: id,
            title: id,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
