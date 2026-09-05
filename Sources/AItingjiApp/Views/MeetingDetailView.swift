import AItingjiCore
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    @State private var titleText = ""
    @State private var showsMinutesPromptSheet = false
    @State private var additionalMinutesPrompt = ""
    @State private var selectedTab: MeetingDetailTab = .recording
    @State private var showsImageImporter = false
    @State private var imageImporterNoteID: MeetingNote.ID?
    let meeting: Meeting
    let onOpenMeeting: (Meeting.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if appState.isPostprocessingSelectedMeeting {
                    PostprocessingLockBanner()
                } else if appState.isSelectedMeetingContentLocked {
                    MeetingContentLockBanner(meeting: meeting)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Picker("会议详情", selection: $selectedTab) {
                ForEach(MeetingDetailTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 760)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            Divider()

            tabContentContainer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            titleText = meeting.title
            if meeting.captureSource == .imported {
                selectedTab = .transcript
            }
        }
        .sheet(isPresented: $showsMinutesPromptSheet) {
            MeetingMinutesPromptSheet(
                prompt: $additionalMinutesPrompt,
                onCancel: { showsMinutesPromptSheet = false },
                onGenerate: {
                    showsMinutesPromptSheet = false
                    appState.generateSelectedMeetingMinutes(additionalPrompt: additionalMinutesPrompt)
                }
            )
        }
        .fileImporter(
            isPresented: $showsImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handleImageImport
        )
        .onChange(of: meeting.title) { _, newTitle in
            titleText = newTitle
        }
    }

    @ViewBuilder
    private var tabContentContainer: some View {
        if selectedTab == .agent {
            MeetingAgentChatView(meeting: meeting)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                selectedTabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .recording:
            VStack(alignment: .leading, spacing: 20) {
                PermissionBannerView()
                RecordingControlsView(meetingID: meeting.id)
                MeetingAudioPlaybackView(meeting: meeting)
                transcriptPanel
            }
        case .transcript:
            exportPanel
        case .minutes:
            meetingMinutesPanel
        case .analysis:
            meetingAnalysisPanel
        case .notes:
            meetingNotesPanel
        case .agent:
            EmptyView()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("会议标题", text: $titleText)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)
                    .disabled(appState.isSelectedMeetingContentLocked)
                    .onSubmit {
                        appState.updateSelectedMeetingTitle(titleText)
                    }
                Text("状态：\(meeting.status.displayName) · 来源：\(meeting.captureSource.displayName)")
                    .foregroundStyle(.secondary)
                Text("音频：\(meeting.audioFilePath == nil ? "未保存" : "已保存")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("保存标题") {
                        appState.updateSelectedMeetingTitle(titleText)
                    }
                    .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isSelectedMeetingContentLocked)
                    Text(appState.isSelectedMeetingContentLocked ? "当前会议暂不可编辑。" : "标题会自动同步到左侧列表和导出预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if appState.shouldShowSelectedMeetingRecordingTimer {
                    recordingTimer
                        .padding(.bottom, 6)
                }
                Text("本地优先")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.green.opacity(0.14), in: Capsule())
                Text(meeting.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingTimer: some View {
        let isPaused = appState.recordingStartupState == .paused
        let isStarting = appState.recordingStartupState == .starting
        let accentColor: Color = isPaused ? .orange : .red
        let label = isPaused ? "录制已暂停" : (isStarting ? "准备录制" : "录制时间")
        let elapsedTime = RecordingControlPresentation.formattedElapsedTime(
            milliseconds: appState.recordingElapsedMs
        )

        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.title2)
                    .foregroundStyle(accentColor)
                Text(elapsedTime)
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(elapsedTime)")
    }

    private var transcriptPanel: some View {
        let displayGroups = TranscriptDisplayGrouper.group(appState.selectedSegments)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时记录", systemImage: "text.bubble")
                    .font(.title2.bold())
            }

            if appState.selectedSegments.isEmpty {
                ContentUnavailableView("还没有转写片段", systemImage: "text.quote")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 10) {
                    ForEach(displayGroups) { group in
                        TranscriptDisplayGroupRow(group: group)
                    }
                }
            }
        }
        .panelStyle()
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("转写记录导出", systemImage: "doc.plaintext")
                    .font(.title2.bold())
                Spacer()
                Button {
                    appState.chooseTranscriptFileForImport(onImported: onOpenMeeting)
                } label: {
                    Label("导入转写记录", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.isPersistenceAvailable)
                .help("支持可直接读取的文本文件；文件排版不会改变标准会议纪要格式。")
                Button("刷新预览") {
                    appState.refreshExportPreview()
                }
                .disabled(appState.isPostprocessingSelectedMeeting)
                .help("刷新当前 Markdown 导出预览，不会生成会议纪要文件。")
                Button {
                    appState.exportSelectedMeetingMarkdown()
                } label: {
                    Label("导出 .md", systemImage: "square.and.arrow.down")
                }
                .disabled(appState.isPostprocessingSelectedMeeting)
            }

            ScrollView {
                Text(appState.exportPreview.isEmpty ? "暂无可导出的内容。" : appState.exportPreview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minHeight: 220)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
        .panelStyle()
    }

    private var meetingMinutesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("原始会议纪要", systemImage: "doc.text")
                    .font(.title2.bold())
                Spacer()
                if appState.isGeneratingSelectedMeetingMinutes {
                    ProgressView()
                        .controlSize(.small)
                    Text("排队/生成中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        if appState.selectedMeetingMinutesArtifact == nil {
                            appState.generateSelectedMeetingMinutes()
                        } else {
                            additionalMinutesPrompt = ""
                            showsMinutesPromptSheet = true
                        }
                    } label: {
                        Label(
                            appState.selectedMeetingMinutesArtifact == nil
                                ? (appState.selectedMeetingMinutesGenerationError == nil ? "生成原始纪要" : "重新生成")
                                : "重新生成",
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canGenerateSelectedMeetingMinutes)
                }
            }

            if let visionWarning = appState.selectedMeetingMinutesVisionWarning {
                Label(visionWarning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let artifact = appState.selectedMeetingMinutesArtifact {
                if let message = appState.selectedMeetingMinutesGenerationError {
                    Label("\(message) 当前显示的是上一次成功生成的纪要。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    Button {
                        appState.previewSelectedMeetingMinutesHTML()
                    } label: {
                        Label("预览 HTML", systemImage: "eye")
                    }
                    Button {
                        appState.exportSelectedMeetingMinutes(.markdown)
                    } label: {
                        Label("导出 MD", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        appState.exportSelectedMeetingMinutes(.html)
                    } label: {
                        Label("导出 HTML", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                    Text("仅依据本场会议资料")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(artifact.displayMarkdown)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minHeight: 280)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else if appState.isGeneratingSelectedMeetingMinutes {
                ContentUnavailableView(
                    "会议纪要排队/生成中",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("系统会按提交顺序逐个生成；可以切换到其他会议，结果会保留在当前会议。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if let error = appState.selectedMeetingMinutesGenerationError {
                ContentUnavailableView(
                    "标准会议纪要生成失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text("\(error)\n\n原始转写已保留，可点击“重新生成”再次处理。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ContentUnavailableView(
                    "尚未生成会议纪要",
                    systemImage: "doc.text",
                    description: Text(emptyMinutesDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .panelStyle()
    }

    private var meetingAnalysisPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("AI 分析会议纪要", systemImage: "sparkles.rectangle.stack")
                    .font(.title2.bold())
                Spacer()
                if appState.isGeneratingSelectedMeetingAnalysis {
                    ProgressView()
                        .controlSize(.small)
                    Text("分析中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        appState.stopSelectedMeetingAnalysis()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("停止 AI 分析")
                } else {
                    Button {
                        appState.generateSelectedMeetingAnalysis()
                    } label: {
                        Label(
                            appState.selectedMeetingAnalysisArtifact == nil ? "开始 AI 分析" : "重新分析",
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canGenerateSelectedMeetingAnalysis)
                }
            }

            if let artifact = appState.selectedMeetingAnalysisArtifact {
                HStack(spacing: 10) {
                    Button {
                        appState.previewSelectedMeetingAnalysisHTML()
                    } label: {
                        Label("预览 HTML", systemImage: "eye")
                    }
                    Button {
                        appState.exportSelectedMeetingAnalysis(.markdown)
                    } label: {
                        Label("导出 MD", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        appState.exportSelectedMeetingAnalysis(.html)
                    } label: {
                        Label("导出 HTML", systemImage: "square.and.arrow.down")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("任务分工派发")
                        .font(.headline)
                    MeetingAnalysisTodoTable(todos: artifact.document.todos)
                }

                Divider()

                Text(artifact.markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else if appState.isGeneratingSelectedMeetingAnalysis {
                ContentUnavailableView(
                    "正在生成 AI 分析会议纪要",
                    systemImage: "sparkles.rectangle.stack"
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ContentUnavailableView(
                    "尚未生成 AI 分析会议纪要",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text(emptyAnalysisDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .panelStyle()
    }

    private var meetingNotesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会议笔记", systemImage: "note.text")
                    .font(.title2.bold())
                Spacer()
                Button {
                    _ = appState.addMeetingNote()
                } label: {
                    Label("新建笔记", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isSelectedMeetingContentLocked)
            }

            Text("记录会议中的补充信息、手写内容和图片资料。笔记默认参与会议纪要生成。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if appState.selectedMeetingNotes.isEmpty {
                ContentUnavailableView(
                    "还没有会议笔记",
                    systemImage: "note.text.badge.plus",
                    description: Text("点击“新建笔记”开始记录文字或图片。")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(appState.selectedMeetingNotes) { content in
                        MeetingNoteCard(
                            content: content,
                            isLocked: appState.isSelectedMeetingContentLocked,
                            onBodyChanged: { body in
                                _ = appState.updateMeetingNote(noteID: content.note.id, body: body)
                            },
                            onIncludeChanged: { includeInMinutes in
                                _ = appState.setMeetingNoteIncluded(
                                    noteID: content.note.id,
                                    includeInMinutes: includeInMinutes
                                )
                            },
                            onAddImage: {
                                imageImporterNoteID = content.note.id
                                showsImageImporter = true
                            },
                            onDeleteImage: { imageID in
                                _ = appState.deleteMeetingNoteImage(imageID: imageID)
                            },
                            onDelete: {
                                _ = appState.deleteMeetingNote(noteID: content.note.id)
                            }
                        )
                    }
                }
            }
        }
        .panelStyle()
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        guard let noteID = imageImporterNoteID else { return }
        imageImporterNoteID = nil
        switch result {
        case let .success(urls):
            for url in urls {
                do {
                    let secured = url.startAccessingSecurityScopedResource()
                    defer {
                        if secured { url.stopAccessingSecurityScopedResource() }
                    }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 20 * 1024 * 1024 else {
                        appState.statusMessage = "图片过大，单张图片不能超过 20 MB。"
                        continue
                    }
                    let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
                    guard let thumbnailData = Self.makeThumbnail(from: data) else {
                        appState.statusMessage = "无法读取图片：(url.lastPathComponent)"
                        continue
                    }
                    _ = appState.addMeetingNoteImage(
                        noteID: noteID,
                        filename: url.lastPathComponent,
                        mimeType: mimeType,
                        originalData: data,
                        thumbnailData: thumbnailData
                    )
                } catch {
                    appState.statusMessage = "图片读取失败：" + error.localizedDescription
                }
            }
        case let .failure(error):
            if (error as NSError).code != NSUserCancelledError {
                appState.statusMessage = "图片选择失败：" + error.localizedDescription
            }
        }
    }

    private static func makeThumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 320,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary
              ) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private var emptyMinutesDescription: String {
        if appState.selectedSegments.isEmpty {
            return "会议产生转写内容后即可生成。"
        }
        if !appState.hasEnabledMeetingMinutesModel {
            return "请先在模型配置中新增并启用 Agent 模型。"
        }
        return "生成后可直接预览并导出 MD 或 HTML。"
    }

    private var emptyAnalysisDescription: String {
        if appState.selectedMeetingMinutesArtifact == nil {
            return "请先生成原始会议纪要。"
        }
        if !appState.hasEnabledMeetingMinutesModel {
            return "请先在模型配置中新增并启用 Agent 模型。"
        }
        return "可主动发起分析。"
    }
}

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case recording
    case transcript
    case notes
    case minutes
    case analysis
    case agent

    var id: Self { self }

    var title: String {
        switch self {
        case .recording: "录音"
        case .transcript: "转写记录"
        case .notes: "笔记"
        case .minutes: "原始纪要"
        case .analysis: "AI 分析"
        case .agent: "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .recording: "waveform"
        case .transcript: "doc.plaintext"
        case .notes: "note.text"
        case .minutes: "doc.text"
        case .analysis: "sparkles.rectangle.stack"
        case .agent: "terminal"
        }
    }
}

private struct MeetingAnalysisTodoTable: View {
    let todos: [MeetingAnalysisTodo]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    header("事项", width: 160)
                    header("负责人", width: 110)
                    header("具体任务", width: 260)
                    header("交付物", width: 180)
                    header("截止时间", width: 130)
                }
                if todos.isEmpty {
                    GridRow {
                        cell("暂无可确认待办", width: 160)
                        cell("待确认", width: 110)
                        cell("待确认", width: 260)
                        cell("待确认", width: 180)
                        cell("待确认", width: 130)
                    }
                } else {
                    ForEach(todos) { todo in
                        GridRow {
                            cell(todo.item, width: 160)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(todo.owner)
                                    .fontWeight(.medium)
                                Text(todo.assignmentBasis)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 110, alignment: .topLeading)
                            .padding(10)
                            .gridCellAnchor(.topLeading)
                            cell(todo.task, width: 260)
                            cell(todo.deliverable, width: 180)
                            cell(todo.deadline, width: 130)
                        }
                    }
                }
            }
            .overlay {
                Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }
        }
    }

    private func header(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.caption.bold())
            .frame(width: width, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.1))
    }

    private func cell(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .frame(width: width, alignment: .topLeading)
            .padding(10)
            .gridCellAnchor(.topLeading)
    }
}

private struct MeetingMinutesPromptSheet: View {
    @Binding var prompt: String
    let onCancel: () -> Void
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重新生成会议纪要")
                .font(.title2.bold())
            Text("可补充本次生成的整理要求，不填写则使用内置提示词。")
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    )
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("例如：重点提取明确的行动项和风险")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 16)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("开始生成", action: onGenerate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct MeetingNoteCard: View {
    let content: MeetingNoteContent
    let isLocked: Bool
    let onBodyChanged: (String) -> Void
    let onIncludeChanged: (Bool) -> Void
    let onAddImage: () -> Void
    let onDeleteImage: (MeetingNoteImage.ID) -> Void
    let onDelete: () -> Void

    @State private var draftBody: String
    @State private var saveTask: Task<Void, Never>?
    @State private var showsDeleteConfirmation = false

    init(
        content: MeetingNoteContent,
        isLocked: Bool,
        onBodyChanged: @escaping (String) -> Void,
        onIncludeChanged: @escaping (Bool) -> Void,
        onAddImage: @escaping () -> Void,
        onDeleteImage: @escaping (MeetingNoteImage.ID) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.content = content
        self.isLocked = isLocked
        self.onBodyChanged = onBodyChanged
        self.onIncludeChanged = onIncludeChanged
        self.onAddImage = onAddImage
        self.onDeleteImage = onDeleteImage
        self.onDelete = onDelete
        _draftBody = State(initialValue: content.note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    content.note.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Toggle(
                    "纳入纪要",
                    isOn: Binding(
                        get: { content.note.includeInMinutes },
                        set: { onIncludeChanged($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .disabled(isLocked)

                Button {
                    showsDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(isLocked)
                .help("删除笔记")
            }

            TextEditor(text: $draftBody)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 220)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                }
                .disabled(isLocked)
                .onChange(of: draftBody) { _, newValue in
                    saveTask?.cancel()
                    saveTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        onBodyChanged(newValue)
                    }
                }
                .onChange(of: content.note.body) { _, newValue in
                    guard newValue != draftBody else { return }
                    draftBody = newValue
                }

            if !content.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
                    ForEach(content.images) { image in
                        MeetingNoteImageThumbnail(
                            image: image,
                            isLocked: isLocked,
                            onDelete: { onDeleteImage(image.id) }
                        )
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    onAddImage()
                } label: {
                    Label("添加图片", systemImage: "photo.badge.plus")
                }
                .disabled(isLocked)

                if content.note.includeInMinutes {
                    Label("本条会参与会议纪要", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("本条不会参与会议纪要", systemImage: "slash.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
        .onDisappear {
            saveTask?.cancel()
            if draftBody != content.note.body {
                onBodyChanged(draftBody)
            }
        }
        .confirmationDialog(
            "删除这条笔记？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除笔记", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("笔记中的图片也会一并删除。")
        }
    }
}

private struct MeetingNoteImageThumbnail: View {
    let image: MeetingNoteImage
    let isLocked: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let nsImage = NSImage(data: image.thumbnailData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ContentUnavailableView("无法预览", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                }

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.borderless)
                .padding(6)
                .disabled(isLocked)
                .help("删除图片")
            }

            Text(image.filename.isEmpty ? "图片" : image.filename)
                .font(.caption)
                .lineLimit(1)

            Label(image.visionStatus.displayName, systemImage: image.visionStatus.systemImage)
                .font(.caption2)
                .foregroundStyle(image.visionStatus == .failed ? .red : .secondary)

            if image.visionStatus == .failed,
               let reason = image.visionError?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PostprocessingLockBanner: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("会议纪要排队/生成中")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("系统会按提交顺序生成正式纪要并更新标题；当前会议暂不可编辑或归档，可切换页面或开始下一场会议。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("处理中")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.16), in: Capsule())
                .foregroundStyle(.orange)
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct TranscriptDisplayGroupRow: View {
    @State private var isExpanded = false
    let group: TranscriptDisplayGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)

                if let speakerName {
                    Text(speakerName)
                        .font(.headline)
                }

                Spacer()

                if group.segments.count > 1 {
                    Button(isExpanded ? "收起" : "展开 \(group.segments.count) 句") {
                        isExpanded.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            Text(group.text.isEmpty ? "（空白片段）" : group.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(group.segments) { segment in
                        TranscriptSegmentRow(segment: segment)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var timeRange: String {
        "\(formatTime(group.startMs))-\(formatTime(group.endMs))"
    }

    private var speakerName: String? {
        let value = group.personName ?? group.speakerLabel
        return value == "未分配发言人" ? nil : value
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TranscriptSegmentRow: View {
    @Environment(AppState.self) private var appState
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                if let speakerName {
                    Text(speakerName)
                        .font(.headline)
                }
                Spacer()
            }

            TextField(
                "最终文本",
                text: Binding(
                    get: {
                        segment.finalText.isEmpty ? segment.rawText : segment.finalText
                    },
                    set: { newValue in
                        appState.updateSegmentText(segmentID: segment.id, text: newValue)
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .disabled(appState.isSelectedMeetingContentLocked)

            Text(appState.isSelectedMeetingContentLocked ? "当前会议暂不可编辑" : "逐句编辑")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var timeRange: String {
        "\(formatTime(segment.startMs))-\(formatTime(segment.endMs))"
    }

    private var speakerName: String? {
        let value = segment.personName ?? segment.speakerLabel
        return value == "未分配发言人" ? nil : value
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MeetingContentLockBanner: View {
    let meeting: Meeting

    var body: some View {
        Label(
            "会议已归档，请先恢复后再编辑。",
            systemImage: "archivebox"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension MeetingNoteVisionStatus {
    var displayName: String {
        switch self {
        case .pending: "待识别"
        case .processing: "识别中"
        case .completed: "已识别"
        case .failed: "识别失败"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "clock"
        case .processing: "hourglass"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
