import Foundation

public enum MeetingTitleGeneration {
    public static let maximumLength = 20
    public static let maximumTranscriptLength = 6_000

    public static func shouldReplace(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("新会议") else { return false }
        let suffix = trimmed.dropFirst("新会议".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
    }

    public static func transcript(from segments: [TranscriptSegment]) -> String {
        let text = segments
            .sorted { $0.startMs < $1.startMs }
            .compactMap { segment -> String? in
                let content = segment.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return "\(segment.speakerLabel)：\(content)"
            }
            .joined(separator: "\n")
        return String(text.prefix(maximumTranscriptLength))
    }

    public static func normalize(_ modelOutput: String) -> String? {
        guard var title = modelOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            return nil
        }

        for prefix in ["会议标题：", "会议标题:", "标题：", "标题:", "#"] where title.hasPrefix(prefix) {
            title.removeFirst(prefix.count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let decoration = CharacterSet(charactersIn: "\"'“”‘’《》【】[]。：:，,；;！!？?")
        title = title.trimmingCharacters(in: decoration.union(.whitespacesAndNewlines))
        guard !title.isEmpty else { return nil }
        return String(title.prefix(maximumLength))
    }
}
