import Foundation
import SQLite3

/// 在数据库结构升级前生成可独立打开的 SQLite 快照，并在升级成功后记录版本身份。
struct UpgradeBackup {
    typealias BackupOperation = (URL, URL) throws -> Void

    private static let versionMarkerName = ".last-opened-version"
    private static let maximumRetainedBackups = 3

    let databaseURL: URL
    let directory: URL
    let currentVersion: String
    let fileManager: FileManager
    let backupOperation: BackupOperation

    init(
        databaseURL: URL,
        directory: URL? = nil,
        currentVersion: String,
        fileManager: FileManager = .default,
        backupOperation: @escaping BackupOperation = UpgradeBackup.createSQLiteOnlineBackup
    ) {
        self.databaseURL = databaseURL
        self.directory = directory ?? Self.defaultDirectory(for: databaseURL)
        self.currentVersion = currentVersion
        self.fileManager = fileManager
        self.backupOperation = backupOperation
    }

    static func defaultDirectory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Upgrades", isDirectory: true)
    }

    func backupIfNeeded(databaseExistedBeforeOpening: Bool) throws {
        guard databaseExistedBeforeOpening, recordedVersion() != currentVersion else {
            return
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try restrictPermissions(of: directory, to: 0o700)

        let backupURL = directory.appendingPathComponent(backupFileName())
        do {
            try backupOperation(databaseURL, backupURL)
            try restrictPermissions(of: backupURL, to: 0o600)
            try removeOlderBackups()
        } catch {
            try? fileManager.removeItem(at: backupURL)
            throw AppPersistenceStoreError.unavailable(reason: "创建升级备份失败：\(error.localizedDescription)")
        }
    }

    func recordCurrentVersion() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try restrictPermissions(of: directory, to: 0o700)

        let markerURL = directory.appendingPathComponent(Self.versionMarkerName)
        try Data(currentVersion.utf8).write(to: markerURL, options: .atomic)
        try restrictPermissions(of: markerURL, to: 0o600)
    }

    private func recordedVersion() -> String? {
        let markerURL = directory.appendingPathComponent(Self.versionMarkerName)
        guard let data = try? Data(contentsOf: markerURL),
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    private func backupFileName() -> String {
        let safeVersion = currentVersion.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                Character(String(scalar))
            default:
                "-"
            }
        }
        .reduce(into: "") { $0.append($1) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "ai-tingji-before-\(safeVersion)-\(timestamp)-\(UUID().uuidString).sqlite"
    }

    private func removeOlderBackups() throws {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let backups = contents.filter {
            $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("ai-tingji-before-")
        }
        let oldestFirst = try backups.sorted { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
        for backup in oldestFirst.dropLast(Self.maximumRetainedBackups) {
            try fileManager.removeItem(at: backup)
        }
    }

    private func restrictPermissions(of url: URL, to permissions: Int16) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    static func createSQLiteOnlineBackup(sourceURL: URL, destinationURL: URL) throws {
        var source: OpaquePointer?
        var destination: OpaquePointer?

        // 打开为读写连接仅为让 SQLite 按正常 WAL 锁协议读取最新快照；本函数不会对源库执行写操作。
        guard sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source
        else {
            let message = source.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let source { sqlite3_close_v2(source) }
            throw DatabaseError.openFailed(message)
        }
        defer { sqlite3_close_v2(source) }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(destinationURL.path, &destination, flags, nil) == SQLITE_OK,
              let destination
        else {
            let message = destination.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let destination { sqlite3_close_v2(destination) }
            throw DatabaseError.openFailed(message)
        }
        defer { sqlite3_close_v2(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(destination)))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(destination)))
        }
    }
}
