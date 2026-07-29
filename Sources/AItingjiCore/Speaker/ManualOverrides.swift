import Foundation

public enum ManualOverrideReason: String, Codable, Sendable {
    case manualRename = "manual_rename"
    case unknownBatchRename = "unknown_batch_rename"
    case speakerMerge = "speaker_merge"
}

public func applyManualSpeakerName(
    to segment: TranscriptSegment,
    personID: String?,
    personName: String,
    reason: ManualOverrideReason = .manualRename
) -> TranscriptSegment {
    var updated = segment
    updated.personID = personID
    updated.personName = personName
    updated.speakerLabel = personName
    updated.isManual = true
    updated.manualReason = reason.rawValue
    return updated
}

public func applyAutomaticSpeakerName(
    to segment: TranscriptSegment,
    speakerLabel: String,
    personID: String?,
    personName: String?,
    confidence: Double
) -> TranscriptSegment {
    var updated = segment
    updated.autoSpeakerLabel = speakerLabel
    updated.confidence = confidence

    guard !segment.isManual else {
        return updated
    }

    updated.speakerLabel = personName ?? speakerLabel
    updated.personID = personID
    updated.personName = personName
    return updated
}

public func applyPostprocessText(
    to segment: TranscriptSegment,
    processedText: String
) -> TranscriptSegment {
    var updated = segment
    updated.processedText = processedText

    if segment.finalText.isEmpty || segment.finalText == segment.rawText {
        updated.finalText = processedText
    }

    return updated
}
