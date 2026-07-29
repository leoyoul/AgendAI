import AItingjiCore
import Foundation
import Testing

@Test
func appSettingsRepositoryPersistsPostprocessPrompt() throws {
    let path = temporarySettingsDatabasePath()

    do {
        let database = try Database(path: path)
        try database.migrate()
        let repository = AppSettingRepository(database: database)
        try repository.set("postprocess_prompt", value: "删除口水词，保留原意。")
        database.close()
    }

    do {
        let database = try Database(path: path)
        try database.migrate()
        let repository = AppSettingRepository(database: database)
        #expect(try repository.get("postprocess_prompt") == "删除口水词，保留原意。")
        database.close()
    }

    try? FileManager.default.removeItem(atPath: path)
}

private func temporarySettingsDatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-\(UUID().uuidString)-settings")
        .appendingPathExtension("sqlite")
        .path
}
