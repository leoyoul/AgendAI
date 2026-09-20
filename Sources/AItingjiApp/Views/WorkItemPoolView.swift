import AItingjiCore
import SwiftUI

struct WorkItemPoolView: View {
    @Environment(AppState.self) private var appState
    let onSelectMeeting: (Meeting.ID) -> Void

    @State private var editingItem: WorkItem?
    @State private var selectedWorkItemIDs: Set<WorkItem.ID> = []
    @State private var pendingDeletionIDs: Set<WorkItem.ID> = []
    @State private var showsBatchDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if appState.pendingConfirmationWorkItems.isEmpty {
                ContentUnavailableView {
                    Label("待办任务池为空", systemImage: "checkmark.circle")
                } description: {
                    Text("新生成的会议任务、未确认负责人或未确认截止日期的任务会显示在这里。")
                } actions: {
                    Button("新建任务") {
                        _ = appState.createManualWorkItem()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.pendingConfirmationWorkItems) { item in
                            WorkItemPoolRow(
                                item: item,
                                people: appState.people,
                                isSelected: selectedWorkItemIDs.contains(item.id),
                                onSelectionChange: { isSelected in
                                    if isSelected {
                                        selectedWorkItemIDs.insert(item.id)
                                    } else {
                                        selectedWorkItemIDs.remove(item.id)
                                    }
                                },
                                onUpdate: { updated in
                                    appState.updateWorkItem(updated)
                                },
                                onConfirm: { itemID in
                                    appState.confirmWorkItem(itemID)
                                },
                                onCancel: { itemID in
                                    appState.setWorkItemStatus(itemID, status: .cancelled)
                                },
                                onDelete: { itemID in
                                    if appState.deleteWorkItem(itemID) {
                                        selectedWorkItemIDs.remove(itemID)
                                    }
                                },
                                onOpenDetails: { editingItem = $0 },
                                onOpenSourceMeeting: onSelectMeeting
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingItem) { item in
            WorkItemEditorView(
                item: item,
                people: appState.people,
                onSave: { appState.updateWorkItem($0) ? nil : appState.statusMessage },
                onDelete: {
                    if appState.deleteWorkItem(item.id) {
                        selectedWorkItemIDs.remove(item.id)
                    }
                    editingItem = nil
                },
                onOpenSourceMeeting: { meetingID in
                    editingItem = nil
                    onSelectMeeting(meetingID)
                },
                onCancel: { editingItem = nil }
            )
        }
        .onChange(of: pendingWorkItemIDs) { _, ids in
            let visibleIDs = Set(ids)
            selectedWorkItemIDs.formIntersection(visibleIDs)
            pendingDeletionIDs.formIntersection(visibleIDs)
        }
        .alert("删除所选任务？", isPresented: $showsBatchDeleteConfirmation) {
            Button("删除 \(pendingDeletionIDs.count) 项", role: .destructive) {
                let ids = Array(pendingDeletionIDs)
                guard appState.deleteWorkItems(ids) else { return }
                selectedWorkItemIDs.subtract(ids)
                pendingDeletionIDs.removeAll()
            }
            Button("取消", role: .cancel) {
                pendingDeletionIDs.removeAll()
            }
        } message: {
            Text("删除后无法恢复这些任务及其关联来源记录。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待办任务池")
                        .font(.largeTitle.bold())
                    Text("先确认负责人和截止日期，再进入工作台日历")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text("待确认 \(appState.pendingConfirmationWorkItems.count) 项")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .accessibilityLabel("待确认任务 \(appState.pendingConfirmationWorkItems.count) 项")
                if !appState.pendingConfirmationWorkItems.isEmpty {
                    Toggle(
                        allWorkItemsSelected ? "取消全选" : "全选",
                        isOn: allWorkItemsSelectionBinding
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(allWorkItemsSelected ? "取消全选待确认任务" : "全选待确认任务")
                }
                if !selectedWorkItemIDs.isEmpty {
                    Button("删除所选 (\(selectedWorkItemIDs.count))", role: .destructive) {
                        requestBatchDeletion()
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    _ = appState.createManualWorkItem()
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.isPersistenceAvailable)
            }

            HStack(spacing: 14) {
                Text("标题、负责人和截止日期可直接在列表中修改")
                Text("确认后任务会自动进入工作台")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.bar.opacity(0.72))
    }

    private var pendingWorkItemIDs: [WorkItem.ID] {
        appState.pendingConfirmationWorkItems.map(\.id)
    }

    private var allWorkItemsSelected: Bool {
        !pendingWorkItemIDs.isEmpty
            && selectedWorkItemIDs.isSuperset(of: pendingWorkItemIDs)
    }

    private var allWorkItemsSelectionBinding: Binding<Bool> {
        Binding(
            get: { allWorkItemsSelected },
            set: { shouldSelectAll in
                if shouldSelectAll {
                    selectedWorkItemIDs.formUnion(pendingWorkItemIDs)
                } else {
                    selectedWorkItemIDs.subtract(pendingWorkItemIDs)
                }
            }
        )
    }

    private func requestBatchDeletion() {
        let visibleIDs = Set(pendingWorkItemIDs)
        let ids = selectedWorkItemIDs.intersection(visibleIDs)
        guard !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        showsBatchDeleteConfirmation = true
    }
}

private struct WorkItemPoolRow: View {
    @State private var draft: WorkItem
    @State private var persistedTitle: String
    @State private var validationMessage = ""
    @FocusState private var isTitleFocused: Bool

    let people: [VoiceprintPerson]
    let isSelected: Bool
    let onSelectionChange: (Bool) -> Void
    let onUpdate: (WorkItem) -> Bool
    let onConfirm: (WorkItem.ID) -> Bool
    let onCancel: (WorkItem.ID) -> Bool
    let onDelete: (WorkItem.ID) -> Void
    let onOpenDetails: (WorkItem) -> Void
    let onOpenSourceMeeting: (Meeting.ID) -> Void

    init(
        item: WorkItem,
        people: [VoiceprintPerson],
        isSelected: Bool,
        onSelectionChange: @escaping (Bool) -> Void,
        onUpdate: @escaping (WorkItem) -> Bool,
        onConfirm: @escaping (WorkItem.ID) -> Bool,
        onCancel: @escaping (WorkItem.ID) -> Bool,
        onDelete: @escaping (WorkItem.ID) -> Void,
        onOpenDetails: @escaping (WorkItem) -> Void,
        onOpenSourceMeeting: @escaping (Meeting.ID) -> Void
    ) {
        _draft = State(initialValue: item)
        _persistedTitle = State(initialValue: item.title)
        self.people = people.filter(\.isActive)
        self.isSelected = isSelected
        self.onSelectionChange = onSelectionChange
        self.onUpdate = onUpdate
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onOpenDetails = onOpenDetails
        self.onOpenSourceMeeting = onOpenSourceMeeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Toggle("选择任务", isOn: selectionBinding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("选择任务：\(draft.title)")

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        TextField("任务标题", text: $draft.title)
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .lineLimit(1)
                            .focused($isTitleFocused)
                            .onSubmit { saveTitle() }
                            .onChange(of: isTitleFocused) { _, isFocused in
                                if !isFocused { saveTitle() }
                            }
                            .accessibilityLabel("任务标题")
                        Text(draft.source.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }

                    if let meetingTitle = draft.sourceMeetingTitle {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text("来源会议：\(meetingTitle)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if !draft.ownerNameHints.isEmpty {
                        Text("原始负责人：\(draft.ownerNameHints.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let sourceDeadlineText = draft.sourceDeadlineText, !sourceDeadlineText.isEmpty {
                        Text("原始截止日期：\(sourceDeadlineText)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(confirmationReason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)

                Divider()

                ownerEditor
                    .frame(width: 190, alignment: .leading)

                dateEditor
                    .frame(width: 290, alignment: .leading)

                VStack(alignment: .trailing, spacing: 7) {
                    Button("确认并进入日历") {
                        guard saveDraft() else { return }
                        if !onConfirm(draft.id) {
                            validationMessage = "确认失败，请检查负责人和截止日期。"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)

                    Button("详情") {
                        onOpenDetails(draft)
                    }
                    .buttonStyle(.link)

                    HStack(spacing: 10) {
                        Menu {
                        if let meetingID = draft.sourceMeetingID {
                            Button("打开来源会议") {
                                onOpenSourceMeeting(meetingID)
                            }
                        }
                        Button("取消任务", role: .destructive) {
                            if !onCancel(draft.id) {
                                validationMessage = "取消前请先补充有效截止日期。"
                            }
                        }
                        .disabled(!canConfirm)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                        .menuStyle(.borderlessButton)

                        Button(role: .destructive) {
                            onDelete(draft.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("删除任务")
                        .accessibilityLabel("删除任务：\(draft.title)")
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }

            DisclosureGroup("查看详情") {
                VStack(alignment: .leading, spacing: 6) {
                    detailLine("详情", draft.detail)
                    detailLine("交付物", draft.deliverable)
                    detailLine("验收标准", draft.acceptanceCriteria)
                    if !draft.tags.isEmpty {
                        detailLine("标签", draft.tags.joined(separator: "、"))
                    }
                }
                .padding(.top, 8)
            }
            .font(.caption)

            if !validationMessage.isEmpty {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.42), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("待确认任务：\(draft.title)，\(confirmationReason)")
    }

    private var ownerEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("负责人")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if people.isEmpty {
                Text("暂无启用人员")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Picker("负责人", selection: ownerBinding) {
                    Text("请选择负责人").tag("")
                    ForEach(people) { person in
                        Text(person.displayName).tag(person.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var dateEditor: some View {
        HStack(spacing: 12) {
            dateField(title: "开始", date: startDateBinding, isSet: draft.plannedStartDate != nil)
            dateField(title: "截止", date: endDateBinding, isSet: draft.plannedEndDate != nil)
        }
    }

    private func dateField(title: String, date: Binding<Date>, isSet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !isSet {
                    Text("未设置")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            DatePicker(title, selection: date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
        }
    }

    private var ownerBinding: Binding<String> {
        Binding(
            get: { draft.ownerPersonIDs.first ?? "" },
            set: { value in
                var candidate = draft
                candidate.ownerPersonIDs = value.isEmpty ? [] : [value]
                if !value.isEmpty { candidate.ownerNameHints = [] }
                save(candidate)
            }
        )
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { isSelected },
            set: { newValue in
                onSelectionChange(newValue)
            }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { draft.plannedStartDate ?? draft.plannedEndDate ?? Date() },
            set: { value in
                var candidate = draft
                let startDate = WorkItemDate.normalized(value)
                candidate.plannedStartDate = startDate
                if candidate.plannedEndDate == nil {
                    candidate.plannedEndDate = WorkItemDate.addingDays(startDate, 7)
                }
                save(candidate)
            }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { draft.plannedEndDate ?? draft.plannedStartDate ?? Date() },
            set: { value in
                var candidate = draft
                candidate.plannedEndDate = WorkItemDate.normalized(value)
                save(candidate)
            }
        )
    }

    private var canConfirm: Bool {
        guard draft.ownerPersonIDs.count == 1,
              let ownerID = draft.ownerPersonIDs.first,
              people.contains(where: { $0.id == ownerID }),
              let end = draft.plannedEndDate else { return false }
        let start = draft.plannedStartDate ?? end
        return WorkItemDate.normalized(start) <= WorkItemDate.normalized(end)
    }

    private var confirmationReason: String {
        guard draft.ownerPersonIDs.count == 1,
              let ownerID = draft.ownerPersonIDs.first,
              people.contains(where: { $0.id == ownerID }) else {
            return "待确认负责人"
        }
        guard let end = draft.plannedEndDate else { return "待确认截止日期" }
        let start = draft.plannedStartDate ?? end
        guard WorkItemDate.normalized(start) <= WorkItemDate.normalized(end) else {
            return "日期范围错误"
        }
        return "信息已齐全，可以确认"
    }

    @discardableResult
    private func saveDraft() -> Bool {
        save(draft)
    }

    /// 行内标题：回车或失焦时提交。标题不允许为空，
    /// 提交失败时还原为上次成功保存的标题，避免列表中留下空标题。
    private func saveTitle() {
        var candidate = draft
        candidate.title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.title.isEmpty else {
            draft.title = persistedTitle
            validationMessage = "任务标题不能为空，已还原。"
            return
        }
        guard candidate.title != persistedTitle else {
            draft.title = persistedTitle
            return
        }
        save(candidate)
    }

    @discardableResult
    private func save(_ candidate: WorkItem) -> Bool {
        guard onUpdate(candidate) else {
            validationMessage = "修改未保存，请检查日期范围。"
            return false
        }
        draft = candidate
        persistedTitle = candidate.title
        validationMessage = ""
        return true
    }

    @ViewBuilder
    private func detailLine(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            Text("\(title)：\(value)")
                .foregroundStyle(.secondary)
        }
    }
}
