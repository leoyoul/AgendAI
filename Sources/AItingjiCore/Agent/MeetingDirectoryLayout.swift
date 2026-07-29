import Foundation

public enum MeetingDirectoryLayoutError: Error, Equatable, LocalizedError, Sendable {
    case invalidPathComponent(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPathComponent(component):
            "会议目录组件无效：\(component)"
        }
    }
}

public struct MeetingDirectoryLayout: Equatable, Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
    }

    public static func `default`() -> MeetingDirectoryLayout {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return MeetingDirectoryLayout(
            applicationSupportDirectory: root.appendingPathComponent("会小纪", isDirectory: true)
        )
    }

    public func meetingDirectory(meetingID: String) throws -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent(try Self.validatedComponent(meetingID), isDirectory: true)
    }

    public func jobsDirectory(meetingID: String) throws -> URL {
        try meetingDirectory(meetingID: meetingID)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
    }

    public func jobDirectory(meetingID: String, jobID: String) throws -> URL {
        try jobsDirectory(meetingID: meetingID)
            .appendingPathComponent(Self.validatedComponent(jobID), isDirectory: true)
    }

    public func relativeJobDirectory(jobID: String) throws -> String {
        "agent/jobs/\(try Self.validatedComponent(jobID))"
    }

    public func relativeReportPath(jobID: String, reportPath: String) throws -> String {
        guard Self.isSafeRelativePath(reportPath) else {
            throw MeetingDirectoryLayoutError.invalidPathComponent(reportPath)
        }
        return "\(try relativeJobDirectory(jobID: jobID))/\(reportPath)"
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path != ".",
              path != "..",
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return false
        }
        if let first = components.first, first.count >= 2 {
            let text = String(first)
            let second = text.index(after: text.startIndex)
            if text[second] == ":", text.first?.isLetter == true {
                return false
            }
        }
        return true
    }

    private static func validatedComponent(_ component: String) throws -> String {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\\"),
              !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw MeetingDirectoryLayoutError.invalidPathComponent(component)
        }
        return component
    }
}
