import SwiftUI

struct DebugLogView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                Section("会议运行状态") {
                    ForEach(appState.debugMeetingStates) { state in
                        meetingStateRow(state)
                    }
                }

                Section("最近事件") {
                    if appState.debugLogEntries.isEmpty {
                        Text("暂无调试事件。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.debugLogEntries) { entry in
                            eventRow(entry)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            appState.refreshDebugLogPage()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("调试日志", systemImage: "ladybug")
                    .font(.title2.bold())
                Text("用于核对内存任务、数据库状态、归档位、恢复标记和最近错误。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.refreshDebugLogPage()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func meetingStateRow(_ state: MeetingDebugState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(state.title)
                    .font(.headline)
                if state.hasPersistenceMismatch {
                    Label("内存与数据库不一致", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(state.runtimeSummary)
                    .font(.caption)
                    .foregroundStyle(state.runtimeSummary == "无运行任务" ? Color.secondary : Color.blue)
            }
            Text("内存：\(state.memoryStatus.displayName) · 归档=\(state.memoryArchived ? "是" : "否")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("数据库：\(state.persistedStatus?.displayName ?? "未读取") · 归档=\(state.persistedArchived.map { $0 ? "是" : "否" } ?? "未读取") · 纪要缓存=\(state.hasMinutesArtifact ? "有" : "无")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let error = state.minutesGenerationError, !error.isEmpty {
                Text("错误：\(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(state.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func eventRow(_ entry: AppDebugLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(entry.message)
                .font(.callout)
            if let meetingID = entry.meetingID {
                Text(meetingID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}
