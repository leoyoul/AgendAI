import AItingjiCore
import Foundation

struct MeetingTextPostprocessItem: Codable, Equatable, Sendable {
    let id: TranscriptSegment.ID
    let text: String
}

enum MeetingTextPostprocessBatchError: Error, Equatable {
    case invalidResponse
    case mismatchedSegmentIDs
}

enum MeetingTextPostprocessBatch {
    static let maximumCharacterCount = 24_000

    static func batches(
        segments: [TranscriptSegment],
        maximumCharacterCount: Int = maximumCharacterCount
    ) -> [[MeetingTextPostprocessItem]] {
        precondition(maximumCharacterCount > 0)
        var result: [[MeetingTextPostprocessItem]] = []
        var current: [MeetingTextPostprocessItem] = []
        var currentCount = 0

        for segment in segments {
            let item = MeetingTextPostprocessItem(
                id: segment.id,
                text: PostprocessApplication.sourceText(for: segment)
            )
            let itemCount = item.id.count + item.text.count + 24
            if !current.isEmpty, currentCount + itemCount > maximumCharacterCount {
                result.append(current)
                current = []
                currentCount = 0
            }
            current.append(item)
            currentCount += itemCount
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func encode(_ items: [MeetingTextPostprocessItem]) throws -> String {
        String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
    }

    static func decode(
        _ response: String,
        expectedItems: [MeetingTextPostprocessItem]
    ) throws -> [TranscriptSegment.ID: String] {
        let cleaned = stripCodeFence(response)
        guard let data = cleaned.data(using: .utf8),
              let items = try? JSONDecoder().decode([MeetingTextPostprocessItem].self, from: data) else {
            throw MeetingTextPostprocessBatchError.invalidResponse
        }
        let expectedIDs = Set(expectedItems.map(\.id))
        let actualIDs = Set(items.map(\.id))
        guard items.count == expectedItems.count,
              actualIDs == expectedIDs else {
            throw MeetingTextPostprocessBatchError.mismatchedSegmentIDs
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text) })
    }

    static func prompt(base: String) -> String {
        """
        \(base)

        输入是 JSON 数组，每项包含 id 和 text。只清理 text，必须原样保留每个 id、项目数量和顺序。
        只输出合法 JSON 数组，不要输出 Markdown 代码块、解释或其他字段。
        """
    }

    private static func stripCodeFence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return trimmed }
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
