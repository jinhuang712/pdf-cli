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
