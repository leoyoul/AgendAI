import Foundation

public enum PostprocessApplication {
    public static let minimumRetainedCharacterRatio = 0.92
    public static let minimumTokenRecallRatio = 0.85

    public static func sourceText(for segment: TranscriptSegment) -> String {
        if segment.isManual {
            let manualText = segment.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !manualText.isEmpty {
                return manualText
            }
        }
        let rawText = segment.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawText.isEmpty {
            return rawText
        }
        return segment.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func apply(polishedText: String, to segment: TranscriptSegment) -> TranscriptSegment {
        guard shouldApply(polishedText: polishedText, to: segment) else {
            return segment
        }
        var updated = segment
        let trimmed = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.processedText = trimmed
        updated.finalText = trimmed
        return updated
    }

    public static func shouldApply(polishedText: String, to segment: TranscriptSegment) -> Bool {
        let sourceText = sourceText(for: segment)
        let outputText = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty, !outputText.isEmpty else {
            return false
        }
        let sourceCount = meaningfulCharacterCount(sourceText)
        let outputCount = meaningfulCharacterCount(outputText)
        guard sourceCount > 0, outputCount > 0 else {
            return false
        }
        if sourceCount >= 12 {
            guard Double(outputCount) / Double(sourceCount) >= minimumRetainedCharacterRatio else {
                return false
            }
            return tokenRecall(sourceText: sourceText, outputText: outputText) >= minimumTokenRecallRatio
        }
        return true
    }

    private static func tokenRecall(sourceText: String, outputText: String) -> Double {
        let sourceTokens = meaningfulTokens(sourceText)
        guard !sourceTokens.isEmpty else {
            return 1
        }
        let outputScalars = Array(outputText.unicodeScalars)
        let matched = sourceTokens.filter { token in
            contains(token, in: outputScalars)
        }.count
        return Double(matched) / Double(sourceTokens.count)
    }

    private static func meaningfulTokens(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        })
        guard scalars.count > 1 else {
            return scalars.map { String($0) }
        }
        return (0..<(scalars.count - 1)).map { index in
            String(String.UnicodeScalarView([scalars[index], scalars[index + 1]]))
        }
    }

    private static func contains(_ token: String, in outputScalars: [UnicodeScalar]) -> Bool {
        let tokenScalars = Array(token.unicodeScalars)
        guard !tokenScalars.isEmpty, outputScalars.count >= tokenScalars.count else {
            return false
        }
        for start in 0...(outputScalars.count - tokenScalars.count) {
            if Array(outputScalars[start..<(start + tokenScalars.count)]) == tokenScalars {
                return true
            }
        }
        return false
    }

    private static func meaningfulCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        }.count
    }
}
