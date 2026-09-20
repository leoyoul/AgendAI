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

public struct MeetingCalendarQuarter: Equatable, Sendable {
    public var interval: DateInterval
    public var year: Int
    public var number: Int
    public var dates: [Date]

    public var identifier: String { "\(year)-Q\(number)" }

    public var displayName: String { "\(year)年第\(number)季度" }

    public init(interval: DateInterval, year: Int, number: Int, dates: [Date]) {
        self.interval = interval
        self.year = year
        self.number = number
        self.dates = dates
    }
}

public enum WorkbenchSpanKind: String, Equatable, Sendable {
    case meeting
    case workItem
}

/// 工作台甘特布局的输入。日期是本地自然日，结束日为包含式。
public struct WorkbenchDateSpan: Equatable, Sendable {
    public var id: String
    public var kind: WorkbenchSpanKind
    public var startDate: Date
    public var endDate: Date

    public init(id: String, kind: WorkbenchSpanKind, startDate: Date, endDate: Date) {
        self.id = id
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct WorkbenchTrackPlacement: Equatable, Sendable {
    public var id: String
    public var spanID: String
    public var kind: WorkbenchSpanKind
    public var startDayIndex: Int
    public var endDayIndex: Int
    public var track: Int
    public var trackCount: Int
    public var continuesFromPreviousQuarter: Bool
    public var continuesIntoNextQuarter: Bool

    public init(
        id: String,
        spanID: String,
        kind: WorkbenchSpanKind,
        startDayIndex: Int,
        endDayIndex: Int,
        track: Int,
        trackCount: Int,
        continuesFromPreviousQuarter: Bool,
        continuesIntoNextQuarter: Bool
    ) {
        self.id = id
        self.spanID = spanID
        self.kind = kind
        self.startDayIndex = startDayIndex
        self.endDayIndex = endDayIndex
        self.track = track
        self.trackCount = trackCount
        self.continuesFromPreviousQuarter = continuesFromPreviousQuarter
        self.continuesIntoNextQuarter = continuesIntoNextQuarter
    }
}

public enum MeetingCalendar {
    public static func quarterInterval(
        containing date: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        let month = calendar.component(.month, from: day)
        let quarterStartMonth = ((month - 1) / 3) * 3 + 1
        let start = calendar.date(from: DateComponents(year: year, month: quarterStartMonth, day: 1))!
        let end = calendar.date(byAdding: .month, value: 3, to: start)!
        return DateInterval(start: start, end: end)
    }

    public static func quarter(
        containing date: Date,
        calendar: Calendar = .current
    ) -> MeetingCalendarQuarter {
        let interval = quarterInterval(containing: date, calendar: calendar)
        let year = calendar.component(.year, from: interval.start)
        let month = calendar.component(.month, from: interval.start)
        let number = ((month - 1) / 3) + 1
        var dates: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return MeetingCalendarQuarter(interval: interval, year: year, number: number, dates: dates)
    }

    public static func workbenchLayout(
        for spans: [WorkbenchDateSpan],
        in quarterInterval: DateInterval,
        calendar: Calendar = .current
    ) -> [WorkbenchTrackPlacement] {
        let quarterStart = calendar.startOfDay(for: quarterInterval.start)
        let dayCount = dates(in: quarterInterval, calendar: calendar).count
        guard dayCount > 0 else { return [] }
        let quarterEnd = calendar.date(byAdding: .day, value: dayCount, to: quarterStart) ?? quarterInterval.end
        var placements: [(placement: WorkbenchTrackPlacement, start: Int, end: Int)] = []

        for span in spans {
            let start = calendar.startOfDay(for: min(span.startDate, span.endDate))
            let end = calendar.startOfDay(for: max(span.startDate, span.endDate))
            guard start < quarterEnd, end >= quarterStart else { continue }

            let clippedStart = max(start, quarterStart)
            let clippedEnd = min(end, calendar.date(byAdding: .day, value: -1, to: quarterEnd) ?? end)
            let startIndex = max(0, calendar.dateComponents([.day], from: quarterStart, to: clippedStart).day ?? 0)
            let endIndex = min(dayCount - 1, calendar.dateComponents([.day], from: quarterStart, to: clippedEnd).day ?? dayCount - 1)
            guard startIndex <= endIndex else { continue }
            let placement = WorkbenchTrackPlacement(
                id: span.id,
                spanID: span.id,
                kind: span.kind,
                startDayIndex: startIndex,
                endDayIndex: endIndex,
                track: 0,
                trackCount: 1,
                continuesFromPreviousQuarter: start < quarterStart,
                continuesIntoNextQuarter: end >= quarterEnd
            )
            placements.append((placement, startIndex, endIndex))
        }

        var sorted = placements.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.placement.id < $1.placement.id
        }
        var trackEnds: [Int] = []
        for index in sorted.indices {
            let reusable = trackEnds.firstIndex(where: { $0 < sorted[index].start })
            let track: Int
            if let reusable {
                track = reusable
                trackEnds[reusable] = sorted[index].end
            } else {
                track = trackEnds.count
                trackEnds.append(sorted[index].end)
            }
            sorted[index].placement.track = track
        }
        let trackCount = max(1, trackEnds.count)
        return sorted.map {
            var placement = $0.placement
            placement.trackCount = trackCount
            return placement
        }
    }

    private static func dates(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

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
