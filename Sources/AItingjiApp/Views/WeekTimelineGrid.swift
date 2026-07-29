import AItingjiCore
import SwiftUI

struct WeekTimelineGrid: View {
    let weekInterval: DateInterval
    let meetings: [Meeting]
    let layoutItems: [MeetingCalendarLayoutItem]
    let now: Date
    let hourHeight: CGFloat
    let onSelectMeeting: (Meeting.ID) -> Void

    private let timeColumnWidth: CGFloat = 56
    private let dayColumnWidth: CGFloat = 148
    private let headerHeight: CGFloat = 52

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        timeline
                    } header: {
                        dayHeader
                            .zIndex(2)
                    }
                }
                .frame(width: totalWidth, alignment: .leading)
            }
            .onAppear {
                scrollToInitialHour(using: proxy)
            }
            .onChange(of: weekInterval.start) { _, _ in
                scrollToInitialHour(using: proxy)
            }
        }
    }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeColumnWidth, height: headerHeight)

            ForEach(0..<7, id: \.self) { dayIndex in
                let date = dayDate(dayIndex)
                VStack(spacing: 3) {
                    Text(weekdayText(for: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(date.formatted(.dateTime.month().day()))
                        .font(.subheadline.weight(isToday(date) ? .semibold : .regular))
                }
                .frame(width: dayColumnWidth, height: headerHeight)
                .background(isToday(date) ? Color.accentColor.opacity(0.08) : Color.clear)
                .overlay(alignment: .leading) {
                    Divider()
                }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            currentDayHighlight
            hourRows
            dayDividers

            if layoutItems.isEmpty {
                emptyState
            } else {
                meetingItems
            }
        }
        .frame(width: totalWidth, height: 24 * hourHeight, alignment: .topLeading)
    }

    private var hourRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(String(format: "%02d:00", hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: timeColumnWidth - 8, alignment: .trailing)
                        .padding(.trailing, 8)
                        .offset(y: -6)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
                }
                .frame(width: totalWidth, height: hourHeight, alignment: .top)
                .id(hourID(hour))
            }
        }
    }

    private var dayDividers: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColumnWidth)
            ForEach(0..<7, id: \.self) { _ in
                Color.clear
                    .frame(width: dayColumnWidth)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 1)
                    }
            }
        }
    }

    @ViewBuilder
    private var currentDayHighlight: some View {
        if let index = currentDayIndex {
            Color.accentColor.opacity(0.035)
                .frame(width: dayColumnWidth, height: 24 * hourHeight)
                .offset(x: timeColumnWidth + CGFloat(index) * dayColumnWidth)
        }
    }

    private var meetingItems: some View {
        ForEach(layoutItems, id: \.id) { item in
            if let meeting = meetingsByID[item.meetingID] {
                let laneWidth = (dayColumnWidth - 8) / CGFloat(max(1, item.laneCount))
                let height = max(
                    1,
                    CGFloat(item.displayEndMinute - item.startMinute) / 60 * hourHeight
                )
                MeetingCalendarCard(
                    meeting: meeting,
                    item: item,
                    date: dayDate(item.dayIndex),
                    onSelect: { onSelectMeeting(meeting.id) }
                )
                .frame(width: max(32, laneWidth - 3), height: height)
                .offset(
                    x: timeColumnWidth
                        + CGFloat(item.dayIndex) * dayColumnWidth
                        + 4
                        + CGFloat(item.lane) * laneWidth,
                    y: CGFloat(item.startMinute) / 60 * hourHeight
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("本周暂无已安排会议")
                .font(.headline)
            Text("新建会议后会显示在未安排时间。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 360)
        .offset(
            x: timeColumnWidth + (7 * dayColumnWidth - 360) / 2,
            y: 8 * hourHeight
        )
    }

    private var meetingsByID: [Meeting.ID: Meeting] {
        Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
    }

    private var totalWidth: CGFloat {
        timeColumnWidth + 7 * dayColumnWidth
    }

    private var currentDayIndex: Int? {
        let calendar = Calendar.current
        guard now >= weekInterval.start, now < weekInterval.end else {
            return nil
        }
        return calendar.dateComponents([.day], from: weekInterval.start, to: now).day
    }

    private var initialHour: Int {
        // 吸顶日期表头会遮住目标行，因此向前定位一小时，让 08:00 成为首个可见刻度。
        7
    }

    private func dayDate(_ dayIndex: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: dayIndex, to: weekInterval.start) ?? weekInterval.start
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    private func weekdayText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func hourID(_ hour: Int) -> String {
        "calendar-hour-\(hour)"
    }

    private func scrollToInitialHour(using proxy: ScrollViewProxy) {
        let target = initialHour
        DispatchQueue.main.async {
            proxy.scrollTo(hourID(target), anchor: .top)
        }
    }
}
