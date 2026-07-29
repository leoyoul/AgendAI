import Foundation

public struct TranscriptImportRecord: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var speakerLabel: String
    public var text: String

    public init(startMs: Int, endMs: Int, speakerLabel: String, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speakerLabel = speakerLabel
        self.text = text
    }
}

public enum TranscriptImportError: Error, Equatable, LocalizedError, Sendable {
    case emptyContent
    case noUsableContent
    case fileTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "转写文件为空。"
        case .noUsableContent:
            "没有识别到可导入的转写内容。"
        case .fileTooLarge(let maximumBytes):
            "转写文件超过 \(maximumBytes / 1_048_576) MB，无法导入。"
        }
    }
}

public enum TranscriptImportParser {
    public static let maximumFileSize = 20 * 1_048_576
    public static let unassignedSpeakerLabel = "未分配发言人"

    public static func parse(
        _ content: String,
        fileExtension: String? = nil
    ) throws -> [TranscriptImportRecord] {
        guard content.utf8.count <= maximumFileSize else {
            throw TranscriptImportError.fileTooLarge(maximumBytes: maximumFileSize)
        }
        let normalized = normalize(content)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptImportError.emptyContent
        }

        let normalizedExtension = fileExtension?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let records: [PendingRecord]
        if normalizedExtension == "srt" || normalizedExtension == "vtt" {
            records = parseTimedCues(normalized)
        } else {
            records = parsePlainText(normalized)
        }

        let finalized = finalize(records)
        guard !finalized.isEmpty else {
            throw TranscriptImportError.noUsableContent
        }
        return finalized
    }

    private struct PendingRecord {
        var startMs: Int?
        var endMs: Int?
        var speakerLabel: String
        var text: String
    }

    private static func normalize(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    }

    private static func parseTimedCues(_ content: String) -> [PendingRecord] {
        let lines = content.components(separatedBy: "\n")
        var records: [PendingRecord] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard let arrowRange = line.range(of: "-->") else {
                index += 1
                continue
            }

            let startText = line[..<arrowRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let endText = line[arrowRange.upperBound...]
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            guard let startMs = parseTime(String(startText)),
                  let endMs = parseTime(endText) else {
                index += 1
                continue
            }

            index += 1
            var textLines: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty {
                    index += 1
                    break
                }
                if candidate.contains("-->") {
                    break
                }
                textLines.append(candidate)
                index += 1
            }
            let rawText = textLines.joined(separator: " ")
            let voice = parseVoiceMarkup(rawText)
            let speakerAndText = splitSpeaker(from: stripMarkup(voice.text))
            let speaker = voice.speaker ?? speakerAndText.speaker
            let text = speakerAndText.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            records.append(PendingRecord(
                startMs: startMs,
                endMs: max(endMs, startMs + 1),
                speakerLabel: normalizedSpeaker(speaker),
                text: text
            ))
        }
        return records
    }

    private static func parsePlainText(_ content: String) -> [PendingRecord] {
        var records: [PendingRecord] = []
        var currentLines: [String] = []

        func flushCurrentLines() {
            let text = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                records.append(PendingRecord(
                    startMs: nil,
                    endMs: nil,
                    speakerLabel: unassignedSpeakerLabel,
                    text: text
                ))
            }
            currentLines = []
        }

        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushCurrentLines()
                continue
            }
            currentLines.append(readableText(from: trimmed))
        }
        flushCurrentLines()
        return records
    }

    private static func readableText(from line: String) -> String {
        line
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func finalize(_ pending: [PendingRecord]) -> [TranscriptImportRecord] {
        let meaningful = pending.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var records: [TranscriptImportRecord] = []
        var cursor = 0

        for (index, item) in meaningful.enumerated() {
            let start = max(item.startMs ?? cursor, cursor)
            let nextExplicitStart = meaningful.dropFirst(index + 1).compactMap(\.startMs).first
            let estimatedEnd = start + estimatedDurationMs(for: item.text)
            let end = max(
                start + 1,
                item.endMs ?? nextExplicitStart.map { min($0, estimatedEnd) } ?? estimatedEnd
            )
            records.append(TranscriptImportRecord(
                startMs: start,
                endMs: end,
                speakerLabel: item.speakerLabel,
                text: item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            cursor = end
        }
        return records
    }

    private static func estimatedDurationMs(for text: String) -> Int {
        let meaningfulCharacters = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
        return max(2_000, Int((Double(meaningfulCharacters) / 4.0 * 1_000).rounded(.up)))
    }

    private static func parseTime(_ rawValue: String) -> Int? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        let hours: Double
        let minutes: Double
        let seconds: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]),
                  let parsedMinutes = Double(components[1]),
                  let parsedSeconds = Double(components[2]) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
            seconds = parsedSeconds
        } else {
            guard let parsedMinutes = Double(components[0]),
                  let parsedSeconds = Double(components[1]) else { return nil }
            hours = 0
            minutes = parsedMinutes
            seconds = parsedSeconds
        }
        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return Int(((hours * 3_600 + minutes * 60 + seconds) * 1_000).rounded())
    }

    private static func splitSpeaker(from rawText: String) -> (speaker: String?, text: String) {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard let match = firstMatch(pattern: #"^([^:：\n]{1,40})\s*[:：]\s*(.+)$"#, in: text) else {
            return (nil, text)
        }
        let speaker = match[1].trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty,
              !speaker.contains("//"),
              !speaker.contains("。"),
              !speaker.contains("，"),
              !speaker.contains(",") else {
            return (nil, text)
        }
        return (speaker, match[2])
    }

    private static func parseVoiceMarkup(_ rawText: String) -> (speaker: String?, text: String) {
        guard let match = firstMatch(pattern: #"^<v(?:\.[^ >]+)?\s+([^>]+)>(.*)$"#, in: rawText) else {
            return (nil, rawText)
        }
        return (match[1].trimmingCharacters(in: .whitespaces), match[2])
    }

    private static func stripMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func normalizedSpeaker(_ speaker: String?) -> String {
        let value = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? unassignedSpeakerLabel : value
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
                return ""
            }
            return String(text[swiftRange])
        }
    }
}
