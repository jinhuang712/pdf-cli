import Foundation
import Testing
@testable import PDFCore

@Suite struct StoreTests {
    func makeStore() throws -> Store {
        try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-store-\(UUID())"))
    }

    let stat = FileStat(size: 100, modifiedNanos: 1, inode: 2, device: 3)

    @Test func aChangedFileHasNoEntry() throws {
        let store = try makeStore()
        let id = try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k1", "k2"])
        #expect(try store.entry(path: "/a.pdf", stat: stat) == .document(id: id))
        let touched = FileStat(size: 100, modifiedNanos: 9, inode: 2, device: 3)
        #expect(try store.entry(path: "/a.pdf", stat: touched) == nil)
        #expect(try store.pageKeys(docID: id) == ["k1", "k2"])
    }

    func result(_ text: String) -> PageResult {
        PageResult(status: .ok, method: "pdfkit", text: text, reason: "", parseMillis: 1)
    }

    @Test func removingAFileKeepsThePagesAnotherFileStillUses() throws {
        let store = try makeStore()
        let first = try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k1", "k2"])
        try store.saveIndex(path: "/b.pdf", stat: stat, pageKeys: ["k2", "k3"])
        for key in ["k1", "k2", "k3"] { try store.saveResult(key: key, result(key)) }
        let removed = try store.remove(paths: ["/a.pdf"])
        #expect(removed == Store.Removed(files: 1, documents: 1, pages: 1))
        #expect(try store.pageKeys(docID: first).isEmpty)
        #expect(Set(try store.results(keys: ["k1", "k2", "k3"]).keys) == ["k2", "k3"])
    }

    @Test func garbageIsWhatNoReadCanReach() throws {
        let store = try makeStore()
        // The file is gone: its entry, its document and its pages go.
        try store.saveIndex(path: "/gone-\(UUID()).pdf", stat: stat, pageKeys: ["gone"])
        try store.saveResult(key: "gone", result("gone"))
        // The file is here and unchanged: its pages stay, except results of an older parser.
        let here = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-here-\(UUID()).pdf").path
        FileManager.default.createFile(atPath: here, contents: Data("%PDF-".utf8))
        defer { try? FileManager.default.removeItem(atPath: here) }
        try store.saveIndex(path: here, stat: try #require(FileStat(path: here)), pageKeys: ["here"])
        try store.saveResult(key: "here", result("here"))
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO page_result (page_key, parser_version, status, method, text, reason, macos_build, parse_ms, parsed_at)
                VALUES ('here', ?, 'ok', 'pdfkit', 'old', '', '', 0, 0)
                """, arguments: [Env.parserVersion - 1])
        }
        let removed = try store.collectGarbage()
        #expect(removed == Store.Removed(files: 1, documents: 1, pages: 2))
        #expect(try store.results(keys: ["here"])["here"]?.text == "here")
        #expect(try store.knows(path: here))
    }

    @Test func anEntryIndexedWithOlderChecksIsReadAgainButKeepsItsPages() throws {
        let store = try makeStore()
        let here = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-checks-\(UUID()).pdf").path
        FileManager.default.createFile(atPath: here, contents: Data("%PDF-".utf8))
        defer { try? FileManager.default.removeItem(atPath: here) }
        let stat = try #require(FileStat(path: here))
        try store.saveIndex(path: here, stat: stat, pageKeys: ["k"])
        try store.saveResult(key: "k", result("text"))
        try store.write { db in try db.execute(sql: "UPDATE file_entry SET checks = 0") }
        #expect(try store.entry(path: here, stat: stat) == nil)
        #expect(try store.collectGarbage() == Store.Removed())
        #expect(try store.results(keys: ["k"])["k"] != nil)
    }

    @Test func compactingGivesTheSpaceBack() throws {
        let store = try makeStore()
        let filler = String(repeating: "word ", count: 4_000)
        try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: (0..<200).map { "k\($0)" })
        for index in 0..<200 {
            try store.saveResult(key: "k\(index)", PageResult(status: .ok, method: "pdfkit", text: filler, reason: "",
                                                               parseMillis: 1, data: filler))
        }
        let full = store.size
        try store.remove(paths: ["/a.pdf"])
        #expect(store.compact())
        #expect(store.size * 4 < full)
    }

    @Test func pagesTheIndexCouldNotReadAreSavedWithTheirDocument() throws {
        let store = try makeStore()
        try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k1", "unreadable-x-1"],
                            failures: ["unreadable-x-1": "time limit"])
        #expect(try store.results(keys: ["unreadable-x-1"])["unreadable-x-1"]?.reason == "time limit")
    }

    @Test func aFileOnADriveNotPluggedInIsNotGone() {
        #expect(FileStat.isGone(path: "/private/tmp/pdf-cli-no-such-file-\(UUID()).pdf"))
        #expect(!FileStat.isGone(path: "/Volumes/No Such Drive \(UUID())/paper.pdf"))
    }

    @Test func twoCopiesShareADocument() throws {
        let store = try makeStore()
        let first = try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k1", "k2"])
        let second = try store.saveIndex(path: "/copy.pdf", stat: stat, pageKeys: ["k1", "k2"])
        #expect(first == second)
    }

    @Test func aFailureNeverReplacesAGoodPage() throws {
        let store = try makeStore()
        let good = PageResult(status: .ok, method: "pdfkit", text: "hello", reason: "", parseMillis: 3)
        try store.saveResult(key: "k1", good)
        try store.saveResult(key: "k1", .failed("time limit"))
        #expect(try store.results(keys: ["k1"])["k1"]?.text == "hello")
    }

    @Test func aFileThatFailedIsRemembered() throws {
        let store = try makeStore()
        try store.saveFailure(path: "/x.pdf", stat: stat, reason: "not a PDF")
        #expect(try store.entry(path: "/x.pdf", stat: stat) == .failed(reason: "not a PDF"))
    }

    @Test func aLiveLockKeepsOthersOut() throws {
        let store = try makeStore()
        #expect(try store.acquireLock("path:/a.pdf"))
        // Process 1 always exists, so a fresh lock in its name counts as alive.
        #expect(try store.acquireLock("path:/b.pdf", pid: 1))
        #expect(try !store.acquireLock("path:/b.pdf"))
        #expect(try store.isLockAlive("path:/b.pdf"))
        try store.releaseLock("path:/a.pdf")
        #expect(try !store.isLockAlive("path:/a.pdf"))
    }

    @Test func aLockWithAStaleHeartbeatIsFree() throws {
        let store = try makeStore()
        try store.write { db in
            try db.execute(sql: "INSERT INTO runner_lock (lock_key, pid, heartbeat_at) VALUES ('doc:x', 1, ?)",
                           arguments: [Date().timeIntervalSince1970 - 60])
        }
        #expect(try !store.isLockAlive("doc:x"))
        #expect(try store.acquireLock("doc:x"))
    }

    @Test func manyKeysAreReadInChunks() throws {
        let store = try makeStore()
        let keys = (0..<1200).map { "k\($0)" }
        for key in keys {
            try store.saveResult(key: key, PageResult(status: .ok, method: "pdfkit", text: key, reason: "", parseMillis: 0))
        }
        #expect(try store.results(keys: keys).count == 1200)
    }
}
