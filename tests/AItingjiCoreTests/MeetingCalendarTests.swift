import AItingjiCore
import Foundation
import Testing

@Suite("MeetingCalendarTests")
struct MeetingCalendarTests {
    private let calendar = Self.makeCalendar(timeZone: "Asia/Shanghai")

    @Test
    func usesMondayAsWeekStart() {
        let reference = date(2026, 7, 8, 12)

        let interval = MeetingCalendar.weekInterval(
            containing: reference,
            calendar: calendar
        )

        #expect(interval.start == date(2026, 7, 6))
        #expect(interval.end == date(2026, 7, 13))
        #expect(calendar.component(.weekday, from: interval.start) == 2)
    }

    @Test
    func computesDSTWeekEndUsingCalendarDays() {
        let losAngeles = Self.makeCalendar(timeZone: "America/Los_Angeles")
        let reference = Self.date(2026, 3, 4, 12, calendar: losAngeles)

        let interval = MeetingCalendar.weekInterval(
            containing: reference,
            calendar: losAngeles
        )

        #expect(interval.start == Self.date(2026, 3, 2, calendar: losAngeles))
        #expect(interval.end == Self.date(2026, 3, 9, calendar: losAngeles))
        #expect(interval.duration == 601_200)
    }

    @Test
    func classifiesScheduledAndUnscheduledMeetingsWithHalfOpenWeekBoundary() {
        let meetings = [
            meeting("scheduled", startedAt: date(2026, 7, 8, 9), endedAt: date(2026, 7, 8, 10)),
            meeting("outside", startedAt: date(2026, 7, 5, 9), endedAt: date(2026, 7, 5, 10)),
            meeting("cross-week", startedAt: date(2026, 7, 5, 23), endedAt: date(2026, 7, 6, 1)),
            meeting("next-week", startedAt: date(2026, 7, 13), endedAt: date(2026, 7, 13, 1)),
            meeting("unscheduled", createdAt: date(2026, 7, 9)),
            meeting("old-unscheduled", createdAt: date(2026, 7, 5)),
            meeting("next-unscheduled", createdAt: date(2026, 7, 13))
        ]

        let week = MeetingCalendar.week(
            containing: date(2026, 7, 8),
            meetings: meetings,
            now: date(2026, 7, 8, 12),
            calendar: calendar
        )

        #expect(week.scheduledMeetings.map(\.id) == ["scheduled", "cross-week"])
        #expect(week.unscheduled.map(\.id) == ["unscheduled"])
    }

    @Test
    func activeMeetingUsesInjectedNowAndCanOverlapCurrentWeek() {
        let active = meeting(
            "active",
            status: .recording,
            startedAt: date(2026, 7, 5, 23)
        )
        let now = date(2026, 7, 6, 2)

        let interval = MeetingCalendar.effectiveInterval(
            for: active,
            now: now,
            isLive: true
        )
        let week = MeetingCalendar.week(
            containing: now,
            meetings: [active],
            now: now,
            calendar: calendar,
            activeMeetingID: active.id
        )

        #expect(interval?.start == date(2026, 7, 5, 23))
        #expect(interval?.end == now)
        #expect(week.scheduledMeetings.map(\.id) == ["active"])
    }

    @Test
    func effectiveIntervalFallsBackToFifteenMinutesForMissingOrInvalidEnd() {
        let start = date(2026, 7, 8, 9)
        let missingEnd = meeting("missing", status: .done, startedAt: start)
        let invalidEnd = meeting(
            "invalid",
            status: .done,
            startedAt: start,
            endedAt: date(2026, 7, 8, 8)
        )
        let futureActive = meeting("future", status: .paused, startedAt: start)

        #expect(
            MeetingCalendar.effectiveInterval(for: missingEnd, now: date(2026, 7, 8, 12))?.end
                == date(2026, 7, 8, 9, 15)
        )
        #expect(
            MeetingCalendar.effectiveInterval(for: invalidEnd, now: date(2026, 7, 8, 12))?.end
                == date(2026, 7, 8, 9, 15)
        )
        #expect(
            MeetingCalendar.effectiveInterval(for: futureActive, now: date(2026, 7, 8, 8))?.end
                == date(2026, 7, 8, 9, 15)
        )
    }

    @Test
    func layoutKeepsActualMinutesSeparateFromMinimumVisualHeight() throws {
        let short = meeting(
            "short",
            startedAt: date(2026, 7, 8, 9),
            endedAt: date(2026, 7, 8, 9, 10)
        )

        let item = try #require(layout([short], minimumDisplayMinutes: 42).first)

        #expect(item.dayIndex == 2)
        #expect(item.startMinute == 540)
        #expect(item.endMinute == 550)
        #expect(item.displayEndMinute == 582)
        #expect(item.lane == 0)
        #expect(item.laneCount == 1)
    }

    @Test
    func activeLayoutUsesInjectedNow() throws {
        let active = meeting(
            "active",
            status: .recording,
            startedAt: date(2026, 7, 8, 9)
        )

        let item = try #require(
            layout(
                [active],
                now: date(2026, 7, 8, 10, 30),
                activeMeetingID: active.id,
                minimumDisplayMinutes: 42
            ).first
        )

        #expect(item.startMinute == 540)
        #expect(item.endMinute == 630)
        #expect(item.displayEndMinute == 630)
    }

    @Test
    func pausedMeetingUsesClosedIntervalsInsteadOfWallClockNow() {
        let paused = meeting(
            "paused",
            status: .paused,
            startedAt: date(2026, 7, 11, 19, 54),
            recordingIntervals: [
                MeetingRecordingInterval(
                    id: "paused-interval",
                    startedAt: date(2026, 7, 11, 19, 54),
                    endedAt: date(2026, 7, 11, 20, 10)
                )
            ]
        )

        let week = MeetingCalendar.week(
            containing: date(2026, 7, 13, 9),
            meetings: [paused],
            now: date(2026, 7, 13, 9),
            calendar: calendar
        )

        #expect(week.scheduledMeetings.isEmpty)
    }

    @Test
    func resumedMeetingProducesOneCalendarSegmentPerRecordingInterval() {
        let resumed = meeting(
            "resumed",
            startedAt: date(2026, 7, 8, 9),
            endedAt: date(2026, 7, 8, 10, 20),
            recordingIntervals: [
                MeetingRecordingInterval(
                    id: "first",
                    startedAt: date(2026, 7, 8, 9),
                    endedAt: date(2026, 7, 8, 9, 10)
                ),
                MeetingRecordingInterval(
                    id: "second",
                    startedAt: date(2026, 7, 8, 10),
                    endedAt: date(2026, 7, 8, 10, 20)
                )
            ]
        )

        let items = layout([resumed], minimumDisplayMinutes: 0)

        #expect(items.map(\.startMinute) == [540, 600])
        #expect(items.map(\.endMinute) == [550, 620])
    }

    @Test
    func splitsMeetingAtMidnightWithoutChangingActualDuration() {
        let overnight = meeting(
            "overnight",
            startedAt: date(2026, 7, 8, 23, 30),
            endedAt: date(2026, 7, 9, 1, 15)
        )

        let items = layout([overnight], minimumDisplayMinutes: 0)

        #expect(items.count == 2)
        #expect(items[0].dayIndex == 2)
        #expect(items[0].startMinute == 1_410)
        #expect(items[0].endMinute == 1_440)
        #expect(!items[0].continuesFromPreviousDay)
        #expect(items[0].continuesIntoNextDay)
        #expect(items[1].dayIndex == 3)
        #expect(items[1].startMinute == 0)
        #expect(items[1].endMinute == 75)
        #expect(items[1].continuesFromPreviousDay)
        #expect(!items[1].continuesIntoNextDay)
        #expect(items.map(\.id) == ["overnight:2:0", "overnight:3:1"])
    }

    @Test
    func clipsCrossWeekMeetingAtBothWeekBoundaries() {
        let spanning = meeting(
            "spanning",
            startedAt: date(2026, 7, 5, 23),
            endedAt: date(2026, 7, 13, 1)
        )

        let items = layout([spanning], minimumDisplayMinutes: 0)

        #expect(items.count == 7)
        #expect(items.first?.dayIndex == 0)
        #expect(items.first?.startMinute == 0)
        #expect(items.first?.continuesFromPreviousDay == true)
        #expect(items.last?.dayIndex == 6)
        #expect(items.last?.endMinute == 1_440)
        #expect(items.last?.continuesIntoNextDay == true)
    }

    @Test
    func overlappingMeetingsUseDifferentLanesAndNonOverlappingMeetingsReuseLane() {
        let meetings = [
            meeting("a", startedAt: date(2026, 7, 8, 9), endedAt: date(2026, 7, 8, 10)),
            meeting("b", startedAt: date(2026, 7, 8, 9, 30), endedAt: date(2026, 7, 8, 10, 30)),
            meeting("c", startedAt: date(2026, 7, 8, 10, 30), endedAt: date(2026, 7, 8, 11))
        ]

        let items = layout(meetings, minimumDisplayMinutes: 0)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.meetingID, $0) })

        #expect(byID["a"]?.lane == 0)
        #expect(byID["b"]?.lane == 1)
        #expect(byID["a"]?.laneCount == 2)
        #expect(byID["b"]?.laneCount == 2)
        #expect(byID["c"]?.lane == 0)
        #expect(byID["c"]?.laneCount == 1)
    }

    @Test
    func chainedOverlapUsesOneGroupLaneCount() {
        let meetings = [
            meeting("a", startedAt: date(2026, 7, 8, 9), endedAt: date(2026, 7, 8, 10)),
            meeting("b", startedAt: date(2026, 7, 8, 9, 30), endedAt: date(2026, 7, 8, 10, 30)),
            meeting("c", startedAt: date(2026, 7, 8, 10, 15), endedAt: date(2026, 7, 8, 11))
        ]

        let items = layout(meetings, minimumDisplayMinutes: 0)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.meetingID, $0) })

        #expect(items.allSatisfy { $0.laneCount == 2 })
        #expect(byID["a"]?.lane == 0)
        #expect(byID["b"]?.lane == 1)
        #expect(byID["c"]?.lane == 0)
    }

    @Test
    func minimumVisualIntervalsParticipateInOverlapLanes() {
        let meetings = [
            meeting("a", startedAt: date(2026, 7, 8, 9), endedAt: date(2026, 7, 8, 9, 5)),
            meeting("b", startedAt: date(2026, 7, 8, 9, 30), endedAt: date(2026, 7, 8, 9, 35))
        ]

        let items = layout(meetings, minimumDisplayMinutes: 42)

        #expect(items.map(\.lane) == [0, 1])
        #expect(items.allSatisfy { $0.laneCount == 2 })
        #expect(items.map(\.endMinute) == [545, 575])
        #expect(items.map(\.displayEndMinute) == [582, 612])
    }

    @Test
    func minimumVisualHeightIsPreservedNearMidnightWithoutChangingActualEnd() throws {
        let late = meeting(
            "late",
            startedAt: date(2026, 7, 8, 23, 50),
            endedAt: date(2026, 7, 8, 23, 55)
        )

        let item = try #require(layout([late], minimumDisplayMinutes: 42).first)

        #expect(item.startMinute == 1_430)
        #expect(item.endMinute == 1_435)
        #expect(item.displayEndMinute == 1_440)
        #expect(!item.continuesIntoNextDay)
    }

    private func layout(
        _ meetings: [Meeting],
        now: Date? = nil,
        activeMeetingID: Meeting.ID? = nil,
        minimumDisplayMinutes: Int
    ) -> [MeetingCalendarLayoutItem] {
        let week = MeetingCalendar.weekInterval(
            containing: date(2026, 7, 8),
            calendar: calendar
        )
        return MeetingCalendar.layoutItems(
            for: meetings,
            in: week,
            now: now ?? date(2026, 7, 8, 12),
            calendar: calendar,
            minimumDisplayMinutes: minimumDisplayMinutes,
            activeMeetingID: activeMeetingID
        )
    }

    private func meeting(
        _ id: String,
        status: MeetingStatus = .done,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        recordingIntervals: [MeetingRecordingInterval] = []
    ) -> Meeting {
        Meeting(
            id: id,
            title: id,
            status: status,
            createdAt: createdAt ?? startedAt ?? date(2026, 7, 8),
            startedAt: startedAt,
            endedAt: endedAt,
            recordingIntervals: recordingIntervals
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        Self.date(
            year,
            month,
            day,
            hour,
            minute,
            calendar: calendar
        )
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private static func makeCalendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }
}
