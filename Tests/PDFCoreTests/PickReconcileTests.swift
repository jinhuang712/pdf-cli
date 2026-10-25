import Foundation
import Testing

@testable import PDFCore

/// `Picks.tally` (ROADMAP.md → M2.24): counts the picks whose block still offers the readings they were
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
