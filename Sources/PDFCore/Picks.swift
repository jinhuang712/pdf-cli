import Foundation
import GRDB

/// The agent's choice between the two readings of a block's unsure words.
public struct Pick: Equatable, Sendable {
    public var pageKey: String
    /// The block, counted from 0.
    public var block: Int
    /// The block's readings when the agent picked, each joined across its unsure words. A pick
    /// applies only while the page still offers the same readings, so a page parsed again
    /// differently never takes a pick made for other words.
    public var readings: [String]
    /// 0 for reading a, 1 for reading b.
    public var chosen: Int
    public var pickedAt: Date

    public init(pageKey: String, block: Int, readings: [String], chosen: Int, pickedAt: Date) {
        self.pageKey = pageKey
        self.block = block
        self.readings = readings
        self.chosen = chosen
        self.pickedAt = pickedAt
    }
}

/// Picks live apart from the parsed pages, in the agent's own folder (DESIGNS.md → Principles →
/// Failure): the cache can be deleted and rebuilt, and the agent's work stays.
public final class Picks: Sendable {
    let queue: DatabaseQueue

    /// With `readOnly`, the folder and the table are left as they are, which a dry run needs
    /// (ROADMAP.md → M2.18); the file must exist, see `exists`.
    public init(directory: URL = Env.supportDirectory, readOnly: Bool = false) throws {
        if !readOnly { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        configuration.readonly = readOnly
        queue = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path,
                                  configuration: configuration)
        if readOnly { return }
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pick (
                    page_key TEXT NOT NULL,
                    block INTEGER NOT NULL,
                    reading_a TEXT NOT NULL,
                    reading_b TEXT NOT NULL,
                    chosen INTEGER NOT NULL,
                    picked_at REAL NOT NULL,
                    PRIMARY KEY (page_key, block)
                )
                """)
        }
    }

    /// The readings of one block's unsure words, each joined across the words: what the
    /// output shows as [a] and [b].
    public static func readings(of spans: [Unsure]) -> [String] {
        [0, 1].map { side in spans.map { $0.readings[side] }.joined(separator: " … ") }
    }

    public func save(_ pick: Pick) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO pick (page_key, block, reading_a, reading_b, chosen, picked_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [pick.pageKey, pick.block, pick.readings[0], pick.readings[1], pick.chosen,
                                 pick.pickedAt.timeIntervalSince1970])
        }
    }

    /// After a page's result was replaced: keeps each pick on these pages that still applies to
    /// the new result, by the rule `Output.judge` reads picks with (the block still offers the
    /// same readings), removes the others, and says how many of each by page key (`pdf reparse`,
    /// M2.23). Idempotent, so a run that ended between the replacement and this call is mended by
    /// the next. It reads and deletes in one transaction, and deletes a row only if it is still
    /// the one it judged, so a `pdf pick` made at the same time against the new reading stays.
    public func reconcile(results: [String: PageResult]) throws -> [String: (kept: Int, cleared: Int)] {
        guard !results.isEmpty else { return [:] }
        let keys = Array(results.keys)
        return try queue.write { db in
            guard try db.tableExists("pick") else { return [:] }
            var counts: [String: (kept: Int, cleared: Int)] = [:]
            for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT * FROM pick WHERE page_key IN (\(marks))", arguments: StatementArguments(chunk)) {
                    let pick = Pick(
                        pageKey: row["page_key"], block: row["block"], readings: [row["reading_a"], row["reading_b"]],
                        chosen: row["chosen"], pickedAt: Date(timeIntervalSince1970: row["picked_at"]))
                    let unsure = results[pick.pageKey].map { Dictionary(grouping: Quality.judge($0).unsure, by: \.block) } ?? [:]
                    let choices = unsure[pick.block]?.filter(\.pickable) ?? []
                    if !choices.isEmpty, Picks.readings(of: choices) == pick.readings {
                        counts[pick.pageKey, default: (0, 0)].kept += 1
                    } else {
                        try db.execute(
                            sql: "DELETE FROM pick WHERE page_key = ? AND block = ? AND reading_a = ? AND reading_b = ? AND picked_at = ?",
                            arguments: [pick.pageKey, pick.block, pick.readings[0], pick.readings[1], row["picked_at"] as Double])
                        if db.changesCount > 0 { counts[pick.pageKey, default: (0, 0)].cleared += 1 }
                    }
                }
            }
            return counts
        }
    }

    /// One clean sentence for a failure of the picks' database: SQLite's message without the
    /// statement it ran.
    public static func reason(of error: Error) -> String {
        if let line = Store.readOnlyFailure(error) { return line }
        if let error = error as? DatabaseError { return error.message ?? "database error \(error.resultCode.rawValue)" }
        return error.localizedDescription
    }

    /// Every pick on these pages, by page key.
    public func picks(keys: [String]) throws -> [String: [Pick]] {
        guard !keys.isEmpty else { return [:] }
        return try queue.read { db in
            guard try db.tableExists("pick") else { return [:] }
            var found: [String: [Pick]] = [:]
            for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT * FROM pick WHERE page_key IN (\(marks))",
                                            arguments: StatementArguments(chunk)) {
                    let pick = Pick(pageKey: row["page_key"], block: row["block"],
                                    readings: [row["reading_a"], row["reading_b"]], chosen: row["chosen"],
                                    pickedAt: Date(timeIntervalSince1970: row["picked_at"]))
                    found[pick.pageKey, default: []].append(pick)
                }
            }
            return found
        }
    }
}
