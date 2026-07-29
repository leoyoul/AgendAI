import Foundation

public struct MarkdownExporter: Sendable {
    public init() {}

    public func export(meeting: Meeting, segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("- 会议ID：\(meeting.id)")
        lines.append("- 状态：\(meeting.status.rawValue)")
        lines.append("- 采集来源：\(meeting.captureSource.rawValue)")
        lines.append("- 创建时间：\(formatDate(meeting.createdAt))")
        if let startedAt = meeting.startedAt {
            lines.append("- 开始时间：\(formatDate(startedAt))")
        }
        if let endedAt = meeting.endedAt {
            lines.append("- 结束时间：\(formatDate(endedAt))")
        }
        if !meeting.modelSnapshot.isEmpty {
            let snapshot = meeting.modelSnapshot.keys.sorted().joined(separator: ", ")
            lines.append("- 模型快照：\(snapshot)")
        }
        lines.append("")
        lines.append("## 记录")
        lines.append("")

        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) {
            let speaker = segment.personName ?? segment.speakerLabel
            let marker = segment.isManual ? "（人工修正）" : ""
            let text = segment.finalText.isEmpty ? segment.rawText : segment.finalText
            let prefix = speaker == "未分配发言人" ? "" : "\(speaker)\(marker)："
            lines.append("- [\(formatTime(segment.startMs))-\(formatTime(segment.endMs))] \(prefix)\(text)")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds, 0) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
