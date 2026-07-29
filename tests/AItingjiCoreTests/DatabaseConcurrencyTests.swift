import AItingjiCore
import Dispatch
import Foundation
import Testing

@Test
func databaseHandlesParallelWritesWithoutCorruption() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-concurrency-\(UUID().uuidString).sqlite")
        .path
    let db = try Database(path: path)
    try db.migrate()
    defer {
        db.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    let taskCount = 20
    let insertsPerTask = 25
    let group = DispatchGroup()
    let workerQueue = DispatchQueue(label: "test.parallel.writes", attributes: .concurrent)
    for i in 0..<taskCount {
        group.enter()
        workerQueue.async {
            defer { group.leave() }
            for j in 0..<insertsPerTask {
                let id = "person-\(i)-\(j)-\(UUID().uuidString)"
                try? db.execute(
                    "INSERT INTO people (id, display_name, aliases, threshold, is_active) VALUES (?, ?, ?, ?, ?);",
                    bindings: [
                        .text(id),
                        .text("并发\(i)_\(j)"),
                        .text("[]"),
                        .real(0.82),
                        .integer(1)
                    ]
                )
            }
        }
    }
    group.wait()

    let rows = try db.query("SELECT COUNT(*) AS c FROM people;")
    #expect(rows.first?["c"]?.intValue == taskCount * insertsPerTask)
}

@Test
func databaseTransactionRollsBackOnError() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-txn-\(UUID().uuidString).sqlite")
        .path
    let db = try Database(path: path)
    try db.migrate()
    defer {
        db.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    struct BoomError: Error {}

    var caught = false
    do {
        try db.transaction {
            try db.execute(
                "INSERT INTO people (id, display_name, aliases, threshold, is_active) VALUES (?, ?, ?, ?, ?);",
                bindings: [.text("t1"), .text("张三"), .text("[]"), .real(0.82), .integer(1)]
            )
            throw BoomError()
        }
    } catch is BoomError {
        caught = true
    }
    #expect(caught)

    let rows = try db.query("SELECT COUNT(*) AS c FROM people;")
    #expect(rows.first?["c"]?.intValue == 0)
}

@Test
func databaseTransactionCommitsOnSuccess() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-txn-ok-\(UUID().uuidString).sqlite")
        .path
    let db = try Database(path: path)
    try db.migrate()
    defer {
        db.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    try db.transaction {
        for i in 0..<5 {
            try db.execute(
                "INSERT INTO people (id, display_name, aliases, threshold, is_active) VALUES (?, ?, ?, ?, ?);",
                bindings: [.text("p\(i)"), .text("n\(i)"), .text("[]"), .real(0.82), .integer(1)]
            )
        }
    }
    let rows = try db.query("SELECT COUNT(*) AS c FROM people;")
    #expect(rows.first?["c"]?.intValue == 5)
}
