import Foundation

/// Pure layout rules for the quarter-backed, seven-day workbench viewport.
enum WorkbenchViewport {
    static let visibleDayCount = 7

    static func clampedStartIndex(
        for date: Date,
        dates: [Date],
        calendar: Calendar = .current
    ) -> Int {
        guard !dates.isEmpty else { return 0 }
        let normalizedDate = calendar.startOfDay(for: date)
        let requestedIndex = dates.firstIndex { calendar.isDate($0, inSameDayAs: normalizedDate) }
            ?? dates.firstIndex { $0 > normalizedDate }
            ?? dates.count - 1
        return min(max(requestedIndex, 0), maxStartIndex(for: dates))
    }

    static func startIndex(
        forContentOffset offset: CGFloat,
        columnWidth: CGFloat,
        dateCount: Int
    ) -> Int {
        guard columnWidth > 0, dateCount > 0 else { return 0 }
        let rawIndex = Int((max(offset, 0) / columnWidth).rounded())
        return min(max(rawIndex, 0), max(0, dateCount - visibleDayCount))
    }

    static func maxStartIndex(for dates: [Date]) -> Int {
        max(0, dates.count - visibleDayCount)
    }

    static func visibleDates(
        startingAt startIndex: Int,
        in dates: [Date]
    ) -> ArraySlice<Date> {
        guard !dates.isEmpty else { return dates[...] }
        let clampedIndex = min(max(startIndex, 0), maxStartIndex(for: dates))
        let endIndex = min(dates.count, clampedIndex + visibleDayCount)
        return dates[clampedIndex..<endIndex]
    }
}
