import AItingjiCore
import AppKit
import SwiftUI

struct WeekTimelineGrid: View {
    let quarter: MeetingCalendarQuarter
    let meetings: [Meeting]
    let workItems: [WorkItem]
    let people: [VoiceprintPerson]
    let calendarPeople: [VoiceprintPerson]
    let participantSnapshots: [Meeting.ID: WorkbenchMeetingParticipantSnapshot]
    let laneMode: WorkbenchLaneMode
    let currentUserPersonID: VoiceprintPerson.ID?
    @Binding var visibleWeekStartDate: Date
    let now: Date
    let activeMeetingID: Meeting.ID?
    let todayScrollRequest: Int
    let onSelectMeeting: (Meeting.ID) -> Void
    let onSelectWorkItem: (WorkItem) -> Void
    let onStatusChange: (WorkItem, WorkItemStatus) -> Void

    private let laneLabelWidth: CGFloat = 190
    private let axisHeaderHeight: CGFloat = 64
    private let monthBandHeight: CGFloat = 24
    private let cardHeight: CGFloat = 76
    private let minimumDateColumnWidth: CGFloat = 96
    @State private var horizontalContentOffset: CGFloat = 0
    @State private var timelineContentGlobalMinX: CGFloat = 0
    @State private var headerViewportGlobalMinX: CGFloat = 0
    @State private var timelineViewportWidth: CGFloat = 0
    /// 各标签内容的自然宽度，用于计算吸附位移。键为标签标识（`item:<记录 id>` / `month:<月份 id>`）。
    @State private var labelWidths: [String: CGFloat] = [:]

    private var gridSeparator: Color {
        Color(nsColor: .separatorColor).opacity(0.78)
    }

    private var subtleGridSeparator: Color {
        Color(nsColor: .separatorColor).opacity(0.46)
    }

    private var contentWidth: CGFloat {
        CGFloat(quarter.dates.count) * dateColumnWidth
    }

    private var dateColumnWidth: CGFloat {
        guard timelineViewportWidth > 0 else { return 116 }
        return max(minimumDateColumnWidth, timelineViewportWidth / CGFloat(WorkbenchViewport.visibleDayCount))
    }

    /// 按人员模式只展示工作台日历中可见的人员；未匹配到人员的会议只在混合模式查看。
    var lanes: [WorkbenchLane] {
        guard laneMode == .people else {
            return [WorkbenchLane(id: "mixed", title: "全部工作项", subtitle: "会议与任务", personID: nil)]
        }
        return calendarPeople.map {
            WorkbenchLane(id: $0.id, title: $0.displayName, subtitle: $0.jobTitle, personID: $0.id)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let availableTimelineWidth = max(proxy.size.width - laneLabelWidth, 1)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    laneHeader
                        .frame(width: laneLabelWidth, height: axisHeaderHeight)

                    timelineHeaderViewport(width: availableTimelineWidth)
                }
                .frame(width: proxy.size.width, height: axisHeaderHeight, alignment: .leading)
                .background(.bar.opacity(0.82))

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        laneLabelRows
                            .frame(width: laneLabelWidth)

                        horizontalTimelineViewport(width: availableTimelineWidth)
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
            .onAppear {
                timelineViewportWidth = max(proxy.size.width - laneLabelWidth, 1)
            }
            .onChange(of: proxy.size) { _, newSize in
                timelineViewportWidth = max(newSize.width - laneLabelWidth, 1)
            }
        }
        .onPreferenceChange(WorkbenchLabelWidthPreferenceKey.self) { widths in
            guard widths != labelWidths else { return }
            labelWidths = widths
        }
    }

    private var timelineRows: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    laneRow(lane, index: index)
                }
            }
            dayScrollAnchors
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var dayScrollAnchors: some View {
        HStack(spacing: 0) {
            ForEach(quarter.dates, id: \.self) { date in
                Color.clear
                    .frame(width: dateColumnWidth, height: 1)
                    .id(dayAnchorID(for: date))
            }
        }
        .frame(width: contentWidth, height: 1, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var timelineHeader: some View {
        VStack(spacing: 0) {
            monthHeader
            dateHeader
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var laneHeader: some View {
        VStack(spacing: 0) {
            // 与月份带等高，让下方文案与日期文字落在同一条带内。
            Color.clear
                .frame(height: monthBandHeight)
            HStack(spacing: 8) {
                Image(systemName: laneMode == .people ? "person.2" : "rectangle.stack")
                    .foregroundStyle(.secondary)
                Text(laneMode == .people ? "负责人 / 参与人" : "工作项")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: laneLabelWidth, height: axisHeaderHeight, alignment: .leading)
        .background(.bar.opacity(0.9))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(gridSeparator)
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(gridSeparator)
                .frame(height: 1)
        }
    }

    private var laneLabelRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                laneLabel(lane)
                    .frame(width: laneLabelWidth, height: rowHeight(for: lane), alignment: .topLeading)
                    .background(rowBackground(index: index))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(gridSeparator).frame(height: 1)
                    }
            }
        }
        .background(.bar.opacity(0.56))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(gridSeparator)
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private func timelineHeaderViewport(width: CGFloat) -> some View {
        if #available(macOS 15.0, *) {
            headerViewportSurface(width: width)
        } else {
            headerViewportSurface(width: width)
                .background { globalMinXReader(QuarterHeaderOriginPreferenceKey.self) }
                .onPreferenceChange(QuarterHeaderOriginPreferenceKey.self) { headerMinX in
                    applyTrackedHeaderViewportMinX(headerMinX)
                }
        }
    }

    private func headerViewportSurface(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            timelineHeader
                .offset(x: min(horizontalContentOffset, 0))
        }
        .frame(width: width, height: axisHeaderHeight, alignment: .leading)
        .clipped()
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(gridSeparator)
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(gridSeparator)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func horizontalTimelineViewport(width: CGFloat) -> some View {
        if #available(macOS 15.0, *) {
            baseScrollView(width: width)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.x
                } action: { _, newOffset in
                    applyHorizontalOffset(-newOffset)
                }
        } else {
            baseScrollView(width: width)
                .onPreferenceChange(QuarterHorizontalOffsetPreferenceKey.self) { contentMinX in
                    applyTrackedContentMinX(contentMinX)
                }
        }
    }

    private func baseScrollView(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                timelineRows
                    .background { timelineContentOriginReader }
            }
            .onAppear {
                scrollToVisibleWeek(using: proxy, animated: false)
            }
            .onChange(of: quarter.identifier) { _, _ in
                scrollToVisibleWeek(using: proxy, animated: false)
            }
            .onChange(of: timelineViewportWidth) { _, _ in
                scrollToVisibleWeek(using: proxy, animated: false)
            }
            .onChange(of: todayScrollRequest) { _, _ in
                scrollToVisibleWeek(using: proxy, animated: true)
            }
            .frame(width: width, alignment: .leading)
            .scrollIndicators(.visible)
        }
    }

    private func dayAnchorID(for date: Date) -> String {
        "workbench-day-\(WorkItemDate.key(date))"
    }

    private func scrollToVisibleWeek(using proxy: ScrollViewProxy, animated: Bool) {
        guard !quarter.dates.isEmpty else {
            return
        }

        let startIndex = WorkbenchViewport.clampedStartIndex(
            for: visibleWeekStartDate,
            dates: quarter.dates
        )
        let targetDate = quarter.dates[startIndex]
        if !Calendar.current.isDate(targetDate, inSameDayAs: visibleWeekStartDate) {
            visibleWeekStartDate = targetDate
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(dayAnchorID(for: targetDate), anchor: .leading)
            }
        } else {
            proxy.scrollTo(dayAnchorID(for: targetDate), anchor: .leading)
        }
    }

    @ViewBuilder
    private var timelineContentOriginReader: some View {
        if #available(macOS 15.0, *) {
            Color.clear
        } else {
            globalMinXReader(QuarterHorizontalOffsetPreferenceKey.self)
        }
    }

    private func globalMinXReader<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { geometry in
            Color.clear.preference(key: key, value: geometry.frame(in: .global).minX)
        }
    }

    private func applyTrackedContentMinX(_ contentMinX: CGFloat) {
        timelineContentGlobalMinX = contentMinX
        updateHorizontalOffsetFromGlobalFrames()
    }

    private func applyTrackedHeaderViewportMinX(_ headerMinX: CGFloat) {
        headerViewportGlobalMinX = headerMinX
        updateHorizontalOffsetFromGlobalFrames()
    }

    private func updateHorizontalOffsetFromGlobalFrames() {
        applyHorizontalOffset(timelineContentGlobalMinX - headerViewportGlobalMinX)
    }

    private func applyHorizontalOffset(_ offset: CGFloat) {
        let value = min(offset, 0)
        guard value != horizontalContentOffset else { return }
        horizontalContentOffset = value
        updateVisibleWeekStartDate(forContentOffset: -value)
    }

    private func updateVisibleWeekStartDate(forContentOffset offset: CGFloat) {
        let index = WorkbenchViewport.startIndex(
            forContentOffset: offset,
            columnWidth: dateColumnWidth,
            dateCount: quarter.dates.count
        )
        guard quarter.dates.indices.contains(index) else { return }
        let candidate = quarter.dates[index]
        guard !Calendar.current.isDate(candidate, inSameDayAs: visibleWeekStartDate) else { return }
        visibleWeekStartDate = candidate
    }

    private func laneLabel(_ lane: WorkbenchLane) -> some View {
            HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(lane.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !lane.subtitle.isEmpty {
                    Text(lane.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let count = records(for: lane).count
                Text(count == 0 ? "暂无安排" : "\(count) 项安排")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var monthHeader: some View {
        HStack(spacing: 0) {
            ForEach(monthSegments) { segment in
                Text(segment.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: stickyLabelShift(
                        containerStartX: segment.startX,
                        containerWidth: segment.width,
                        labelWidth: labelWidths["month:\(segment.id)"]
                    ))
                    .padding(.leading, 10)
                    .frame(width: segment.width, height: monthBandHeight, alignment: .leading)
                    .clipped()
                    .background(alignment: .topLeading) {
                        Text(segment.title)
                            .font(.caption.weight(.semibold))
                            .fixedSize()
                            .hidden()
                            .background(labelWidthReader(id: "month:\(segment.id)"))
                    }
                    .background(.bar.opacity(0.88))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(gridSeparator).frame(width: 1)
                    }
            }
        }
        .frame(width: contentWidth, height: monthBandHeight, alignment: .leading)
        .background(.bar.opacity(0.88))
    }

    private var dateHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(quarter.dates.enumerated()), id: \.offset) { index, date in
                VStack(spacing: 3) {
                    Text(weekdayText(for: date))
                        .font(.caption2)
                        .foregroundStyle(isWeekend(date) ? .tertiary : .secondary)
                    Text(monthDayText(for: date))
                        .font(.subheadline.weight(isToday(date) ? .bold : .medium))
                        .foregroundStyle(isToday(date) ? Color.accentColor : .primary)
                }
                .frame(width: dateColumnWidth, height: axisHeaderHeight - monthBandHeight)
                .background(dayBackground(for: date))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(subtleGridSeparator).frame(width: 1)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(gridSeparator).frame(height: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("第 \(index + 1) 天，\(fullDateText(for: date))")
            }
        }
        .frame(width: contentWidth, height: axisHeaderHeight - monthBandHeight, alignment: .leading)
        .background(.bar.opacity(0.82))
    }

    private func laneRow(_ lane: WorkbenchLane, index: Int) -> some View {
        let rowLayout = layout(for: lane)
        let rowHeight = rowHeight(for: lane, layout: rowLayout)
        return ZStack(alignment: .topLeading) {
            dayGridBackground
            ForEach(rowLayout.placements, id: \.id) { placement in
                if let record = rowLayout.records[placement.spanID] {
                    recordCard(record, placement: placement)
                }
            }
        }
        .frame(width: contentWidth, height: rowHeight, alignment: .topLeading)
        .background(rowBackground(index: index))
        .overlay(alignment: .bottom) {
            Rectangle().fill(gridSeparator).frame(height: 1)
        }
    }

    private var dayGridBackground: some View {
        HStack(spacing: 0) {
            ForEach(quarter.dates, id: \.self) { date in
                Rectangle()
                    .fill(dayBackground(for: date))
                    .frame(width: dateColumnWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(subtleGridSeparator).frame(width: 1)
                    }
            }
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private func recordCard(_ record: WorkbenchRenderRecord, placement: WorkbenchTrackPlacement) -> some View {
        let width = max(dateColumnWidth - 8, CGFloat(placement.endDayIndex - placement.startDayIndex + 1) * dateColumnWidth - 8)
        let x = CGFloat(placement.startDayIndex) * dateColumnWidth + 4
        let y = CGFloat(placement.track) * cardHeight + 4
        if let meeting = record.meeting {
            QuarterMeetingEventCard(
                meeting: meeting,
                participantNames: record.participantNames,
                now: now,
                activeMeetingID: activeMeetingID,
                continuesFromPreviousQuarter: placement.continuesFromPreviousQuarter,
                continuesIntoNextQuarter: placement.continuesIntoNextQuarter,
                onSelect: { onSelectMeeting(meeting.id) }
            )
            .frame(width: width, height: cardHeight - 8)
            .offset(x: x, y: y)
        } else if let item = record.workItem {
            QuarterWorkItemBar(
                item: item,
                people: people,
                continuesFromPreviousQuarter: placement.continuesFromPreviousQuarter,
                continuesIntoNextQuarter: placement.continuesIntoNextQuarter,
                textShift: stickyLabelShift(
                    containerStartX: x,
                    containerWidth: width,
                    labelWidth: labelWidths["item:\(record.id)"]
                ),
                labelWidthKey: "item:\(record.id)",
                onSelect: { onSelectWorkItem(item) },
                onStatusChange: { onStatusChange(item, $0) }
            )
            .frame(width: width, height: cardHeight - 8)
            .offset(x: x, y: y)
        }
    }

    private func rowHeight(for lane: WorkbenchLane) -> CGFloat {
        rowHeight(for: lane, layout: layout(for: lane))
    }

    private func rowHeight(for lane: WorkbenchLane, layout: LaneLayout) -> CGFloat {
        layout.placements.isEmpty ? 54 : CGFloat(layout.trackCount) * cardHeight + 8
    }

    private func records(for lane: WorkbenchLane) -> [WorkbenchRenderRecord] {
        var result: [WorkbenchRenderRecord] = []
        for meeting in meetings {
            guard laneContains(meeting: meeting, lane: lane) else { continue }
            let snapshot = participantSnapshots[meeting.id]
            let intervals = MeetingCalendar.effectiveIntervals(
                for: meeting,
                now: now,
                isLive: meeting.id == activeMeetingID
            )
            var addedDays = Set<String>()
            for interval in intervals {
                var date = WorkItemDate.normalized(interval.start)
                while date < interval.end {
                    let key = WorkItemDate.key(date)
                    if addedDays.insert(key).inserted {
                        let id = "meeting:\(meeting.id):\(key):\(lane.id)"
                        result.append(WorkbenchRenderRecord(
                            id: id,
                            span: WorkbenchDateSpan(id: id, kind: .meeting, startDate: date, endDate: date),
                            meeting: meeting,
                            workItem: nil,
                            participantNames: snapshot?.names ?? []
                        ))
                    }
                    guard let next = Calendar.current.date(byAdding: .day, value: 1, to: date) else { break }
                    date = next
                }
            }
        }

        for item in workItems {
            guard laneContains(item: item, lane: lane),
                  let start = item.plannedStartDate ?? item.plannedEndDate,
                  let end = item.plannedEndDate ?? item.plannedStartDate else { continue }
            let id = "work-item:\(item.id):\(lane.id)"
            result.append(WorkbenchRenderRecord(
                id: id,
                span: WorkbenchDateSpan(id: id, kind: .workItem, startDate: start, endDate: end),
                meeting: nil,
                workItem: item,
                participantNames: []
            ))
        }
        return result
    }

    private func layout(for lane: WorkbenchLane) -> LaneLayout {
        let values = records(for: lane)
        let placements = MeetingCalendar.workbenchLayout(
            for: values.map(\.span),
            in: quarter.interval
        )
        return LaneLayout(
            placements: placements,
            records: Dictionary(uniqueKeysWithValues: values.map { ($0.span.id, $0) }),
            trackCount: placements.map(\.trackCount).max() ?? 0
        )
    }

    private func laneContains(meeting: Meeting, lane: WorkbenchLane) -> Bool {
        let snapshot = participantSnapshots[meeting.id]
        return WorkbenchMeetingRouting.belongs(
            meetingID: meeting.id,
            participantPersonIDs: snapshot?.personIDs ?? [],
            lanePersonID: lane.personID,
            laneMode: laneMode,
            activeMeetingID: activeMeetingID,
            currentUserPersonID: currentUserPersonID
        )
    }

    private func laneContains(item: WorkItem, lane: WorkbenchLane) -> Bool {
        guard laneMode == .people else { return true }
        guard let personID = lane.personID else { return false }
        return item.ownerPersonIDs == [personID]
    }

    private var monthGroups: [WorkbenchMonthGroup] {
        var groups: [WorkbenchMonthGroup] = []
        for date in quarter.dates {
            let year = Calendar.current.component(.year, from: date)
            let month = Calendar.current.component(.month, from: date)
            let id = "\(year)-\(month)"
            if let last = groups.last, last.id == id {
                groups[groups.count - 1].dayCount += 1
            } else {
                groups.append(WorkbenchMonthGroup(id: id, title: "\(year)年\(month)月", dayCount: 1))
            }
        }
        return groups
    }

    /// 月份带的切分结果。每个月份格子的宽度必须等于它覆盖的天数乘以日期列宽，
    /// 否则月份分隔线会相对下方日期列逐月偏移。
    private var monthSegments: [WorkbenchMonthSegment] {
        WorkbenchMonthBand.segments(
            monthGroups.map { (id: $0.id, title: $0.title, dayCount: $0.dayCount) },
            columnWidth: dateColumnWidth
        )
    }

    /// 标签跟随视口左缘时的吸附位移。
    private func stickyLabelShift(containerStartX: CGFloat, containerWidth: CGFloat, labelWidth: CGFloat?) -> CGFloat {
        guard let labelWidth, labelWidth > 0 else { return 0 }
        return WorkbenchStickyLabel.shift(
            containerStart: containerStartX,
            containerWidth: containerWidth,
            labelWidth: min(labelWidth, containerWidth),
            contentOffset: horizontalContentOffset
        )
    }

    private func labelWidthReader(id: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: WorkbenchLabelWidthPreferenceKey.self,
                value: [id: geometry.size.width]
            )
        }
    }

    private func dayBackground(for date: Date) -> Color {
        if isToday(date) { return Color.accentColor.opacity(0.075) }
        if isWeekend(date) { return Color.secondary.opacity(0.025) }
        return Color.clear
    }

    private func rowBackground(index: Int) -> Color {
        index.isMultiple(of: 2) ? Color.primary.opacity(0.018) : Color.clear
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    private func isWeekend(_ date: Date) -> Bool {
        [1, 7].contains(Calendar.current.component(.weekday, from: date))
    }

    private func weekdayText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func monthDayText(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    private func fullDateText(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}

struct WorkbenchLane: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let personID: VoiceprintPerson.ID?
}

private struct WorkbenchMonthGroup: Identifiable {
    let id: String
    let title: String
    var dayCount: Int
}

/// 月份带上一个月份格子的位置与宽度（内容坐标系）。
struct WorkbenchMonthSegment: Identifiable, Equatable {
    let id: String
    let title: String
    let startX: CGFloat
    let width: CGFloat
}

enum WorkbenchMonthBand {
    /// 把「每月天数」切成连续的格子：宽度严格等于天数 × 列宽，起点逐月累加，
    /// 保证月份分隔线与下方日期列对齐。
    static func segments(
        _ months: [(id: String, title: String, dayCount: Int)],
        columnWidth: CGFloat
    ) -> [WorkbenchMonthSegment] {
        var result: [WorkbenchMonthSegment] = []
        var startX: CGFloat = 0
        for month in months {
            let width = CGFloat(max(0, month.dayCount)) * columnWidth
            result.append(WorkbenchMonthSegment(id: month.id, title: month.title, startX: startX, width: width))
            startX += width
        }
        return result
    }
}

/// 横向滚动时把标签固定在视口左缘的位移。
enum WorkbenchStickyLabel {
    /// - Parameters:
    ///   - containerStart: 容器（任务条或月份格子）在内容坐标系里的起点
    ///   - containerWidth: 容器宽度
    ///   - labelWidth: 标签内容的自然宽度
    ///   - contentOffset: 当前水平滚动偏移（≤0，内容整体左移的量）
    ///   - trailingPadding: 标签右侧至少保留的内边距
    /// - Returns: 标签需要额外向右偏移的距离，保证标签不越过容器右端。
    static func shift(
        containerStart: CGFloat,
        containerWidth: CGFloat,
        labelWidth: CGFloat,
        contentOffset: CGFloat,
        trailingPadding: CGFloat = 10
    ) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        let followingViewport = max(0, -(containerStart + contentOffset))
        let maximumShift = max(0, containerWidth - labelWidth - trailingPadding)
        return min(followingViewport, maximumShift)
    }
}

private struct WorkbenchLabelWidthPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct WorkbenchRenderRecord {
    let id: String
    let span: WorkbenchDateSpan
    let meeting: Meeting?
    let workItem: WorkItem?
    let participantNames: [String]
}

private struct LaneLayout {
    let placements: [WorkbenchTrackPlacement]
    let records: [String: WorkbenchRenderRecord]
    let trackCount: Int
}

private struct QuarterHorizontalOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct QuarterHeaderOriginPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct QuarterMeetingEventCard: View {
    let meeting: Meeting
    let participantNames: [String]
    let now: Date
    let activeMeetingID: Meeting.ID?
    let continuesFromPreviousQuarter: Bool
    let continuesIntoNextQuarter: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    private var activity: WorkbenchMeetingActivity {
        WorkbenchMeetingActivity(meeting: meeting, activeMeetingID: activeMeetingID)
    }

    private var accentColor: Color {
        activity.isRecording ? .red : .cyan
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if activity.isRecording {
                        Image(systemName: activity.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating)
                            .accessibilityLabel("正在录音")
                    } else {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(meeting.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(participantNames.isEmpty ? "待确认人员" : participantNames.joined(separator: "、"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(timeText)
                    Text("·")
                    Text(activity.isRecording ? activity.label : meeting.status.displayName)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(activity.isRecording ? Color.red : Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(accentColor.opacity(activity.isRecording ? 0.14 : 0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accentColor.opacity(activity.isRecording ? 0.72 : 0.44), lineWidth: activity.isRecording ? 1.25 : 1)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(accentColor).frame(width: 4).padding(.vertical, 8)
            }
            .shadow(
                color: accentColor.opacity(activity.isRecording ? 0.16 : 0.08),
                radius: isHovering ? 7 : 3,
                y: isHovering ? 3 : 1
            )
            .scaleEffect(isHovering ? 1.01 : 1)
        }
        .buttonStyle(WorkbenchCardButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(
            "会议：\(meeting.title)，\(participantNames.joined(separator: "、"))，\(timeText)，\(activity.isRecording ? activity.label : meeting.status.displayName)"
        )
        .help(
            continuesFromPreviousQuarter || continuesIntoNextQuarter
                ? "会议跨季度"
                : activity.isRecording ? "打开正在录音的会议" : "打开会议详情"
        )
    }

    private var timeText: String {
        let intervals = MeetingCalendar.effectiveIntervals(
            for: meeting,
            now: now,
            isLive: meeting.id == activeMeetingID
        )
        guard let first = intervals.first, let last = intervals.last else { return "未安排时间" }
        return "\(timeFormatter.string(from: first.start))-\(timeFormatter.string(from: last.end))"
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}

private struct QuarterWorkItemBar: View {
    let item: WorkItem
    let people: [VoiceprintPerson]
    let continuesFromPreviousQuarter: Bool
    let continuesIntoNextQuarter: Bool
    /// 跨天任务条横向滚动时，文字块跟随视口左缘的位移。
    let textShift: CGFloat
    /// 文字块自然宽度的偏好键，用于计算吸附位移的上限。
    let labelWidthKey: String
    let onSelect: () -> Void
    let onStatusChange: (WorkItemStatus) -> Void

    var body: some View {
        Button(action: onSelect) {
            textBlock
                .offset(x: textShift)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(alignment: .topLeading) {
                    // 按自然宽度测量一份隐藏副本，吸附位移需要知道文字块有多宽。
                    textBlock
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: WorkbenchLabelWidthPreferenceKey.self,
                                    value: [labelWidthKey: geometry.size.width]
                                )
                            }
                        }
                }
                .background(Color.purple.opacity(0.19), in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(statusColor.opacity(0.60), lineWidth: 1)
                }
                .shadow(color: Color.purple.opacity(0.08), radius: 5, y: 2)
                .opacity(item.status == .cancelled ? 0.56 : 1)
        }
        .buttonStyle(WorkbenchCardButtonStyle())
        .contextMenu {
            ForEach(WorkItemStatus.allCases, id: \.self) { status in
                Button(status.displayName) { onStatusChange(status) }
            }
        }
        .accessibilityLabel("任务：\(item.title)，\(ownerText)，\(item.priority.displayName)优先级，标签：\(item.tags.joined(separator: "、"))，\(item.status.displayName)")
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Capsule().fill(statusColor).frame(width: 4)
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if item.priority == .high {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            Text(ownerText)
                .font(.caption2)
                .foregroundStyle(ownerColor)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(item.priority.displayName + "优先级")
                if !item.tags.isEmpty {
                    Text("·")
                    Text(item.tags.joined(separator: "、"))
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(item.status.displayName)
                if item.isOverdue() { Text("· 已逾期").foregroundStyle(.red) }
                if continuesFromPreviousQuarter { Text("←") }
                if continuesIntoNextQuarter { Text("→") }
            }
            .font(.caption2)
            .foregroundStyle(item.isOverdue() ? .red : statusColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private var ownerText: String {
        if let ownerID = item.ownerPersonIDs.first,
           let owner = people.first(where: { $0.id == ownerID }) {
            return owner.displayName
        }
        return item.ownerNameHints.isEmpty ? "负责人待确认" : "待匹配：" + item.ownerNameHints.joined(separator: "、")
    }

    private var ownerColor: Color {
        item.ownerPersonIDs.count == 1 ? .secondary : .orange
    }

    private var statusColor: Color {
        switch item.status {
        case .pendingConfirmation: .orange
        case .notStarted: .secondary
        case .inProgress: .blue
        case .completed: .green
        case .cancelled: .secondary
        }
    }
}

private struct WorkbenchCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
