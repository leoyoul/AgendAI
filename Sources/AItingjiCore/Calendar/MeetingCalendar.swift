import Foundation

public struct MeetingCalendarWeek: Equatable, Sendable {
    public var interval: DateInterval
    public var scheduledMeetings: [Meeting]
    public var unscheduled: [Meeting]

    public init(
        interval: DateInterval,
        scheduledMeetings: [Meeting],
        unscheduled: [Meeting]
    ) {
        self.interval = interval
        self.scheduledMeetings = scheduledMeetings
        self.unscheduled = unscheduled
    }
}

public struct MeetingCalendarLayoutItem: Equatable, Sendable {
    public var id: String
    public var meetingID: Meeting.ID
    public var dayIndex: Int
    public var startMinute: Int
    public var endMinute: Int
    public var displayEndMinute: Int
    public var lane: Int
    public var laneCount: Int
    public var continuesFromPreviousDay: Bool
    public var continuesIntoNextDay: Bool

    public init(
        id: String,
        meetingID: Meeting.ID,
        dayIndex: Int,
        startMinute: Int,
        endMinute: Int,
        displayEndMinute: Int,
        lane: Int,
        laneCount: Int,
        continuesFromPreviousDay: Bool,
        continuesIntoNextDay: Bool
    ) {
        self.id = id
        self.meetingID = meetingID
        self.dayIndex = dayIndex
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.displayEndMinute = displayEndMinute
        self.lane = lane
        self.laneCount = laneCount
        self.continuesFromPreviousDay = continuesFromPreviousDay
        self.continuesIntoNextDay = continuesIntoNextDay
    }
}

public enum MeetingCalendar {
    public static func weekInterval(
        containing date: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        var calendar = calendar
        calendar.firstWeekday = 2

        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: startOfDay
        )!
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        return DateInterval(start: start, end: end)
    }

    public static func effectiveInterval(
        for meeting: Meeting,
        now: Date,
        isLive: Bool = false
    ) -> DateInterval? {
        effectiveIntervals(for: meeting, now: now, isLive: isLive).first
    }

    public static func effectiveIntervals(
        for meeting: Meeting,
        now: Date,
        isLive: Bool = false
    ) -> [DateInterval] {
        MeetingRecordingTimeline.intervals(
            for: meeting,
            now: now,
            isLive: isLive
        )
    }

    public static func week(
        containing date: Date,
        meetings: [Meeting],
        now: Date,
        calendar: Calendar = .current,
        activeMeetingID: Meeting.ID? = nil
    ) -> MeetingCalendarWeek {
        let interval = weekInterval(containing: date, calendar: calendar)
        var scheduledMeetings: [Meeting] = []
        var unscheduled: [Meeting] = []

        for meeting in meetings {
            let meetingIntervals = effectiveIntervals(
                for: meeting,
                now: now,
                isLive: meeting.id == activeMeetingID
            )
            if meetingIntervals.contains(where: { overlaps($0, interval) }) {
                scheduledMeetings.append(meeting)
            } else if meetingIntervals.isEmpty,
                      contains(meeting.createdAt, in: interval) {
                unscheduled.append(meeting)
            }
        }

        return MeetingCalendarWeek(
            interval: interval,
            scheduledMeetings: scheduledMeetings,
            unscheduled: unscheduled
        )
    }

    public static func layoutItems(
        for meetings: [Meeting],
        in weekInterval: DateInterval,
        now: Date,
        calendar: Calendar = .current,
        minimumDisplayMinutes: Int,
        activeMeetingID: Meeting.ID? = nil
    ) -> [MeetingCalendarLayoutItem] {
        let minimumDisplayMinutes = max(0, minimumDisplayMinutes)
        var itemsByDay = Array(repeating: [MeetingCalendarLayoutItem](), count: 7)

        for meeting in meetings {
            let effectiveIntervals = effectiveIntervals(
                for: meeting,
                now: now,
                isLive: meeting.id == activeMeetingID
            )
            guard !effectiveIntervals.isEmpty else {
                continue
            }

            var segmentIndex = 0
            for effectiveInterval in effectiveIntervals {
                guard overlaps(effectiveInterval, weekInterval) else {
                    continue
                }

                for dayIndex in 0..<7 {
                    guard let dayStart = calendar.date(
                        byAdding: .day,
                        value: dayIndex,
                        to: weekInterval.start
                    ), let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                    else {
                        continue
                    }

                    let segmentStart = max(effectiveInterval.start, dayStart, weekInterval.start)
                    let segmentEnd = min(effectiveInterval.end, dayEnd, weekInterval.end)
                    guard segmentStart < segmentEnd else {
                        continue
                    }

                    let startMinute = minutePosition(
                        for: segmentStart,
                        dayStart: dayStart,
                        dayEnd: dayEnd,
                        isEnd: false,
                        calendar: calendar
                    )
                    let endMinute = minutePosition(
                        for: segmentEnd,
                        dayStart: dayStart,
                        dayEnd: dayEnd,
                        isEnd: true,
                        calendar: calendar
                    )
                    let displayEndMinute = min(
                        24 * 60,
                        max(endMinute, startMinute + minimumDisplayMinutes)
                    )

                    itemsByDay[dayIndex].append(
                        MeetingCalendarLayoutItem(
                            id: "\(meeting.id):\(dayIndex):\(segmentIndex)",
                            meetingID: meeting.id,
                            dayIndex: dayIndex,
                            startMinute: startMinute,
                            endMinute: endMinute,
                            displayEndMinute: displayEndMinute,
                            lane: 0,
                            laneCount: 1,
                            continuesFromPreviousDay: effectiveInterval.start < segmentStart,
                            continuesIntoNextDay: effectiveInterval.end > segmentEnd
                        )
                    )
                    segmentIndex += 1
                }
            }
        }

        return itemsByDay.flatMap(assignLanes)
    }

    private static func assignLanes(
        to unsortedItems: [MeetingCalendarLayoutItem]
    ) -> [MeetingCalendarLayoutItem] {
        var items = unsortedItems.sorted {
            if $0.startMinute != $1.startMinute {
                return $0.startMinute < $1.startMinute
            }
            if $0.endMinute != $1.endMinute {
                return $0.endMinute < $1.endMinute
            }
            return $0.meetingID < $1.meetingID
        }

        var groupStart = 0
        while groupStart < items.count {
            var groupEnd = groupStart + 1
            var latestDisplayEnd = items[groupStart].displayEndMinute

            while groupEnd < items.count,
                  items[groupEnd].startMinute < latestDisplayEnd {
                latestDisplayEnd = max(
                    latestDisplayEnd,
                    items[groupEnd].displayEndMinute
                )
                groupEnd += 1
            }

            var laneEnds: [Int] = []
            for index in groupStart..<groupEnd {
                let lane: Int
                if let reusableLane = laneEnds.firstIndex(
                    where: { $0 <= items[index].startMinute }
                ) {
                    lane = reusableLane
                    laneEnds[reusableLane] = items[index].displayEndMinute
                } else {
                    lane = laneEnds.count
                    laneEnds.append(items[index].displayEndMinute)
                }
                items[index].lane = lane
            }

            for index in groupStart..<groupEnd {
                items[index].laneCount = laneEnds.count
            }
            groupStart = groupEnd
        }

        return items
    }

    private static func minutePosition(
        for date: Date,
        dayStart: Date,
        dayEnd: Date,
        isEnd: Bool,
        calendar: Calendar
    ) -> Int {
        if date <= dayStart {
            return 0
        }
        if date >= dayEnd {
            return 24 * 60
        }

        let components = calendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: date
        )
        var minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if isEnd,
           (components.second ?? 0) > 0 || (components.nanosecond ?? 0) > 0 {
            minute += 1
        }
        return minute
    }

    private static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        interval.start <= date && date < interval.end
    }

    private static func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }
}
