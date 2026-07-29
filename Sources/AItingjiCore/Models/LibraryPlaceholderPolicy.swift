import Foundation

public enum LibraryPlaceholderPolicy {
    public static func isGeneratedPersonName(_ value: String) -> Bool {
        matches(value, prefix: "新同事")
    }

    public static func isGeneratedTerminologyName(_ value: String) -> Bool {
        matches(value, prefix: "新专有名词")
    }

    private static func matches(_ value: String, prefix: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return false }
        let suffix = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
    }
}
