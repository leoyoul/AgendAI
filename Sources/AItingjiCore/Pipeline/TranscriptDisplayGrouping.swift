import Foundation

public struct TranscriptDisplayGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var speakerLabel: String
    public var autoSpeakerLabel: String
    public var personID: String?
    public var personName: String?
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var isManual: Bool
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        let sortedSegments = segments.sorted { left, right in
            if left.startMs == right.startMs {
                return left.endMs < right.endMs
            }
            return left.startMs < right.startMs
        }
        let first = sortedSegments.first
        let last = sortedSegments.last
        self.id = sortedSegments.map(\.id).joined(separator: "+")
        self.speakerLabel = first?.speakerLabel ?? ""
        self.autoSpeakerLabel = first?.autoSpeakerLabel ?? ""
        self.personID = first?.personID
        self.personName = first?.personName
        self.startMs = first?.startMs ?? 0
        self.endMs = last?.endMs ?? first?.endMs ?? 0
        self.text = sortedSegments
            .map { segment in
                let final = segment.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                let raw = segment.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                return final.isEmpty ? raw : final
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.isManual = sortedSegments.contains { $0.isManual }
        self.segments = sortedSegments
    }
}

public enum TranscriptDisplayGrouper {
    public static func group(_ segments: [TranscriptSegment]) -> [TranscriptDisplayGroup] {
        let sortedSegments = segments.sorted { left, right in
            if left.startMs == right.startMs {
                return left.endMs < right.endMs
            }
            return left.startMs < right.startMs
        }
        var groups: [[TranscriptSegment]] = []

        for segment in sortedSegments {
            guard var lastGroup = groups.popLast(),
                  let lastSegment = lastGroup.last else {
                groups.append([segment])
                continue
            }

            if speakerKey(for: lastSegment) == speakerKey(for: segment) {
                lastGroup.append(segment)
                groups.append(lastGroup)
            } else {
                groups.append(lastGroup)
                groups.append([segment])
            }
        }

        return groups.map(TranscriptDisplayGroup.init)
    }

    private static func speakerKey(for segment: TranscriptSegment) -> String {
        if let personID = segment.personID, !personID.isEmpty {
            return "person:\(personID)"
        }
        if let personName = segment.personName, !personName.isEmpty {
            return "name:\(personName)"
        }
        return "label:\(segment.speakerLabel)"
    }
}
