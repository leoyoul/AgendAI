import AItingjiCore
import SwiftUI

struct WeekCalendarToolbar: View {
    @Binding var displayedQuarterDate: Date
    let quarter: MeetingCalendarQuarter
    let calendar: Calendar
    let people: [VoiceprintPerson]
    let visibleWeekStartDate: Date
    @Binding var laneMode: WorkbenchLaneMode
    @Binding var workItemFilter: WorkItemFilter
    let onToday: () -> Void
    let onQuarterChange: (Date) -> Void
    let onCreateWorkItem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayoutMetrics.Workbench.toolbarRowSpacing) {
            HStack(alignment: .center, spacing: AppLayoutMetrics.Workbench.toolbarGroupSpacing) {
                titleRow
                Spacer(minLength: AppLayoutMetrics.Workbench.toolbarGroupSpacing)
                toolbarActions
            }
            .frame(height: AppLayoutMetrics.Workbench.controlHeight)

            HStack(alignment: .center, spacing: AppLayoutMetrics.Workbench.controlSpacing) {
                toolbarControls
                Divider()
                    .frame(height: AppLayoutMetrics.Workbench.toolbarDividerHeight)
                toolbarLegend
                Spacer(minLength: 0)
            }
            .frame(height: AppLayoutMetrics.Workbench.controlHeight)
        }
        .padding(.horizontal, AppLayoutMetrics.Workbench.toolbarHorizontalPadding)
        .padding(.vertical, AppLayoutMetrics.Workbench.toolbarVerticalPadding)
        .background(.bar)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppLayoutMetrics.Workbench.toolbarGroupSpacing) {
            Text("个人工作台")
                .font(AppTypography.workbenchTitle)
                .lineLimit(1)
            Text("\(quarter.displayName) · \(dateRange)")
                .font(AppTypography.workbenchSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var toolbarActions: some View {
        HStack(alignment: .center, spacing: AppLayoutMetrics.Workbench.toolbarActionSpacing) {
            Button("今天", action: onToday)
                .buttonStyle(WorkbenchToolbarButtonStyle(emphasis: .neutral))
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help("回到今天")

            Button(action: onCreateWorkItem) {
                Label("新建任务", systemImage: "plus")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .buttonStyle(WorkbenchToolbarButtonStyle(emphasis: .prominent))
        }
    }

    private var toolbarControls: some View {
        HStack(alignment: .center, spacing: AppLayoutMetrics.Workbench.controlSpacing) {
            quarterPicker
            filterMenu
            axisPicker
        }
    }

    private var axisPicker: some View {
        segmentedControl(width: 150) {
            ForEach(WorkbenchLaneMode.allCases, id: \.self) { mode in
                Button {
                    laneMode = mode
                } label: {
                    segmentLabel(mode.displayName, isSelected: laneMode == mode)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("纵轴模式")
    }

    private var toolbarLegend: some View {
        HStack(spacing: AppLayoutMetrics.Workbench.toolbarLegendSpacing) {
            legendItem(color: .cyan, title: "会议")
            legendItem(color: .purple, title: "工作项")
            legendItem(color: .red, title: "已逾期")
        }
        .font(AppTypography.workbenchLegend)
        .foregroundStyle(.secondary)
        .frame(height: AppLayoutMetrics.Workbench.controlHeight, alignment: .center)
        .fixedSize()
    }

    private var quarterPicker: some View {
        segmentedControl(width: 132) {
            ForEach(1...4, id: \.self) { number in
                Button {
                    let year = calendar.component(.year, from: quarter.interval.start)
                    let targetDate = calendar.date(
                        from: DateComponents(year: year, month: (number - 1) * 3 + 1, day: 1)
                    ) ?? displayedQuarterDate
                    onQuarterChange(targetDate)
                    displayedQuarterDate = targetDate
                } label: {
                    segmentLabel("Q\(number)", isSelected: quarter.number == number)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("季度切换")
    }

    private var filterMenu: some View {
        Menu {
            TextField("搜索标题、详情或标签", text: $workItemFilter.query)

            Section("状态") {
                ForEach(WorkItemStatus.allCases.filter { $0 != .pendingConfirmation }, id: \.self) { status in
                    Toggle(status.displayName, isOn: statusBinding(status))
                }
            }

            Section("优先级") {
                ForEach(WorkItemPriority.allCases, id: \.self) { priority in
                    Toggle(priority.displayName, isOn: priorityBinding(priority))
                }
            }

            if !people.isEmpty {
                Section("负责人") {
                    ForEach(people.filter(\.isActive)) { person in
                        Toggle(person.displayName, isOn: ownerBinding(person.id))
                    }
                }
            }

            Divider()
            Button("清除筛选") {
                workItemFilter = WorkItemFilter()
            }
        } label: {
            HStack(spacing: AppLayoutMetrics.Workbench.controlContentSpacing) {
                Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text("筛选")
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(AppTypography.workbenchControl)
            .foregroundStyle(hasActiveFilter ? Color.accentColor : Color.primary)
            .padding(.horizontal, AppLayoutMetrics.Workbench.controlHorizontalPadding)
            .frame(width: 104, height: AppLayoutMetrics.Workbench.controlHeight)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 104, height: AppLayoutMetrics.Workbench.controlHeight)
        .fixedSize()
        .help("筛选工作台任务")
    }

    private func segmentedControl<Content: View>(
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: AppLayoutMetrics.Workbench.segmentSpacing) {
            content()
        }
        .padding(AppLayoutMetrics.Workbench.segmentedControlPadding)
        .frame(width: width, height: AppLayoutMetrics.Workbench.controlHeight)
        .background(
            Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius)
        )
    }

    private func segmentLabel(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(AppTypography.workbenchControl.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius - 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius - 1))
    }

    private var hasActiveFilter: Bool {
        !workItemFilter.query.isEmpty
            || !workItemFilter.statuses.isEmpty
            || !workItemFilter.ownerPersonIDs.isEmpty
            || !workItemFilter.priorities.isEmpty
            || workItemFilter.startDate != nil
            || workItemFilter.endDate != nil
    }

    private func statusBinding(_ status: WorkItemStatus) -> Binding<Bool> {
        Binding(
            get: { workItemFilter.statuses.contains(status) },
            set: { enabled in
                if enabled { workItemFilter.statuses.insert(status) }
                else { workItemFilter.statuses.remove(status) }
            }
        )
    }

    private func priorityBinding(_ priority: WorkItemPriority) -> Binding<Bool> {
        Binding(
            get: { workItemFilter.priorities.contains(priority) },
            set: { enabled in
                if enabled { workItemFilter.priorities.insert(priority) }
                else { workItemFilter.priorities.remove(priority) }
            }
        )
    }

    private func ownerBinding(_ ownerID: VoiceprintPerson.ID) -> Binding<Bool> {
        Binding(
            get: { workItemFilter.ownerPersonIDs.contains(ownerID) },
            set: { enabled in
                if enabled { workItemFilter.ownerPersonIDs.insert(ownerID) }
                else { workItemFilter.ownerPersonIDs.remove(ownerID) }
            }
        )
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }

    private var dateRange: String {
        let startIndex = WorkbenchViewport.clampedStartIndex(
            for: visibleWeekStartDate,
            dates: quarter.dates,
            calendar: calendar
        )
        let visibleDates = WorkbenchViewport.visibleDates(startingAt: startIndex, in: quarter.dates)
        guard let first = visibleDates.first, let last = visibleDates.last else {
            return "暂无日期"
        }
        return "\(monthDayText(first))—\(monthDayText(last))"
    }

    private func monthDayText(_ date: Date) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}

private enum WorkbenchToolbarButtonEmphasis {
    case neutral
    case prominent
}

private struct WorkbenchToolbarButtonStyle: ButtonStyle {
    let emphasis: WorkbenchToolbarButtonEmphasis

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.workbenchControl)
            .foregroundStyle(emphasis == .prominent ? Color.white : Color.primary)
            .padding(.horizontal, AppLayoutMetrics.Workbench.controlHorizontalPadding)
            .frame(height: AppLayoutMetrics.Workbench.controlHeight)
            .background(
                emphasis == .prominent ? Color.accentColor : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius))
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
