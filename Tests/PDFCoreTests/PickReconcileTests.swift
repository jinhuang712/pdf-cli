import Foundation
import GRDB
import Testing

@testable import PDFCore

/// `Picks.tally` (plan/ROADMAP.md → M2.24): counts the picks whose block still offers the readings they were
/// made for and those whose block does not, by page key, and deletes nothing.
@Suite struct PickReconcileTests {
    let box = Box(x: 0.1, y: 0.2, width: 0.8, height: 0.05)

    func result(_ a: String, _ b: String) throws -> PageResult {
        var layer = PageText(
            blocks: [TextBlock(text: "\(a) well.", box: box, lines: [TextLine(text: "\(a) well.", box: box)])], words: 2, runTogether: 0)
        layer.unsure = [Unsure(block: 0, offset: 0, readings: [a, b], box: box)]
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        return PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1, data: data)
    }

    func picks() throws -> Picks {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picks-" + UUID().uuidString)
        return try Picks(directory: directory)
    }

    @Test func countsWhatAppliesAndWhatDoesNotAndDeletesNothing() throws {
        let store = try picks()
        let now = Date()
        try store.save(Pick(pageKey: "same", block: 0, readings: ["CTRLperforms", "CTRL performs"], chosen: 1, pickedAt: now))
        try store.save(Pick(pageKey: "other", block: 0, readings: ["CTRLworks", "CTRL works"], chosen: 0, pickedAt: now))
        try store.save(Pick(pageKey: "gone", block: 3, readings: ["CTRLperforms", "CTRL performs"], chosen: 0, pickedAt: now))
        let results = [
            "same": try result("CTRLperforms", "CTRL performs"), "other": try result("CTRLperforms", "CTRL performs"),
            "gone": try result("CTRLperforms", "CTRL performs"),
        ]
        let first = try store.tally(results: results)
        #expect(first["same"]?.applies == 1 && first["same"]?.stale == 0)
        #expect(first["other"]?.applies == 0 && first["other"]?.stale == 1)
        #expect(first["gone"]?.applies == 0 && first["gone"]?.stale == 1, "a block the page no longer has")
        // Nothing was deleted, and the same question gets the same answer.
        #expect(try store.picks(keys: ["same", "other", "gone"]).keys.sorted() == ["gone", "other", "same"])
        let second = try store.tally(results: results)
        #expect(second["same"]?.applies == 1 && second["other"]?.stale == 1 && second["gone"]?.stale == 1)
        // The readings come back: the stale pick applies again.
        let back = try store.tally(results: ["other": try result("CTRLworks", "CTRL works")])
        #expect(back["other"]?.applies == 1 && back["other"]?.stale == 0)
    }

    @Test func aPageWithNoResultOrNoPickCostsNothing() throws {
        let store = try picks()
        #expect(try store.tally(results: [:]).isEmpty)
        #expect(try store.tally(results: ["k": try result("a", "b")]).isEmpty)
    }

    @Test func aLockedDatabaseIsOneCleanSentence() throws {
        struct Odd: Error {}
        #expect(!Picks.reason(of: Odd()).isEmpty)
    }
}

/// The picks' table keeps a pick made for other readings of the same paragraph (M2.24 review, M1).
@Suite struct PickKeyTests {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("picks-" + UUID().uuidString) }

    @Test func aPickForOtherReadingsOfTheSameBlockDoesNotReplaceTheStoredOne() throws {
        let store = try Picks(directory: directory())
        let now = Date()
        try store.save(Pick(pageKey: "k", block: 2, readings: ["a b", "ab"], chosen: 0, pickedAt: now))
        try store.save(Pick(pageKey: "k", block: 2, readings: ["c d", "cd"], chosen: 1, pickedAt: now))
        #expect(try store.picks(keys: ["k"])["k"]?.count == 2)
        try store.save(Pick(pageKey: "k", block: 2, readings: ["a b", "ab"], chosen: 1, pickedAt: now))
        let kept = try #require(try store.picks(keys: ["k"])["k"])
        #expect(kept.count == 2 && kept.first { $0.readings == ["a b", "ab"] }?.chosen == 1, "the same readings replace")
    }

    @Test func aTableWithTheOldKeyIsMigratedAndEveryRowKept() throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("library.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE pick (page_key TEXT NOT NULL, block INTEGER NOT NULL, reading_a TEXT NOT NULL,
                    reading_b TEXT NOT NULL, chosen INTEGER NOT NULL, picked_at REAL NOT NULL, PRIMARY KEY (page_key, block));
                INSERT INTO pick VALUES ('k', 1, 'a b', 'ab', 0, 1.0), ('k', 2, 'c d', 'cd', 1, 2.0);
                """)
        }
        let store = try Picks(directory: dir)
        try store.save(Pick(pageKey: "k", block: 1, readings: ["x y", "xy"], chosen: 0, pickedAt: Date()))
        let all = try #require(try store.picks(keys: ["k"])["k"])
        #expect(all.count == 3, "both old rows kept, and the new one beside the first")
        // Opened again, nothing more happens.
        #expect(try Picks(directory: dir).picks(keys: ["k"])["k"]?.count == 3)
    }
}
