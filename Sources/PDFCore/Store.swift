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

    /// Whether a file is gone for good: no such file, on a volume that is mounted. A file on an
    /// unplugged drive, on an offline share or behind a folder it may not read is only out of
    /// reach, and a cleanup keeps what it knows of it.
    public static func isGone(path: String) -> Bool {
        var info = Darwin.stat()
        guard stat(path, &info) != 0, errno == ENOENT else { return false }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes" {
            var mount = Darwin.stat()
            return stat("/Volumes/\(parts[1])", &mount) == 0
        }
        return true
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
    /// What the verdict reads of the layer, as the cache stores it (`PageMeasures.stored`), or
    /// nil where the cache has not stored it.
    let verdict: String?

    public init(status: Status, method: String, text: String, reason: String,
                macOSBuild: String = Env.macOSBuild, parseMillis: Double, data: String = "") {
        self.init(status: status, method: method, text: text, reason: reason, macOSBuild: macOSBuild,
                  parseMillis: parseMillis, data: data, verdict: nil)
    }

    init(status: Status, method: String, text: String, reason: String, macOSBuild: String, parseMillis: Double,
         data: String, verdict: String?) {
        self.status = status
        self.method = method
        self.text = text
        self.reason = reason
        self.macOSBuild = macOSBuild
        self.parseMillis = parseMillis
        self.data = data
        self.verdict = verdict
    }

    /// The text layer, decoded once, however often a command asks: `pdf info` asks for each
    /// page's several times. Nil for a failed page.
    public var pageText: PageText? { decoded.layer(from: data) }

    /// What the verdict reads of the layer: as the cache stored it, or else from the layer.
    /// Nil where the layer cannot be read.
    public var measures: PageMeasures? {
        decoded.measures { verdict.map(PageMeasures.decode) ?? pageText.map(PageMeasures.init) }
    }

    private let decoded = DecodedLayer()

    public static func failed(_ reason: String) -> PageResult {
        PageResult(status: .failed, method: "", text: "", reason: reason, parseMillis: 0)
    }

    public static func == (lhs: PageResult, rhs: PageResult) -> Bool {
        lhs.status == rhs.status && lhs.method == rhs.method && lhs.text == rhs.text && lhs.reason == rhs.reason
            && lhs.macOSBuild == rhs.macOSBuild && lhs.parseMillis == rhs.parseMillis && lhs.data == rhs.data
    }
}

/// A page's text layer and measures, each decoded the first time it is asked for. Copies of a
/// result share them, and a result's data never changes.
final class DecodedLayer: @unchecked Sendable {
    private let lock = NSLock()
    private var layer: PageText??
    private var measures: PageMeasures??

    func layer(from data: String) -> PageText? {
        lock.lock()
        defer { lock.unlock() }
        if let layer { return layer }
        let decoded = try? JSONDecoder().decode(PageText.self, from: Data(data.utf8))
        layer = .some(decoded)
        return decoded
    }

    /// The measures, from `read` the first time. `read` may ask for the layer, so it runs
    /// outside the lock.
    func measures(_ read: () -> PageMeasures?) -> PageMeasures? {
        lock.lock()
        let known = measures
        lock.unlock()
        if let known { return known }
        let value = read()
        lock.lock()
        measures = .some(value)
        lock.unlock()
        return value
    }
}

/// The SQLite cache. Every process opens it: the CLI reads it, and the runner writes it.
///
/// Page results are keyed by page content and parser version
/// (DESIGNS.md → Principles → Cache). Writes take SQLite's write lock at once, because
/// several processes share the file.
public final class Store: Sendable {
    let pool: DatabasePool

    /// A dry run says why it cannot open the cache without changing it.
    public struct OlderCache: Error, CustomStringConvertible {
        public var description: String {
            "the cache is from an older version of pdf, which the next normal command brings up to date; a dry run changes nothing: run pdf ls, then again"
        }
    }

    /// With `readOnly` (a dry run, plan/ROADMAP.md → M2.18) the file is opened read-only: no folder,
    /// no schema, no row, and no write of any kind. A cache from an older schema is refused,
    /// as only a normal command brings it up to date. The file must exist, see `exists`.
    public init(directory: URL = Env.cacheDirectory, readOnly: Bool = false) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        let path = directory.appendingPathComponent("cache.sqlite").path
        if readOnly {
            configuration.readonly = true
            pool = try Store.open(path, configuration)
            let version = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
            guard version >= Store.schemaVersion else { throw OlderCache() }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pool = try Store.open(path, configuration)
        try write { db in try Store.createSchema(db) }
    }

    /// A read-only open that finds a journal a crashed writer left (SQLite's error 8, a database
    /// it may not repair), or log files gone (error 14), reads as one sentence: only a normal
    /// command repairs it.
    public static func readOnlyFailure(_ error: Error) -> String? {
        guard let error = error as? DatabaseError else { return nil }
        if error.resultCode == .SQLITE_CANTOPEN {
            // A cache in WAL mode whose log files are gone (a clean close deletes them) cannot be
            // opened read-only: SQLite would have to create them.
            return
                "the cache's log files are gone, so a dry run cannot read it without writing; the next normal command recreates them: run pdf ls, then again"
        }
        guard error.resultCode == .SQLITE_READONLY else { return nil }
        return
            "another pdf run was cut off and left its work half written; the next normal command repairs it, and a dry run changes nothing: run pdf ls, then again"
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

    static let schemaVersion = 9

    static func createSchema(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if version < schemaVersion { try createVersions(db) }
        // M2.26: the edge summaries came after version 9 without a new version, so they are
        // created whenever the cache opens, as `IF NOT EXISTS`.
        try createEdgeSummaries(db)
    }

    static func createVersions(_ db: Database) throws {
        try createVersion1(db)
        // Version 2: the text layer of each page, and the font check of each document.
        // Version 3: the sample check of each document.
        // Version 4: whether PDFKit saved the document.
        // Version 5: the document's title, and the index checks each file entry ran.
        // Version 6: each file's facts.
        // Version 8: what the verdict reads of each page's layer, so a listing need not decode
        // it. Pages cached before it have none until a listing first judges them.
        for (table, column, type) in [("page_result", "data", "TEXT NOT NULL DEFAULT ''"),
                                      ("page_result", "verdict", "TEXT"),
                                      ("document", "spaces_at_risk", "INTEGER NOT NULL DEFAULT 0"),
                                      ("document", "needs_ocr", "INTEGER NOT NULL DEFAULT 0"),
                                      ("document", "saved_by_pdfkit", "INTEGER NOT NULL DEFAULT 0"),
                                      ("document", "title", "TEXT NOT NULL DEFAULT ''"),
                                      ("file_entry", "checks", "INTEGER NOT NULL DEFAULT 0"),
                                      ("file_entry", "facts", "TEXT NOT NULL DEFAULT ''")]
        where try !db.columns(in: table).contains(where: { $0.name == column }) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
        // Entries indexed before version 5 get checks 0, so the next read indexes their files
        // again. Earlier versions deleted every entry instead, which let `pdf gc` drop every
        // document before its file was read again.
        // Version 7: the keyword index. Pages cached before it join the index when a search
        // first looks at their document.
        try createSearchIndex(db)
        // Version 9: each page's annotations, in a table of their own. Files indexed before it
        // have none, as their entries carry older index checks: the next read indexes them again.
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS page_annotation (
                    path TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    data TEXT NOT NULL,
                    more INTEGER NOT NULL DEFAULT 0,
                    why INTEGER NOT NULL DEFAULT 0,
                    words INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (path, page_index)
                )
                """)
        try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
    }

    /// The checks the index runs on a file: the font check, the sample check, the producer,
    /// the title, the facts and the annotations of each page. Raise it when they change. A file entry indexed with older
    /// checks still holds its document, so a cleanup keeps the document's pages, but a read
    /// indexes the file again and runs every check.
    static let indexChecks = 11

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

    /// The cached entry for a file, if the file has not changed since it was indexed, with the
    /// index checks of this version. A file found slow to open is tried again once its verdict is
    /// older than `Env.slowOpenRetry`, and so is one that an earlier version cached as damaged
    /// because it was slow to open.
    public func entry(path: String, stat: FileStat) throws -> FileEntry? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT doc_id, failure, indexed_at FROM file_entry
                WHERE path = ? AND size = ? AND modified_ns = ? AND inode = ? AND device = ? AND checks = ?
                """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device, Store.indexChecks])
            else { return nil }
            if let id: String = row["doc_id"] { return .document(id: id) }
            let reason: String = row["failure"] ?? "unknown"
            let age = Date().timeIntervalSince1970 - (row["indexed_at"] as Double? ?? 0)
            if reason.hasPrefix(OpenFailure.slow) && age >= Env.slowOpenRetry { return nil }
            if reason.hasPrefix("damaged: the reader stopped while opening it (time limit") { return nil }
            return .failed(reason: reason)
        }
    }

    /// Whether the cache holds an entry for this very version of the file, whatever checks it ran:
    /// an entry that `entry` does not return then comes from an older `pdf`, not from a changed file.
    public func hasEntry(path: String, stat: FileStat) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM file_entry WHERE path = ? AND size = ? AND modified_ns = ? AND inode = ? AND device = ?
                    """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device]) ?? false
        }
    }

    /// Records a file's pages. The document's ID hashes its page keys, so two copies of one
    /// file, or one file with new highlights, share a document.
    /// `spacesAtRisk` is the font check's verdict for the whole file, `needsOCR` the sample
    /// check's, and `savedByPDFKit` says the file's producer is macOS's PDFKit. `title` is the
    /// title the file names in its metadata, or empty. `failures` are the results of pages the
    /// index could not read, by key: they go in the same transaction as their document, so a
    /// cleanup in between never drops them. `facts` belong to this version of the file, so they
    /// go with its entry.
    @discardableResult
    public func saveIndex(path: String, stat: FileStat, pageKeys: [String], spacesAtRisk: Bool = false,
                          needsOCR: Bool = false, savedByPDFKit: Bool = false, title: String = "",
                          failures: [String: String] = [:], facts: FileFacts? = nil) throws -> String {
        let id = Store.documentID(pageKeys: pageKeys)
        try write { db in
            for (key, reason) in failures { try Store.insertResult(db, key: key, .failed(reason)) }
            try db.execute(sql: """
                INSERT INTO document (id, page_count, created_at, spaces_at_risk, needs_ocr, saved_by_pdfkit, title)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET spaces_at_risk = excluded.spaces_at_risk, needs_ocr = excluded.needs_ocr,
                    saved_by_pdfkit = excluded.saved_by_pdfkit, title = excluded.title
                """, arguments: [id, pageKeys.count, Date().timeIntervalSince1970, spacesAtRisk, needsOCR, savedByPDFKit,
                                 title])
            for (index, key) in pageKeys.enumerated() {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO document_page (doc_id, page_index, page_key) VALUES (?, ?, ?)
                    """, arguments: [id, index, key])
            }
            // The facts keep to the file's entry; its annotations go per page, in the same transaction,
            // so a reader sees the old file's or the new file's, never a mix.
            var kept = facts
            kept?.annotations = []
            kept?.moreOnPage = [:]
            kept?.whyOnPage = [:]
            let encoded = kept.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            try saveEntry(db, path: path, stat: stat, docID: id, failure: nil, facts: encoded ?? "")
            try Store.saveAnnotations(db, path: path, facts: facts)
        }
        return id
    }

    /// The annotations of one page of a file, with how many more the page holds past what is kept
    /// and why (`FactReader.Cap` bits), and whether the words under its links are read yet.
    public struct PageAnnotations: Equatable, Sendable {
        /// `WordsState.pending` until the words under the page's links are read.
        public enum WordsState: Int, Sendable { case pending = 0, read = 1, failed = 2 }
        public var annotations: [FileFacts.Annotation]
        public var more: Int
        public var why: Int
        public var words: WordsState
        public init(annotations: [FileFacts.Annotation] = [], more: Int = 0, why: Int = 0, words: WordsState = .read) {
            self.annotations = annotations
            self.more = more
            self.why = why
            self.words = words
        }
    }

    /// Replaces the rows of a file's pages: one per page that holds an annotation or has some left
    /// out. The file's facts are the whole truth about this version of the file. A page with links
    /// waits for their words (`saveWords`).
    static func saveAnnotations(_ db: Database, path: String, facts: FileFacts?) throws {
        try db.execute(sql: "DELETE FROM page_annotation WHERE path = ?", arguments: [path])
        guard let facts else { return }
        let encoder = JSONEncoder()
        let byPage = Dictionary(grouping: facts.annotations, by: \.page)
        for page in Set(byPage.keys).union(facts.moreOnPage.keys).sorted() {
            let list = byPage[page] ?? []
            guard let data = try? encoder.encode(list) else { continue }
            let pending = list.contains { $0.kind == .link }
            try db.execute(
                sql: "INSERT INTO page_annotation (path, page_index, data, more, why, words) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [path, page, String(bytes: data, encoding: .utf8) ?? "[]", facts.moreOnPage[page] ?? 0,
                            facts.whyOnPage[page] ?? 0, pending ? 0 : 1])
        }
    }

    /// Puts the words under a page's links into its row, once: `words` holds the words by the
    /// link's place in the page's list, and nil says the reading failed. Only while the file is the
    /// version `stat` names and the row still waits, so a file indexed again meanwhile keeps its own.
    public func saveWords(path: String, stat: FileStat, page: Int, words: [Int: String]?) throws {
        try write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT a.data, a.words FROM page_annotation a JOIN file_entry e ON e.path = a.path
                        WHERE a.path = ? AND a.page_index = ? AND a.words = 0
                          AND e.size = ? AND e.modified_ns = ? AND e.inode = ? AND e.device = ? AND e.checks = ?
                        """, arguments: [path, page, stat.size, stat.modifiedNanos, stat.inode, stat.device, Store.indexChecks])
            else { return }
            guard let words else {
                try db.execute(sql: "UPDATE page_annotation SET words = 2 WHERE path = ? AND page_index = ?", arguments: [path, page])
                return
            }
            let data: String = row["data"]
            var list = (try? JSONDecoder().decode([FileFacts.Annotation].self, from: Data(data.utf8))) ?? []
            for (index, text) in words where list.indices.contains(index) && list[index].kind == .link {
                list[index].words = text
            }
            let encoded = String(bytes: try JSONEncoder().encode(list), encoding: .utf8) ?? data
            try db.execute(sql: "UPDATE page_annotation SET data = ?, words = 1 WHERE path = ? AND page_index = ?",
                           arguments: [encoded, path, page])
        }
    }

    /// The annotations of these pages (counted from 0) of the file as it is now, if the cache
    /// knows this version of it. Only their rows are decoded; a page with none is left out.
    public func annotations(path: String, stat: FileStat, pages: [Int]) throws -> [Int: PageAnnotations] {
        let decoder = JSONDecoder()
        var found: [Int: PageAnnotations] = [:]
        try pool.read { db in
            // The entry and its rows are read in one snapshot, so a file indexed again in between
            // cannot give rows of another version.
            guard
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT 1 FROM file_entry
                        WHERE path = ? AND size = ? AND modified_ns = ? AND inode = ? AND device = ? AND checks = ?
                        """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device, Store.indexChecks]) == true
            else { return }
            for chunk in stride(from: 0, to: pages.count, by: 500).map({ Array(pages[$0..<min($0 + 500, pages.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT page_index, data, more, why, words FROM page_annotation WHERE path = ? AND page_index IN (\(marks))
                        """, arguments: StatementArguments([path as any DatabaseValueConvertible] + chunk.map { $0 as any DatabaseValueConvertible }))
                for row in rows {
                    let data: String = row["data"]
                    let list = (try? decoder.decode([FileFacts.Annotation].self, from: Data(data.utf8))) ?? []
                    found[row["page_index"]] = PageAnnotations(
                        annotations: list, more: row["more"], why: row["why"],
                        words: PageAnnotations.WordsState(rawValue: row["words"]) ?? .failed)
                }
            }
        }
        return found
    }

    /// The facts of a file as it is now, if the cache knows this version of it. With `olderChecks`,
    /// facts that an older version of the index read of this very file count too: good for what
    /// they hold and the new version does not change, as the outline.
    public func facts(path: String, stat: FileStat, olderChecks: Bool = false) throws -> FileFacts? {
        let text = try pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT facts FROM file_entry
                WHERE path = ? AND size = ? AND modified_ns = ? AND inode = ? AND device = ? AND (checks = ? OR ?)
                """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device, Store.indexChecks, olderChecks])
        }
        guard let text, !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(FileFacts.self, from: Data(text.utf8))
    }

    public func saveFailure(path: String, stat: FileStat, reason: String) throws {
        try write { db in try saveEntry(db, path: path, stat: stat, docID: nil, failure: reason) }
    }

    /// Forgets how the cache knows a file, so the next read indexes it again, as after a
    /// password that opens a file cached as locked.
    public func forgetEntry(path: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM file_entry WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM page_annotation WHERE path = ?", arguments: [path])
        }
    }

    /// The title the document's file names, empty when it names none, and its page count.
    public func documentInfo(docID: String) throws -> (title: String, pageCount: Int)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT title, page_count FROM document WHERE id = ?", arguments: [docID])
                .map { ($0["title"], $0["page_count"]) }
        }
    }

    func saveEntry(_ db: Database, path: String, stat: FileStat, docID: String?, failure: String?, facts: String = "") throws {
        // An entry stands for one version of the file; the rows of the version before it go.
        try db.execute(sql: "DELETE FROM page_annotation WHERE path = ?", arguments: [path])
        try db.execute(sql: """
            INSERT OR REPLACE INTO file_entry
                (path, size, modified_ns, inode, device, doc_id, failure, indexed_at, checks, facts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device,
                             docID, failure, Date().timeIntervalSince1970, Store.indexChecks, facts])
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

    /// The sample check's verdict for a document: OCR reads every page.
    public func needsOCR(docID: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT needs_ocr FROM document WHERE id = ?", arguments: [docID]) ?? false
        }
    }

    /// Whether macOS's PDFKit saved the document, as Preview saves a file.
    public func savedByPDFKit(docID: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT saved_by_pdfkit FROM document WHERE id = ?", arguments: [docID]) ?? false
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

    /// Which of these keys have a cached result, without loading the results.
    public func cachedKeys(_ keys: [String]) throws -> Set<String> {
        let unique = Array(Set(keys))
        return try pool.read { db in
            var found = Set<String>()
            for chunk in stride(from: 0, to: unique.count, by: 500).map({ Array(unique[$0..<min($0 + 500, unique.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                found.formUnion(try String.fetchAll(db, sql: """
                    SELECT page_key FROM page_result WHERE parser_version = ? AND page_key IN (\(marks))
                    """, arguments: StatementArguments([Env.parserVersion] + chunk)!))
            }
            return found
        }
    }

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
                        macOSBuild: row["macos_build"], parseMillis: row["parse_ms"], data: row["data"],
                        verdict: row["verdict"])
                }
            }
            return found
        }
    }

    /// The results of these keys for judging alone, as `pdf ls` judges every page in the
    /// library: each without its text or layer, and with what the verdict reads of the layer.
    /// A result cached before that was stored comes with its layer, and gets it stored now.
    public func verdicts(keys: [String]) throws -> [String: PageResult] {
        let unique = Array(Set(keys))
        var found: [String: PageResult] = [:]
        try pool.read { db in
            for chunk in stride(from: 0, to: unique.count, by: 500).map({ Array(unique[$0..<min($0 + 500, unique.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT page_key, status, method, reason, macos_build, parse_ms, verdict,
                           CASE WHEN verdict IS NULL THEN data ELSE '' END AS data
                    FROM page_result WHERE parser_version = ? AND page_key IN (\(marks))
                    """, arguments: StatementArguments([Env.parserVersion] + chunk)!)
                for row in rows {
                    found[row["page_key"]] = PageResult(
                        status: PageResult.Status(rawValue: row["status"]) ?? .failed,
                        method: row["method"], text: "", reason: row["reason"],
                        macOSBuild: row["macos_build"], parseMillis: row["parse_ms"], data: row["data"],
                        verdict: row["verdict"])
                }
            }
        }
        let missing = found.filter { $0.value.verdict == nil }
        guard !missing.isEmpty else { return found }
        // A few hundred pages at a time, so no transaction holds the write lock long enough to
        // stall a runner. Storing them only saves the next listing time: a write that fails, as
        // on a cache another process holds locked, fails nothing.
        let entries = Array(missing)
        for start in stride(from: 0, to: entries.count, by: 200) {
            try? write { db in
                for (key, result) in entries[start..<min(start + 200, entries.count)] {
                    try db.execute(sql: """
                        UPDATE page_result SET verdict = ? WHERE page_key = ? AND parser_version = ? AND verdict IS NULL
                        """, arguments: [Store.verdict(of: result), key, Env.parserVersion])
                }
            }
        }
        return found
    }

    /// What the cache stores of a result's verdict: its measures, "{}" for a failed page, which
    /// needs none, and an empty string for a layer that cannot be read.
    static func verdict(of result: PageResult) -> String {
        if let verdict = result.verdict { return verdict }
        guard result.status == .ok else { return "{}" }
        return result.pageText.map { PageMeasures($0).stored } ?? ""
    }

    /// Stores a page's result. A result already cached stays, so a failure never replaces a
    /// page that read well.
    public func saveResult(key: String, _ result: PageResult) throws {
        try write { db in try Store.insertResult(db, key: key, result) }
    }

    /// Replaces the cached results of these page keys with new ones, all in one transaction, so a
    /// reader sees every old result or every new one, and a page is never without a result. The
    /// keyword index follows through the table's trigger and `insertResult`. A new result that
    /// failed never replaces one that read well: that page keeps its old result, and the reason
    /// comes back under its key. A key with no result yet gets the new one, failed or not.
    @discardableResult
    public func replaceResults(_ results: [String: PageResult]) throws -> [String: String] {
        try write { db in
            var kept: [String: String] = [:]
            for (key, result) in results.sorted(by: { $0.key < $1.key }) {
                let old = try String.fetchOne(
                    db, sql: "SELECT status FROM page_result WHERE page_key = ? AND parser_version = ?",
                    arguments: [key, Env.parserVersion])
                if result.status == .failed, old == PageResult.Status.ok.rawValue {
                    kept[key] = result.reason
                    continue
                }
                try db.execute(
                    sql: "DELETE FROM page_result WHERE page_key = ? AND parser_version = ?",
                    arguments: [key, Env.parserVersion])
                try Store.insertResult(db, key: key, result)
            }
            return kept
        }
    }

    static func insertResult(_ db: Database, key: String, _ result: PageResult) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO page_result
                (page_key, parser_version, status, method, text, reason, macos_build, parse_ms, parsed_at, data, verdict)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [key, Env.parserVersion, result.status.rawValue, result.method,
                             result.text, result.reason, result.macOSBuild, result.parseMillis,
                             Date().timeIntervalSince1970, result.data, verdict(of: result)])
        // The page joins the keyword index in the same transaction, so a search never sees a
        // cached page that it cannot find.
        if db.changesCount > 0 { try indexForSearch(db, key: key, version: Env.parserVersion, result: result) }
    }

    // MARK: Cleanup

    /// What a cleanup removed.
    public struct Removed: Equatable, Sendable {
        public var files = 0
        public var documents = 0
        public var pages = 0
        public init(files: Int = 0, documents: Int = 0, pages: Int = 0) {
            self.files = files
            self.documents = documents
            self.pages = pages
        }
    }

    /// Whether the cache knows a file at this path, changed since or not.
    public func knows(path: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM file_entry WHERE path = ?", arguments: [path]) ?? false
        }
    }

    /// The paths the cache knows for a document.
    public func paths(docID: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM file_entry WHERE doc_id = ? ORDER BY path", arguments: [docID])
        }
    }

    /// Forgets the files at these paths, and every document and page result that no other file
    /// still uses. Picks are the agent's work, kept apart, and stay.
    @discardableResult
    public func remove(paths: [String]) throws -> Removed {
        try write { db in
            var removed = Removed()
            for path in paths {
                try db.execute(sql: "DELETE FROM file_entry WHERE path = ?", arguments: [path])
                removed.files += db.changesCount
            }
            try Store.dropUnused(db, into: &removed)
            return removed
        }
    }

    /// What `remove` would give for these paths, counted with SELECTs that mirror its deletes and
    /// `dropUnused`, so a dry run takes no write lock and writes nothing.
    public func wouldRemove(paths: [String]) throws -> Removed {
        try pool.read { db in
            let marks = Array(repeating: "?", count: paths.count).joined(separator: ",")
            let arguments = StatementArguments(paths)
            var removed = Removed()
            let kept = "SELECT doc_id FROM file_entry WHERE doc_id IS NOT NULL AND path NOT IN (\(marks))"
            removed.files = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_entry WHERE path IN (\(marks))", arguments: arguments) ?? 0
            removed.documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document WHERE id NOT IN (\(kept))", arguments: arguments) ?? 0
            removed.pages =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM page_result WHERE page_key NOT IN (
                            SELECT page_key FROM document_page WHERE doc_id IN (\(kept)) AND doc_id IN (SELECT id FROM document))
                        """, arguments: arguments) ?? 0
            return removed
        }
    }

    /// The documents these files are indexed as.
    public func docIDs(paths: [String]) throws -> Set<String> {
        try pool.read { db in
            var found = Set<String>()
            for path in paths {
                if let id = try String.fetchOne(db, sql: "SELECT doc_id FROM file_entry WHERE path = ? AND doc_id IS NOT NULL", arguments: [path]) {
                    found.insert(id)
                }
            }
            return found
        }
    }

    /// Whether the cache's database exists yet: a dry run opens it only then.
    public static func exists(directory: URL = Env.cacheDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache.sqlite").path)
    }

    /// Removes what no read can reach any more: files gone or changed since they were indexed,
    /// the documents and pages only they used, results of older parser versions, and the locks
    /// of runners that are gone. A file out of reach, as on an unplugged drive, keeps its rows.
    public func collectGarbage() throws -> Removed {
        let stale = try staleFiles()
        // Which locks are left over is decided before anything is deleted, from the processes as
        // they are now: a lock whose process exists is not left over, however long it is silent.
        let leftover = try runners().leftover
        return try write { db in
            var removed = Removed()
            // Only an entry that still holds the stat read above goes: a runner may have indexed
            // the changed file again since, and its new entry stays.
            for (path, stat) in stale {
                try db.execute(sql: """
                    DELETE FROM file_entry WHERE path = ? AND size = ? AND modified_ns = ? AND inode = ? AND device = ?
                    """, arguments: [path, stat.size, stat.modifiedNanos, stat.inode, stat.device])
                removed.files += db.changesCount
            }
            try db.execute(sql: "DELETE FROM page_result WHERE parser_version <> ?", arguments: [Env.parserVersion])
            removed.pages += db.changesCount
            try Store.dropUnused(db, into: &removed)
            for key in leftover {
                try db.execute(sql: "DELETE FROM runner_lock WHERE lock_key = ?", arguments: [key])
            }
            return removed
        }
    }

    /// Drops documents no file uses, and page results no document uses. A runner saves a
    /// document and its file in one transaction, so a parse in progress keeps its rows.
    static func dropUnused(_ db: Database, into removed: inout Removed) throws {
        try db.execute(sql: "DELETE FROM page_annotation WHERE path NOT IN (SELECT path FROM file_entry)")
        try db.execute(sql: "DELETE FROM document WHERE id NOT IN (SELECT doc_id FROM file_entry WHERE doc_id IS NOT NULL)")
        removed.documents += db.changesCount
        try db.execute(sql: "DELETE FROM document_page WHERE doc_id NOT IN (SELECT id FROM document)")
        try db.execute(sql: "DELETE FROM page_request WHERE doc_id NOT IN (SELECT id FROM document)")
        try db.execute(sql: "DELETE FROM page_result WHERE page_key NOT IN (SELECT page_key FROM document_page)")
        removed.pages += db.changesCount
    }

    /// Gives the space of removed rows back to the disk. VACUUM holds the write lock while it
    /// rebuilds the database, which would make a runner's writes and heartbeats fail, so it
    /// runs only while no runner is alive: false means it did not run. VACUUM writes
    /// the rebuilt database through the write-ahead log, so the log is emptied again after it.
    public func compact() -> Bool {
        let busy = (try? runners().alive.isEmpty == false) ?? true
        guard !busy else { return false }
        do {
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "VACUUM")
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            return true
        } catch {
            return false
        }
    }

    /// The bytes the cache's database takes on disk, its write-ahead log included.
    public var size: Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: pool.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
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

    /// How long a lock's heartbeat may be silent before the lock is judged left over even though
    /// its process exists: a runner that was stopped (SIGSTOP) or a pid that another process
    /// took after a reboot. Minutes, not seconds, so a stopped runner is not cleaned from under it.
    static let leftoverAfter: TimeInterval = 600

    /// Whether a lock still belongs to a runner: its process exists and its heartbeat is not minutes old.
    static func isHeld(pid: Int32, heartbeat: Double) -> Bool {
        guard Date().timeIntervalSince1970 - heartbeat < leftoverAfter else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func isAlive(pid: Int32, heartbeat: Double) -> Bool {
        guard Date().timeIntervalSince1970 - heartbeat < heartbeatTimeout else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: Doctor

extension Store {
    /// A live runner, as the cache's locks name it.
    public struct LiveRunner: Equatable, Sendable {
        public var pid: Int32
        /// What it holds the lock of: `path:<file>` or `doc:<id>`.
        public var lock: String
    }

    /// What the cache holds, counted.
    public struct Counts: Equatable, Sendable {
        public var files = 0
        public var documents = 0
        public var pages = 0
        /// Pages parsed by an older parser, which a cleanup removes.
        public var oldPages = 0
    }

    public func counts() throws -> Counts {
        try pool.read { db in
            func one(_ sql: String, _ arguments: StatementArguments = []) throws -> Int {
                try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
            }
            return Counts(
                files: try one("SELECT COUNT(*) FROM file_entry"), documents: try one("SELECT COUNT(*) FROM document"),
                pages: try one("SELECT COUNT(*) FROM page_result"),
                oldPages: try one(
                    "SELECT COUNT(*) FROM page_result WHERE parser_version <> ?",
                    [Env.parserVersion]))
        }
    }

    /// Runners that hold a lock now, and the locks of runners that are gone.
    public func runners() throws -> (alive: [LiveRunner], leftover: [String]) {
        try pool.read { db in
            var alive: [LiveRunner] = []
            var leftover: [String] = []
            for row in try Row.fetchAll(db, sql: "SELECT lock_key, pid, heartbeat_at FROM runner_lock ORDER BY lock_key") {
                if Store.isHeld(pid: row["pid"], heartbeat: row["heartbeat_at"]) {
                    alive.append(LiveRunner(pid: row["pid"], lock: row["lock_key"]))
                } else {
                    leftover.append(row["lock_key"])
                }
            }
            return (alive, leftover)
        }
    }

    /// The bytes that compacting would give back from space earlier removals left: the database's
    /// free pages. Rows a cleanup removes now come on top of it.
    public func freePageBytes() throws -> Int64 {
        try pool.read { db in
            let free = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            return free * size
        }
    }

    /// The file entries `collectGarbage` would delete: files gone, or changed since indexed.
    func staleFiles() throws -> [(path: String, stat: FileStat)] {
        let entries = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT path, size, modified_ns, inode, device FROM file_entry")
        }
        return entries.compactMap { row in
            let path: String = row["path"]
            let cached = FileStat(
                size: row["size"], modifiedNanos: row["modified_ns"], inode: row["inode"],
                device: row["device"])
            if let now = FileStat(path: path) { return now == cached ? nil : (path, cached) }
            return FileStat.isGone(path: path) ? (path, cached) : nil
        }
    }

    /// What `collectGarbage` would remove, counted with SELECTs that mirror its deletes, so a dry
    /// run takes no write lock and writes nothing.
    public func wouldCollectGarbage() throws -> Removed {
        let stale = Set(try staleFiles().map(\.path))
        return try pool.read { db in
            var removed = Removed()
            let paths = Array(stale)
            let marks = paths.isEmpty ? "''" : Array(repeating: "?", count: paths.count).joined(separator: ",")
            let arguments = StatementArguments(paths)
            let kept = "SELECT doc_id FROM file_entry WHERE doc_id IS NOT NULL AND path NOT IN (\(marks))"
            removed.files = paths.count
            removed.documents =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM document WHERE id NOT IN (\(kept))",
                    arguments: arguments) ?? 0
            // A page goes when its parser is old, or when no document that stays holds it.
            removed.pages =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM page_result WHERE parser_version <> ? OR page_key NOT IN (
                            SELECT page_key FROM document_page WHERE doc_id IN (\(kept)) AND doc_id IN (SELECT id FROM document))
                        """, arguments: StatementArguments([Env.parserVersion] + paths)) ?? 0
            return removed
        }
    }
}
