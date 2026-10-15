import Foundation
import GRDB

/// What `stat` says about a file. An unchanged stat means an unchanged file, so a cached
/// read never opens the PDF.
public struct FileStat: Equatable, Sendable {
    public let size: Int64
    public let modifiedNanos: Int64
    public let inode: Int64
    public let device: Int64

    public init?(path: String) {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        size = Int64(info.st_size)
        modifiedNanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        inode = Int64(bitPattern: UInt64(info.st_ino))
        device = Int64(info.st_dev)
    }

    init(size: Int64, modifiedNanos: Int64, inode: Int64, device: Int64) {
        self.size = size
        self.modifiedNanos = modifiedNanos
        self.inode = inode
        self.device = device
    }
}

/// How the cache knows a file: the document it holds, or why it could not be read.
public enum FileEntry: Equatable, Sendable {
    case document(id: String)
    case failed(reason: String)
}

public struct PageResult: Equatable, Sendable {
    public enum Status: String, Sendable { case ok, failed }

    public let status: Status
    /// The step that produced the page, such as `pdfkit`. Empty for a failed page.
    public let method: String
    public let text: String
    /// Why the page failed. Empty for a page that read well.
    public let reason: String
    public let macOSBuild: String
    public let parseMillis: Double
    /// The page's text layer as JSON: blocks and lines with their positions.
    public let data: String

    public init(status: Status, method: String, text: String, reason: String,
                macOSBuild: String = Env.macOSBuild, parseMillis: Double, data: String = "") {
        self.status = status
        self.method = method
        self.text = text
        self.reason = reason
        self.macOSBuild = macOSBuild
        self.parseMillis = parseMillis
        self.data = data
    }

    /// The text layer, decoded. Nil for a failed page.
    public var pageText: PageText? {
        try? JSONDecoder().decode(PageText.self, from: Data(data.utf8))
    }

    public static func failed(_ reason: String) -> PageResult {
        PageResult(status: .failed, method: "", text: "", reason: reason, parseMillis: 0)
    }
}

/// The SQLite cache. Every process opens it: the CLI reads it, and the runner writes it.
///
/// Page results are keyed by page content and parser version
/// (DESIGNS.md → Principles → Cache). Writes take SQLite's write lock at once, because
/// several processes share the file.
public final class Store: Sendable {
    let pool: DatabasePool

    public init(directory: URL = Env.cacheDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        pool = try Store.open(directory.appendingPathComponent("cache.sqlite").path, configuration)
        try write { db in try Store.createSchema(db) }
    }

    /// Opens the database. When several commands open a new cache at the same moment, the
    /// switch to WAL mode can find the file locked before the busy timeout applies, so the
    /// open is tried again for up to 2 s.
    static func open(_ path: String, _ configuration: Configuration) throws -> DatabasePool {
        var attempt = 0
        while true {
            do {
                return try DatabasePool(path: path, configuration: configuration)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY && attempt < 100 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    /// Runs `body` in a transaction that holds the write lock from its first statement,
    /// so two processes never interleave a read and a write.
    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.writeWithoutTransaction { db in
            var value: T?
            try db.inTransaction(.immediate) {
                value = try body(db)
                return .commit
            }
            return value!
        }
    }

    static let schemaVersion = 2

    static func createSchema(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard version < schemaVersion else { return }
        try createVersion1(db)
        // Version 2: the text layer of each page, and the font check of each document.
        if try !db.columns(in: "page_result").contains(where: { $0.name == "data" }) {
            try db.execute(sql: "ALTER TABLE page_result ADD COLUMN data TEXT NOT NULL DEFAULT ''")
        }
        if try !db.columns(in: "document").contains(where: { $0.name == "spaces_at_risk" }) {
            try db.execute(sql: "ALTER TABLE document ADD COLUMN spaces_at_risk INTEGER NOT NULL DEFAULT 0")
        }
        if version == 1 {
            // Files indexed before the font check existed have no verdict. Forgetting their
            // entries makes the next read index them again, and run the check.
            try db.execute(sql: "DELETE FROM file_entry")
        }
        try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
    }

    static func createVersion1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS file_entry (
                path TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                modified_ns INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                device INTEGER NOT NULL,
                doc_id TEXT,
                failure TEXT,
                indexed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS document (
                id TEXT PRIMARY KEY,
                page_count INTEGER NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS document_page (
                doc_id TEXT NOT NULL,
                page_index INTEGER NOT NULL,
                page_key TEXT NOT NULL,
                PRIMARY KEY (doc_id, page_index)
            );
            CREATE INDEX IF NOT EXISTS document_page_by_key ON document_page (page_key);
            CREATE TABLE IF NOT EXISTS page_result (
                page_key TEXT NOT NULL,
                parser_version INTEGER NOT NULL,
                status TEXT NOT NULL,
                method TEXT NOT NULL,
                text TEXT NOT NULL,
                reason TEXT NOT NULL,
                macos_build TEXT NOT NULL,
                parse_ms REAL NOT NULL,
                parsed_at REAL NOT NULL,
                PRIMARY KEY (page_key, parser_version)
            );
            CREATE TABLE IF NOT EXISTS page_request (
                doc_id TEXT NOT NULL,
                page_index INTEGER NOT NULL,
                requested_at REAL NOT NULL,
                PRIMARY KEY (doc_id, page_index)
            );
            CREATE TABLE IF NOT EXISTS runner_lock (
                lock_key TEXT PRIMARY KEY,
                pid INTEGER NOT NULL,
                heartbeat_at REAL NOT NULL
            );
            """)
    }

    // MARK: Files and documents

    /// The cached entry for a file, if the file has not changed since it was indexed.
    public func entry(path: String, stat: FileStat) throws -> FileEntry? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT doc_id, failure FROM file_entry
                WHERE path = ? AND size = ? AND modified_ns = ? AND inode = ? AND device = ?
                """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device])
            else { return nil }
            if let id: String = row["doc_id"] { return .document(id: id) }
            return .failed(reason: row["failure"] ?? "unknown")
        }
    }

    /// Records a file's pages. The document's ID hashes its page keys, so two copies of one
    /// file, or one file with new highlights, share a document.
    /// `spacesAtRisk` is the font check's verdict for the whole file.
    @discardableResult
    public func saveIndex(path: String, stat: FileStat, pageKeys: [String], spacesAtRisk: Bool = false) throws -> String {
        let id = Store.documentID(pageKeys: pageKeys)
        try write { db in
            try db.execute(sql: """
                INSERT INTO document (id, page_count, created_at, spaces_at_risk) VALUES (?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET spaces_at_risk = excluded.spaces_at_risk
                """, arguments: [id, pageKeys.count, Date().timeIntervalSince1970, spacesAtRisk])
            for (index, key) in pageKeys.enumerated() {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO document_page (doc_id, page_index, page_key) VALUES (?, ?, ?)
                    """, arguments: [id, index, key])
            }
            try saveEntry(db, path: path, stat: stat, docID: id, failure: nil)
        }
        return id
    }

    public func saveFailure(path: String, stat: FileStat, reason: String) throws {
        try write { db in try saveEntry(db, path: path, stat: stat, docID: nil, failure: reason) }
    }

    func saveEntry(_ db: Database, path: String, stat: FileStat, docID: String?, failure: String?) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO file_entry
                (path, size, modified_ns, inode, device, doc_id, failure, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device,
                             docID, failure, Date().timeIntervalSince1970])
    }

    static func documentID(pageKeys: [String]) -> String {
        Hashing.hex(of: Data(pageKeys.joined(separator: "\n").utf8))
    }

    /// The font check's verdict for a document: its pages need the space repair.
    public func spacesAtRisk(docID: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT spaces_at_risk FROM document WHERE id = ?", arguments: [docID]) ?? false
        }
    }

    /// The key of every page, in page order.
    public func pageKeys(docID: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT page_key FROM document_page WHERE doc_id = ? ORDER BY page_index
                """, arguments: [docID])
        }
    }

    // MARK: Page results

    public func results(keys: [String]) throws -> [String: PageResult] {
        guard !keys.isEmpty else { return [:] }
        return try pool.read { db in
            var found: [String: PageResult] = [:]
            for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM page_result WHERE parser_version = ? AND page_key IN (\(marks))
                    """, arguments: StatementArguments([Env.parserVersion] + chunk)!)
                for row in rows {
                    found[row["page_key"]] = PageResult(
                        status: PageResult.Status(rawValue: row["status"]) ?? .failed,
                        method: row["method"], text: row["text"], reason: row["reason"],
                        macOSBuild: row["macos_build"], parseMillis: row["parse_ms"], data: row["data"])
                }
            }
            return found
        }
    }

    /// Stores a page's result. A result already cached stays, so a failure never replaces a
    /// page that read well.
    public func saveResult(key: String, _ result: PageResult) throws {
        try write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO page_result
                    (page_key, parser_version, status, method, text, reason, macos_build, parse_ms, parsed_at, data)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [key, Env.parserVersion, result.status.rawValue, result.method,
                                 result.text, result.reason, result.macOSBuild, result.parseMillis,
                                 Date().timeIntervalSince1970, result.data])
        }
    }

    // MARK: Requests from commands

    /// Asks the runner to parse these pages before the rest.
    public func request(docID: String, pages: [Int]) throws {
        guard !pages.isEmpty else { return }
        try write { db in
            for page in pages {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO page_request (doc_id, page_index, requested_at) VALUES (?, ?, ?)
                    """, arguments: [docID, page, Date().timeIntervalSince1970])
            }
        }
    }

    public func requestedPages(docID: String) throws -> [Int] {
        try pool.read { db in
            try Int.fetchAll(db, sql: """
                SELECT page_index FROM page_request WHERE doc_id = ? ORDER BY requested_at, page_index
                """, arguments: [docID])
        }
    }

    public func clearRequests(docID: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM page_request WHERE doc_id = ?", arguments: [docID])
        }
    }

    // MARK: Runner locks

    /// A lock is alive while its holder's heartbeat is fresh and its process exists.
    static let heartbeatTimeout: TimeInterval = 5

    /// Takes the lock unless a live process holds it.
    public func acquireLock(_ key: String, pid: Int32 = getpid()) throws -> Bool {
        try write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT pid, heartbeat_at FROM runner_lock WHERE lock_key = ?",
                                          arguments: [key]) {
                let holder: Int32 = row["pid"]
                let heartbeat: Double = row["heartbeat_at"]
                if holder != pid && Store.isAlive(pid: holder, heartbeat: heartbeat) { return false }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO runner_lock (lock_key, pid, heartbeat_at) VALUES (?, ?, ?)",
                           arguments: [key, pid, Date().timeIntervalSince1970])
            return true
        }
    }

    public func isLockAlive(_ key: String) throws -> Bool {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT pid, heartbeat_at FROM runner_lock WHERE lock_key = ?",
                                             arguments: [key]) else { return false }
            return Store.isAlive(pid: row["pid"], heartbeat: row["heartbeat_at"])
        }
    }

    /// Refreshes the locks this process holds. Returns the ones it still holds: a lock missing
    /// from the answer was taken over by another process.
    public func heartbeat(_ keys: [String], pid: Int32 = getpid()) throws -> [String] {
        guard !keys.isEmpty else { return [] }
        return try write { db in
            var held: [String] = []
            for key in keys {
                try db.execute(sql: "UPDATE runner_lock SET heartbeat_at = ? WHERE lock_key = ? AND pid = ?",
                               arguments: [Date().timeIntervalSince1970, key, pid])
                if db.changesCount > 0 { held.append(key) }
            }
            return held
        }
    }

    public func releaseLock(_ key: String, pid: Int32 = getpid()) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM runner_lock WHERE lock_key = ? AND pid = ?", arguments: [key, pid])
        }
    }

    static func isAlive(pid: Int32, heartbeat: Double) -> Bool {
        guard Date().timeIntervalSince1970 - heartbeat < heartbeatTimeout else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
