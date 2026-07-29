import Foundation

public struct DiarizationTurn: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var speakerKey: String
    public var confidence: Double

    public init(startMs: Int, endMs: Int, speakerKey: String, confidence: Double = 0) {
        self.startMs = startMs
        self.endMs = endMs
        self.speakerKey = speakerKey
        self.confidence = confidence
    }
}

public struct DiarizationSpeakerMapping: Codable, Equatable, Sendable {
    public var meetingID: String
    public var speakerKey: String
    public var speakerLabel: String
    public var personID: String?
    public var personName: String?
    public var confidence: Double
    /// 仅本次会议的人工确认；自动重跑不得覆盖。
    public var isManual: Bool

    public init(
        meetingID: String,
        speakerKey: String,
        speakerLabel: String,
        personID: String? = nil,
        personName: String? = nil,
        confidence: Double = 0,
        isManual: Bool = false
    ) {
        self.meetingID = meetingID
        self.speakerKey = speakerKey
        self.speakerLabel = speakerLabel
        self.personID = personID
        self.personName = personName
        self.confidence = confidence
        self.isManual = isManual
    }
}

public struct DiarizationApplicationResult: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var mappings: [DiarizationSpeakerMapping]

    public init(segments: [TranscriptSegment], mappings: [DiarizationSpeakerMapping]) {
        self.segments = segments
        self.mappings = mappings
    }
}

public enum DiarizationApplication {
    public static let multiTrackOverlapLabel = "多人重叠 / 待确认"

    public static func shift(turns: [DiarizationTurn], by offsetMs: Int) -> [DiarizationTurn] {
        guard offsetMs != 0 else {
            return turns
        }
        return turns.map { turn in
            DiarizationTurn(
                startMs: turn.startMs + offsetMs,
                endMs: turn.endMs + offsetMs,
                speakerKey: turn.speakerKey,
                confidence: turn.confidence
            )
        }
    }

    public static func apply(
        turns: [DiarizationTurn],
        to segments: [TranscriptSegment],
        mappings existingMappings: [DiarizationSpeakerMapping] = []
    ) -> DiarizationApplicationResult {
        // 自动匿名标签可随本次分离结果重建；只保留人工确认和未来的已确认身份，
        // 避免旧 run 残留的 speaker key 污染新结果。
        let preservedMappings = existingMappings.filter {
            $0.isManual || $0.personID != nil || $0.personName != nil
        }
        var mappingsByKey = Dictionary(uniqueKeysWithValues: preservedMappings.map { ($0.speakerKey, $0) })
        var nextUnknownIndex = nextIndex(after: Array(mappingsByKey.values))

        let updated = segments.flatMap { segment -> [TranscriptSegment] in
            let candidateTurns = candidateTurns(for: segment, from: turns)
            // 来自麦克风与电脑音频的 turn 同时覆盖时，混合 ASR 无法可靠决定文字归属。
            // 宁可保留文本并标为待确认，也不能随意选一个人。
            if segment.sourceTrack == nil && hasCrossTrackOverlap(for: segment, turns: candidateTurns) {
                return [applyAutomaticSpeakerName(
                    to: segment,
                    speakerLabel: multiTrackOverlapLabel,
                    personID: nil,
                    personName: nil,
                    confidence: segment.confidence
                )]
            }

            let parts = speakerTurns(for: segment, turns: candidateTurns)
            guard !parts.isEmpty else {
                return [segment]
            }
            return parts.map { part -> TranscriptSegment in
                let mapping: DiarizationSpeakerMapping
                let speakerKey = part.turn.speakerKey
                // MANUAL_FALLBACK_* 不参与共享 mapping：手动段没找到真实 turn 时用它做占位，
                // 但不生成 "未知发言人 N" 索引，也不写进最终 mappings 数组。
                if speakerKey.hasPrefix("MANUAL_FALLBACK_") {
                    mapping = DiarizationSpeakerMapping(
                        meetingID: segment.meetingID,
                        speakerKey: speakerKey,
                        speakerLabel: segment.speakerLabel,
                        personID: segment.personID,
                        personName: segment.personName,
                        confidence: part.turn.confidence
                    )
                    mappingsByKey[speakerKey] = mapping
                } else if let existing = mappingsByKey[speakerKey] {
                    mapping = existing
                } else {
                    let label = automaticLabel(
                        for: speakerKey,
                        nextUnknownIndex: &nextUnknownIndex
                    )
                    mapping = DiarizationSpeakerMapping(
                        meetingID: segment.meetingID,
                        speakerKey: speakerKey,
                        speakerLabel: label,
                        confidence: part.turn.confidence
                    )
                    mappingsByKey[speakerKey] = mapping
                }

                var updatedSegment = segment
                if part.startMs != segment.startMs || part.endMs != segment.endMs {
                    updatedSegment.id = "\(segment.id)_speaker_\(part.startMs)_\(part.endMs)"
                    updatedSegment.startMs = part.startMs
                    updatedSegment.endMs = part.endMs
                }
                let automaticallyNamed = applyAutomaticSpeakerName(
                    to: updatedSegment,
                    speakerLabel: mapping.personName ?? mapping.speakerLabel,
                    personID: mapping.personID,
                    personName: mapping.personName,
                    confidence: max(segment.confidence, mapping.confidence, part.turn.confidence)
                )
                guard mapping.isManual else {
                    return automaticallyNamed
                }
                return applyManualSpeakerName(
                    to: automaticallyNamed,
                    personID: mapping.personID,
                    personName: mapping.personName ?? mapping.speakerLabel
                )
            }
        }

        let mappings = mappingsByKey.values
            .filter { !$0.speakerKey.hasPrefix("MANUAL_FALLBACK_") }
            .sorted { left, right in
                let leftIndex = unknownIndex(left.speakerLabel)
                let rightIndex = unknownIndex(right.speakerLabel)
                if leftIndex == rightIndex {
                    return left.speakerKey < right.speakerKey
                }
                return leftIndex < rightIndex
            }
        return DiarizationApplicationResult(segments: updated, mappings: mappings)
    }

    private struct SegmentSpeakerPart {
        var startMs: Int
        var endMs: Int
        var turn: DiarizationTurn
    }

    private static func automaticLabel(for speakerKey: String, nextUnknownIndex: inout Int) -> String {
        guard let separator = speakerKey.firstIndex(of: ":") else {
            defer { nextUnknownIndex += 1 }
            return "未知发言人 \(nextUnknownIndex)"
        }

        let track = String(speakerKey[..<separator])
        let localKey = String(speakerKey[speakerKey.index(after: separator)...])
        let trackName: String
        switch track {
        case "microphone":
            trackName = "麦克风"
        case "computer":
            trackName = "电脑音频"
        default:
            defer { nextUnknownIndex += 1 }
            return "未知发言人 \(nextUnknownIndex)"
        }

        let numericSuffix = localKey.reversed().prefix { $0.isNumber }
        let index = Int(String(numericSuffix.reversed())) ?? 0
        return "\(trackName) · 发言人 \(speakerLetter(index))"
    }

    private static func speakerLetter(_ index: Int) -> String {
        guard index >= 0 else { return "A" }
        var value = index
        var letters = ""
        repeat {
            let scalar = UnicodeScalar(65 + value % 26)!
            letters = String(Character(scalar)) + letters
            value = value / 26 - 1
        } while value >= 0
        return letters
    }

    private static func hasCrossTrackOverlap(for segment: TranscriptSegment, turns: [DiarizationTurn]) -> Bool {
        let overlapping = turns.filter { turn in
            overlapMs(
                segmentStart: segment.startMs,
                segmentEnd: segment.endMs,
                turnStart: turn.startMs,
                turnEnd: turn.endMs
            ) > 0
        }
        for leftIndex in overlapping.indices {
            let left = overlapping[leftIndex]
            guard let leftTrack = trackName(for: left.speakerKey) else { continue }
            for rightIndex in overlapping.indices where rightIndex > leftIndex {
                let right = overlapping[rightIndex]
                guard leftTrack != trackName(for: right.speakerKey) else { continue }
                let sharedMs = overlapMs(
                    segmentStart: max(left.startMs, right.startMs),
                    segmentEnd: min(left.endMs, right.endMs),
                    turnStart: segment.startMs,
                    turnEnd: segment.endMs
                )
                if sharedMs >= 250 {
                    return true
                }
            }
        }
        return false
    }

    private static func trackName(for speakerKey: String) -> String? {
        guard let separator = speakerKey.firstIndex(of: ":") else { return nil }
        let track = String(speakerKey[..<separator])
        return ["microphone", "computer"].contains(track) ? track : nil
    }

    private static func candidateTurns(for segment: TranscriptSegment, from turns: [DiarizationTurn]) -> [DiarizationTurn] {
        guard let sourceTrack = segment.sourceTrack, sourceTrack != .mixed else {
            return turns
        }
        return turns.filter { trackName(for: $0.speakerKey) == sourceTrack.rawValue }
    }

    private static func speakerTurns(for segment: TranscriptSegment, turns: [DiarizationTurn]) -> [SegmentSpeakerPart] {
        if segment.isManual {
            // 手动段：优先落进真实的 diarization turn，否则用一个"手动回退"speakerKey，
            // 避免把中文 autoSpeakerLabel 当 speakerKey 污染映射唯一约束。
            if let realTurn = bestTurn(for: segment, turns: turns) {
                return [SegmentSpeakerPart(startMs: segment.startMs, endMs: segment.endMs, turn: realTurn)]
            }
            let fallbackKey = "MANUAL_FALLBACK_\(segment.id)"
            return [
                SegmentSpeakerPart(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    turn: DiarizationTurn(
                        startMs: segment.startMs,
                        endMs: segment.endMs,
                        speakerKey: fallbackKey,
                        confidence: segment.confidence
                    )
                )
            ]
        }
        let parts = turns
            .compactMap { turn -> SegmentSpeakerPart? in
                let startMs = max(segment.startMs, turn.startMs)
                let endMs = min(segment.endMs, turn.endMs)
                guard endMs > startMs else {
                    return nil
                }
                return SegmentSpeakerPart(startMs: startMs, endMs: endMs, turn: turn)
            }
            .sorted { $0.startMs < $1.startMs }
        guard !parts.isEmpty else {
            return []
        }
        guard Set(parts.map(\.turn.speakerKey)).count > 1 else {
            return [SegmentSpeakerPart(startMs: segment.startMs, endMs: segment.endMs, turn: parts[0].turn)]
        }
        guard let best = bestTurn(for: segment, turns: turns) else {
            return []
        }
        return [SegmentSpeakerPart(startMs: segment.startMs, endMs: segment.endMs, turn: best)]
    }

    private static func bestTurn(for segment: TranscriptSegment, turns: [DiarizationTurn]) -> DiarizationTurn? {
        let midpoint = segment.startMs + max(0, segment.endMs - segment.startMs) / 2
        if let midpointTurn = turns
            .filter({ $0.startMs <= midpoint && midpoint < $0.endMs })
            .max(by: { $0.confidence < $1.confidence }) {
            return midpointTurn
        }

        return turns
            .map { turn in
                (turn, overlapMs(segmentStart: segment.startMs, segmentEnd: segment.endMs, turnStart: turn.startMs, turnEnd: turn.endMs))
            }
            .filter { $0.1 > 0 }
            .max { left, right in
                if left.1 == right.1 {
                    return left.0.confidence < right.0.confidence
                }
                return left.1 < right.1
            }?
            .0
    }

    private static func overlapMs(segmentStart: Int, segmentEnd: Int, turnStart: Int, turnEnd: Int) -> Int {
        max(0, min(segmentEnd, turnEnd) - max(segmentStart, turnStart))
    }

    private static func nextIndex(after mappings: [DiarizationSpeakerMapping]) -> Int {
        let existingUnknownIndices = mappings.compactMap { mapping -> Int? in
            let index = unknownIndex(mapping.speakerLabel)
            return index == Int.max ? nil : index
        }
        return (existingUnknownIndices.max() ?? 0) + 1
    }

    private static func unknownIndex(_ label: String) -> Int {
        let prefix = "未知发言人 "
        guard label.hasPrefix(prefix) else {
            return Int.max
        }
        return Int(label.dropFirst(prefix.count)) ?? Int.max
    }
}
