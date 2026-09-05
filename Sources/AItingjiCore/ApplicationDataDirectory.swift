import Foundation

public enum ApplicationDataDirectory {
    public static let defaultName = "会小纪"
    public static let infoPlistKey = "AgendAIDataDirectoryName"

    public static var name: String {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return defaultName
        }
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDirectoryName(value) else { return defaultName }
        return value
    }

    public static var rootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    public static func child(_ component: String, isDirectory: Bool = true) -> URL {
        rootURL.appendingPathComponent(component, isDirectory: isDirectory)
    }

    public static func isManagedRoot(_ url: URL) -> Bool {
        url.standardizedFileURL == rootURL.standardizedFileURL
    }

    private static func isValidDirectoryName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }
}
