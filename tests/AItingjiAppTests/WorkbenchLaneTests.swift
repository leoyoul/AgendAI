import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Workbench month band")
struct WorkbenchMonthBandTests {
    @Test("month cells tile the timeline without drifting from the date columns")
    func monthCellsTileTimelineExactly() {
        let segments = WorkbenchMonthBand.segments(
            [
                (id: "2026-7", title: "2026年7月", dayCount: 31),
                (id: "2026-8", title: "2026年8月", dayCount: 31),
                (id: "2026-9", title: "2026年9月", dayCount: 30),
            ],
            columnWidth: 116
        )

        #expect(segments.map(\.startX) == [0, 3596, 7192])
        #expect(segments.map(\.width) == [3596, 3596, 3480])
        #expect(segments.last.map { $0.startX + $0.width } == CGFloat(92 * 116))
    }

    @Test("single day counts still produce a full column width")
    func singleDayMonthKeepsColumnWidth() {
        let segments = WorkbenchMonthBand.segments(
            [(id: "2026-1", title: "2026年1月", dayCount: 1)],
            columnWidth: 116
        )

        #expect(segments == [WorkbenchMonthSegment(id: "2026-1", title: "2026年1月", startX: 0, width: 116)])
    }
}

@Suite("Workbench sticky label")
struct WorkbenchStickyLabelTests {
    @Test("keeps the label in place while the container start is visible")
    func keepsLabelWhileContainerStartVisible() {
        let shift = WorkbenchStickyLabel.shift(
            containerStart: 100,
            containerWidth: 580,
            labelWidth: 200,
            contentOffset: 0
        )

        #expect(shift == 0)
    }

    @Test("follows the viewport once the container start scrolls out")
    func followsViewportAfterContainerStartLeaves() {
        let shift = WorkbenchStickyLabel.shift(
            containerStart: 100,
            containerWidth: 580,
            labelWidth: 200,
            contentOffset: -300
        )

        #expect(shift == 200)
    }

    @Test("stops at the container trailing edge")
    func stopsAtContainerTrailingEdge() {
        let shift = WorkbenchStickyLabel.shift(
            containerStart: 100,
            containerWidth: 580,
            labelWidth: 200,
            contentOffset: -1_000
        )

        #expect(shift == 370)
    }

    @Test("never shifts when the label is wider than the container")
    func keepsLabelInPlaceWhenWiderThanContainer() {
        let shift = WorkbenchStickyLabel.shift(
            containerStart: 0,
            containerWidth: 200,
            labelWidth: 260,
            contentOffset: -500
        )

        #expect(shift == 0)
    }

    @Test("returns zero for an empty container")
    func returnsZeroForEmptyContainer() {
        let shift = WorkbenchStickyLabel.shift(
            containerStart: 0,
            containerWidth: 0,
            labelWidth: 100,
            contentOffset: -500
        )

        #expect(shift == 0)
    }
}

@Suite("Workbench viewport")
struct WorkbenchViewportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var quarterDates: [Date] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        return (0..<92).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    @Test("shows seven days and puts today at the viewport leading edge")
    func todayStartsTheVisibleWindow() {
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19))!
        let startIndex = WorkbenchViewport.clampedStartIndex(
            for: today,
            dates: quarterDates,
            calendar: calendar
        )

        #expect(startIndex == 80)
        #expect(WorkbenchViewport.visibleDates(startingAt: startIndex, in: quarterDates).count == 7)
        #expect(calendar.isDate(WorkbenchViewport.visibleDates(startingAt: startIndex, in: quarterDates).first!, inSameDayAs: today))
    }

    @Test("clamps the viewport to the final seven quarter dates")
    func clampsAtQuarterEnd() {
        let endDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!

        #expect(
            WorkbenchViewport.clampedStartIndex(
                for: endDate,
                dates: quarterDates,
                calendar: calendar
            ) == 85
        )
    }

    @Test("maps horizontal content offsets to the leftmost visible date")
    func mapsContentOffsetToDateIndex() {
        #expect(WorkbenchViewport.startIndex(forContentOffset: 0, columnWidth: 120, dateCount: 92) == 0)
        #expect(WorkbenchViewport.startIndex(forContentOffset: 359, columnWidth: 120, dateCount: 92) == 3)
        #expect(WorkbenchViewport.startIndex(forContentOffset: 1_000_000, columnWidth: 120, dateCount: 92) == 85)
    }
}

@Suite("Workbench lanes")
@MainActor
struct WorkbenchLaneTests {
    @Test("unmatched live meetings are attributed to the current user's lane")
    func unmatchedLiveMeetingUsesCurrentUserLane() {
        #expect(
            WorkbenchMeetingRouting.belongs(
                meetingID: "live",
                participantPersonIDs: [],
                lanePersonID: "person-me",
                laneMode: .people,
                activeMeetingID: "live",
                currentUserPersonID: "person-me"
            )
        )
        #expect(
            !WorkbenchMeetingRouting.belongs(
                meetingID: "live",
                participantPersonIDs: [],
                lanePersonID: "person-other",
                laneMode: .people,
                activeMeetingID: "live",
                currentUserPersonID: "person-me"
            )
        )
    }

    @Test("unmatched live meetings stay hidden without a current user")
    func unmatchedLiveMeetingRequiresCurrentUser() {
        #expect(
            !WorkbenchMeetingRouting.belongs(
                meetingID: "live",
                participantPersonIDs: [],
                lanePersonID: "person-me",
                laneMode: .people,
                activeMeetingID: "live",
                currentUserPersonID: nil
            )
        )
    }

    @Test("matched meetings remain in their matched people lanes")
    func matchedMeetingDoesNotFallbackToCurrentUser() {
        #expect(
            WorkbenchMeetingRouting.belongs(
                meetingID: "live",
                participantPersonIDs: ["person-other"],
                lanePersonID: "person-other",
                laneMode: .people,
                activeMeetingID: "live",
                currentUserPersonID: "person-me"
            )
        )
        #expect(
            !WorkbenchMeetingRouting.belongs(
                meetingID: "live",
                participantPersonIDs: ["person-other"],
                lanePersonID: "person-me",
                laneMode: .people,
                activeMeetingID: "live",
                currentUserPersonID: "person-me"
            )
        )
    }

    @Test("recording activity is distinct from a scheduled meeting")
    func recordingActivityPresentation() {
        let meeting = Meeting(
            id: "live",
            title: "进行中会议",
            status: .recording,
            createdAt: Date()
        )

        #expect(WorkbenchMeetingActivity(meeting: meeting, activeMeetingID: meeting.id) == .recording)
        #expect(WorkbenchMeetingActivity(meeting: meeting, activeMeetingID: nil) == .scheduled)
    }

    @Test("people mode shows only calendar-visible people")
    func peopleModeShowsOnlyKnownPeople() {
        let people = [
            VoiceprintPerson(id: "person-zhang", displayName: "张敏", jobTitle: "项目经理"),
            VoiceprintPerson(id: "person-li", displayName: "李明"),
        ]
        let grid = makeGrid(
            people: people,
            meetings: [
                // 参会人匹配不到人员库的会议不应再单独占一行。
                Meeting(id: "meeting-unknown", title: "外部对接", status: .done, createdAt: Date())
            ],
            participantSnapshots: [
                "meeting-unknown": WorkbenchMeetingParticipantSnapshot(
                    meetingID: "meeting-unknown",
                    personIDs: [],
                    names: ["王小明"],
                    unmatchedNames: ["王小明"]
                )
            ],
            laneMode: .people
        )

        #expect(grid.lanes.map(\.title) == ["张敏", "李明"])
        #expect(grid.lanes.allSatisfy { !$0.title.contains("待确认") })
    }

    @Test("mixed mode keeps a single all-work-items lane")
    func mixedModeKeepsSingleLane() {
        let grid = makeGrid(people: [], meetings: [], participantSnapshots: [:], laneMode: .mixed)

        #expect(grid.lanes.map(\.title) == ["全部工作项"])
    }

    private func makeGrid(
        people: [VoiceprintPerson],
        meetings: [Meeting],
        participantSnapshots: [Meeting.ID: WorkbenchMeetingParticipantSnapshot],
        laneMode: WorkbenchLaneMode
    ) -> WeekTimelineGrid {
        WeekTimelineGrid(
            quarter: MeetingCalendar.quarter(containing: Date()),
            meetings: meetings,
            workItems: [],
            people: people,
            calendarPeople: laneMode == .people ? people : [],
            participantSnapshots: participantSnapshots,
            laneMode: laneMode,
            currentUserPersonID: nil,
            visibleWeekStartDate: .constant(Date()),
            now: Date(),
            activeMeetingID: nil,
            todayScrollRequest: 0,
            onSelectMeeting: { _ in },
            onSelectWorkItem: { _ in },
            onStatusChange: { _, _ in }
        )
    }
}
