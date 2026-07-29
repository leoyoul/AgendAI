import Foundation

/// 实时转写去重。对 ASR 的滚动窗口做两级过滤：
/// 1. 相邻两段的首尾字符重叠（旧行为，处理"上一片段最后一句在本次结果开头再出现"这种典型情况）。
/// 2. 与最近若干段（默认 3）做整体相似度比较，避免大范围幻觉/回声导致的整段重复。
public enum LiveTranscriptDeduplicator {
    public static let minimumOverlapCharacters = 4
    public static let defaultRecentComparisonWindow = 3
    /// 归一化后的 Jaccard 相似度阈值，超过则视为重复段。
    public static let duplicateJaccardThreshold = 0.85
    /// 短文本（<=8 归一字符）时，用字符包含关系判定重复。
    public static let shortTextInclusionLength = 8

    /// 旧接口：只与前一段比对，保留给现有调用与测试。
    public static func appendableText(previousText: String?, currentText: String) -> String? {
        let previous = previousText.map { [$0] } ?? []
        return appendableText(recentTexts: previous, currentText: currentText)
    }

    /// 新接口：`recentTexts` 是最近几段落库文本（最新的在末尾）。
    public static func appendableText(recentTexts: [String], currentText: String) -> String? {
        let trimmedCurrent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCurrent.isEmpty else { return nil }

        let normalizedCurrent = normalize(trimmedCurrent)
        guard !normalizedCurrent.isEmpty else { return nil }

        let normalizedRecents = recentTexts
            .suffix(defaultRecentComparisonWindow)
            .map { normalize($0) }
            .filter { !$0.isEmpty }

        // 与任何最近段完全重复 → 丢弃
        if normalizedRecents.contains(normalizedCurrent) {
            return nil
        }
        // 大范围幻觉：整段被包含在最近段里，或最近段被包含在整段里且极其相似
        for recent in normalizedRecents where isDuplicate(recent: recent, current: normalizedCurrent) {
            return nil
        }

        guard let last = recentTexts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else {
            return trimmedCurrent
        }

        // 首尾重叠裁剪逻辑（原实现，保留）
        var remainder = trimmedCurrent
        var trimmedAtLeastOnce = false
        while true {
            let overlap = longestOverlap(previous: last, current: remainder)
            guard overlap >= minimumOverlapCharacters else { break }
            trimmedAtLeastOnce = true
            remainder = String(remainder.dropFirst(overlap)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty || remainder == last { return nil }
        }

        // 裁剪后再看一遍 duplicate：避免裁完只剩几个字仍与前段重复
        let remainderNormalized = normalize(remainder)
        if remainderNormalized.isEmpty { return nil }
        for recent in normalizedRecents where isDuplicate(recent: recent, current: remainderNormalized) {
            return nil
        }

        return trimmedAtLeastOnce ? remainder : trimmedCurrent
    }

    // MARK: - Helpers

    static func normalize(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            result.append(scalar)
        }
        return String(result).lowercased()
    }

    static func isDuplicate(recent: String, current: String) -> Bool {
        let recentChars = Array(recent)
        let currentChars = Array(current)
        let shorterCount = min(recentChars.count, currentChars.count)
        let longerCount = max(recentChars.count, currentChars.count)
        guard shorterCount > 0 else { return false }

        // 短文本：一方完全包含另一方
        if shorterCount <= shortTextInclusionLength {
            return recent.contains(current) || current.contains(recent)
        }

        // 一方完全包含另一方且长度差 <= 25%
        if recent.contains(current) || current.contains(recent) {
            let ratio = Double(shorterCount) / Double(longerCount)
            if ratio >= 0.75 { return true }
        }

        // 中文更适合用 unigram Jaccard（bigram 对短句差异过敏感），
        // 结合长度差过滤：长度差超过 30% 直接不判重。
        if Double(shorterCount) / Double(longerCount) < 0.7 { return false }
        return jaccardUnigram(recentChars, currentChars) >= duplicateJaccardThreshold
    }

    private static func jaccardUnigram(_ a: [Character], _ b: [Character]) -> Double {
        let setA = Set(a)
        let setB = Set(b)
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func longestOverlap(previous: String, current: String) -> Int {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        let maxOverlap = min(previousCharacters.count, currentCharacters.count)
        guard maxOverlap > 0 else { return 0 }

        for length in stride(from: maxOverlap, through: 1, by: -1) {
            if previousCharacters.suffix(length).elementsEqual(currentCharacters.prefix(length)) {
                return length
            }
        }
        return 0
    }
}
