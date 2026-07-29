import CryptoKit
import Foundation

public enum MeetingAgentRequestHashError: Error, Equatable, Sendable {
    case invalidJSONObject
}

public enum MeetingAgentRequestHasher {
    public static func hash(_ request: MeetingAgentJobRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(request)
        let object = try JSONSerialization.jsonObject(with: data)
        let normalized = normalize(object)
        guard JSONSerialization.isValidJSONObject(normalized) else {
            throw MeetingAgentRequestHashError.invalidJSONObject
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalize(_ value: Any, key: String = "") -> Any {
        if let string = value as? String {
            return string
                .precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if let values = value as? [Any] {
            let normalized = values.map { normalize($0) }
            switch key {
            case "segments":
                return normalized.sorted(by: compareSegments)
            case "attachments":
                return normalized.sorted(by: compareAttachments)
            default:
                return normalized
            }
        }
        if let object = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: object
                .filter { $0.key != "source_path" }
                .map { key, child in
                    (key.precomposedStringWithCanonicalMapping, normalize(child, key: key))
                })
        }
        return value
    }

    private static func compareSegments(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] else {
            return false
        }
        let lhsStart = integer(lhs["start_ms"])
        let rhsStart = integer(rhs["start_ms"])
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        let lhsEnd = integer(lhs["end_ms"])
        let rhsEnd = integer(rhs["end_ms"])
        if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
        return utf8Precedes(string(lhs["id"]), string(rhs["id"]))
    }

    private static func compareAttachments(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] else {
            return false
        }
        return utf8Precedes(string(lhs["id"]), string(rhs["id"]))
    }

    private static func integer(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
