import Foundation
import GRDB

/// A PDF in the library: a file the agent added or read.
public struct LibraryEntry: Equatable, Sendable {
    public var path: String
    public var docID: String
    /// The title the file's metadata names, or empty.
    public var title: String
    public var pageCount: Int
    public var addedAt: Date

    public init(path: String, docID: String, title: String, pageCount: Int, addedAt: Date) {
        self.path = path
        self.docID = docID
        self.title = title
        self.pageCount = pageCount
        self.addedAt = addedAt
    }

    /// The ID commands show and accept: the start of the document's ID.
    public var shortID: String { String(docID.prefix(8)) }

    /// The title to show: the file's own, or its name when it names none.
    public var displayTitle: String {
        title.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : title
    }
}

/// The library list, in the agent's own folder beside the picks (DESIGNS.md → Decision:
/// macOS's Library folders, with no size limit). A cleared cache leaves the list, and the next
/// read parses each file again.
public final class Library: Sendable {
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
                CREATE TABLE IF NOT EXISTS library_entry (
                    path TEXT PRIMARY KEY,
                    doc_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    page_count INTEGER NOT NULL,
                    added_at REAL NOT NULL
                )
                """)
        }
    }

    /// Adds a file, or points it at its new document after the file changed. A file already
    /// listed as it is costs one read and no write, so a cached read stays fast.
    public func register(path: String, docID: String, title: String, pageCount: Int) throws {
        let listed = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT doc_id, title FROM library_entry WHERE path = ?", arguments: [path])
        }
        if let listed, listed["doc_id"] as String == docID, listed["title"] as String == title { return }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO library_entry (path, doc_id, title, page_count, added_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (path) DO UPDATE SET doc_id = excluded.doc_id, title = excluded.title,
                    page_count = excluded.page_count
                """, arguments: [path, docID, title, pageCount, Date().timeIntervalSince1970])
        }
    }

    /// Whether the agent's folder holds its database yet: a dry run opens it only then.
    public static func exists(directory: URL = Env.supportDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.sqlite").path)
    }

    /// Every entry, by path.
    public func entries() throws -> [LibraryEntry] {
        try queue.read { db in
            guard try db.tableExists("library_entry") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT * FROM library_entry ORDER BY path").map { row in
                LibraryEntry(path: row["path"], docID: row["doc_id"], title: row["title"], pageCount: row["page_count"],
                             addedAt: Date(timeIntervalSince1970: row["added_at"]))
            }
        }
    }

    @discardableResult
    public func remove(paths: [String]) throws -> Int {
        try queue.write { db in
            var removed = 0
            for path in paths {
                try db.execute(sql: "DELETE FROM library_entry WHERE path = ?", arguments: [path])
                removed += db.changesCount
            }
            return removed
        }
    }
}
