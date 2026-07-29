import Foundation

public enum DiarizationTokenResolver {
    public static func resolve(source: ModelSource?, environment: [String: String]) -> String? {
        if let token = normalized(source?.apiKey) {
            return token
        }
        if let token = normalized(environment["HF_TOKEN"]) {
            return token
        }
        return normalized(environment["HUGGINGFACE_TOKEN"])
    }

    private static func normalized(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
