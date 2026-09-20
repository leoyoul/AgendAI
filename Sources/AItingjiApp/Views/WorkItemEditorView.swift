import AItingjiCore
import SwiftUI

struct WorkItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkItem
    @State private var hasStartDate: Bool
    @State private var hasEndDate: Bool
    @State private var tagText: String
    @State private var selectedOwnerID: String
    @State private var validationMessage = ""

    let people: [VoiceprintPerson]
    /// 返回 nil 表示保存成功，否则返回可直接展示的失败原因。
    let onSave: (WorkItem) -> String?
    let onDelete: () -> Void
    let onOpenSourceMeeting: (Meeting.ID) -> Void
    let onCancel: () -> Void

    init(
        item: WorkItem,
        people: [VoiceprintPerson],
        onSave: @escaping (WorkItem) -> String?,
        onDelete: @escaping () -> Void,
        onOpenSourceMeeting: @escaping (Meeting.ID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: item)
        _hasStartDate = State(initialValue: item.plannedStartDate != nil)
        _hasEndDate = State(initialValue: item.plannedEndDate != nil)
        _tagText = State(initialValue: item.tags.joined(separator: ", "))
        _selectedOwnerID = State(initialValue: item.ownerPersonIDs.first ?? "")
        self.people = people.filter(\.isActive)
        self.onSave = onSave
        self.onDelete = onDelete
        self.onOpenSourceMeeting = onOpenSourceMeeting
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(draft.source == .manual ? "编辑个人任务" : "编辑工作台任务", systemImage: "checklist")
                .font(.title2.bold())

            Form {
                Section("基本信息") {
                    TextField("任务标题", text: $draft.title)
                    TextField("详情", text: $draft.detail, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("交付物", text: $draft.deliverable)
                    TextField("验收标准", text: $draft.acceptanceCriteria, axis: .vertical)
                        .lineLimit(3...5)
                }

                Section("负责人") {
                    if people.isEmpty {
                        Text("人员库暂无可用人员，无法保存任务。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("唯一负责人", selection: $selectedOwnerID) {
                            Text("请选择负责人").tag("")
                            ForEach(people) { person in
                                Text(person.displayName).tag(person.id)
                            }
                        }
                        .onChange(of: selectedOwnerID) { _, newValue in
                            draft.ownerPersonIDs = newValue.isEmpty ? [] : [newValue]
                        }
                    }
                    if !draft.ownerNameHints.isEmpty {
                        Text("待匹配：\(draft.ownerNameHints.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(draft.status == .pendingConfirmation
                        ? "确认任务前可先保留负责人待确认。"
                        : "进入工作台的任务必须选择一名人员库中的唯一负责人。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("计划日期") {
                    Toggle("设置开始日期", isOn: $hasStartDate)
                        .onChange(of: hasStartDate) { _, isSet in
                            guard isSet else { return }
                            let startDate = WorkItemDate.normalized(
                                draft.plannedStartDate ?? draft.plannedEndDate ?? Date()
                            )
                            draft.plannedStartDate = startDate
                            if !hasEndDate || draft.plannedEndDate == nil {
                                draft.plannedEndDate = WorkItemDate.addingDays(startDate, 7)
                                hasEndDate = true
                            }
                        }
                    if hasStartDate {
                        DatePicker(
                            "计划开始",
                            selection: Binding(
                                get: { draft.plannedStartDate ?? draft.plannedEndDate ?? Date() },
                                set: {
                                    let startDate = WorkItemDate.normalized($0)
                                    draft.plannedStartDate = startDate
                                    if !hasEndDate || draft.plannedEndDate == nil {
                                        draft.plannedEndDate = WorkItemDate.addingDays(startDate, 7)
                                        hasEndDate = true
                                    }
                                }
                            ),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.field)
                    }
                    Toggle("设置结束日期", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker(
                            "计划结束",
                            selection: Binding(
                                get: { draft.plannedEndDate ?? draft.plannedStartDate ?? Date() },
                                set: { draft.plannedEndDate = WorkItemDate.normalized($0) }
                            ),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.field)
                    }
                }

                Section("跟踪") {
                    Picker("状态", selection: $draft.status) {
                        ForEach(WorkItemStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    Picker("优先级", selection: $draft.priority) {
                        ForEach(WorkItemPriority.allCases, id: \.self) { priority in
                            Text(priority.displayName).tag(priority)
                        }
                    }
                    TextField("标签（用逗号分隔）", text: $tagText)
                    TextField("完成备注 / 成果说明", text: $draft.completionNote, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)

            if let sourceTitle = draft.sourceMeetingTitle {
                Button {
                    if let meetingID = draft.sourceMeetingID {
                        onOpenSourceMeeting(meetingID)
                        dismiss()
                    }
                } label: {
                    Label("打开来源会议：\(sourceTitle)", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack {
                Button("删除任务", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Button("保存") {
                    draft.plannedStartDate = hasStartDate ? WorkItemDate.normalized(draft.plannedStartDate ?? Date()) : nil
                    draft.plannedEndDate = hasEndDate ? WorkItemDate.normalized(draft.plannedEndDate ?? draft.plannedStartDate ?? Date()) : nil
                    draft.tags = tagText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if draft.status != .pendingConfirmation && draft.ownerPersonIDs.count != 1 {
                        validationMessage = "请选择唯一负责人后再保存。"
                        return
                    }
                    if let failureReason = onSave(draft) {
                        validationMessage = failureReason
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if !validationMessage.isEmpty {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 620)
    }

}
