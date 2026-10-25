import Foundation
import Testing

@testable import PDFCore

/// `Picks.reconcile` (ROADMAP.md → M2.23): a pick stays while its block still offers the readings it
/// was made for, and the counts come by page key, so a key that two pages share counts once.
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

    @Test func keepsWhatStillAppliesClearsTheRestAndCountsByKey() throws {
        let store = try picks()
        let now = Date()
        try store.save(Pick(pageKey: "same", block: 0, readings: ["CTRLperforms", "CTRL performs"], chosen: 1, pickedAt: now))
        try store.save(Pick(pageKey: "other", block: 0, readings: ["CTRLworks", "CTRL works"], chosen: 0, pickedAt: now))
        try store.save(Pick(pageKey: "gone", block: 3, readings: ["CTRLperforms", "CTRL performs"], chosen: 0, pickedAt: now))
        let results = [
            "same": try result("CTRLperforms", "CTRL performs"), "other": try result("CTRLperforms", "CTRL performs"),
            "gone": try result("CTRLperforms", "CTRL performs"),
        ]
        let first = try store.reconcile(results: results)
        #expect(first["same"]?.kept == 1 && first["same"]?.cleared == 0)
        #expect(first["other"]?.kept == 0 && first["other"]?.cleared == 1)
        #expect(first["gone"]?.kept == 0 && first["gone"]?.cleared == 1, "a block the page no longer has")
        // Again, as a second chunk with the same key would: nothing more is cleared, the key still keeps its one.
        let second = try store.reconcile(results: results)
        #expect(second["same"]?.kept == 1 && (second["other"]?.cleared ?? 0) == 0 && (second["gone"]?.cleared ?? 0) == 0)
        #expect(try store.picks(keys: ["same", "other", "gone"]).keys.sorted() == ["same"])
    }

    @Test func aPageWithNoResultOrNoPickCostsNothing() throws {
        let store = try picks()
        #expect(try store.reconcile(results: [:]).isEmpty)
        #expect(try store.reconcile(results: ["k": try result("a", "b")]).isEmpty)
    }

    @Test func aLockedDatabaseIsOneCleanSentence() throws {
        struct Odd: Error {}
        #expect(!Picks.reason(of: Odd()).isEmpty)
    }
}
