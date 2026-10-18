import Foundation
import GRDB

/// What the agent read from an equation's crop, kept so that later reads show it in place and
/// need no crop (FEATURES.md → F3, ROADMAP.md → M2.13): its LaTeX. The tool rebuilds no LaTeX
/// itself, as rules cannot promise it right (DESIGNS.md → Decision: the agent reads figures,
/// tables and equations from their crops, and its LaTeX is kept). It is the agent's reading, and
/// the output says so.
public struct Transcript: Equatable, Sendable {
    public var pageKey: String
    public var kind: Region.Kind
    /// The region's number, as `Region.normalized` gives it.
    public var number: String
    public var text: String
    public var madeAt: Date

    public init(pageKey: String, kind: Region.Kind, number: String, text: String, madeAt: Date) {
        self.pageKey = pageKey
        self.kind = kind
        self.number = Region.normalized(number)
        self.text = text
        self.madeAt = madeAt
    }

    /// The day it was made, as the output labels it: "2026-10-18".
    public var day: String { ISO8601DateFormatter.string(from: madeAt, timeZone: .current, formatOptions: [.withFullDate]) }
}

/// Transcripts live beside the picks, in the agent's own folder (DESIGNS.md → Principles →
/// Failure): the cache can be deleted and rebuilt, and the agent's work stays. One is kept by the
/// page's key, so it holds while the page draws the same, in any file, and leaves a page that
/// changed.
public final class Transcripts: Sendable {
    /// At most this many characters of one transcript.
    public static let limit = 4_000
    let queue: DatabaseQueue

    public init(directory: URL = Env.supportDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        queue = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path,
                                  configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transcript (
                    page_key TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    number TEXT NOT NULL,
                    text TEXT NOT NULL,
                    made_at REAL NOT NULL,
                    PRIMARY KEY (page_key, kind, number)
                )
                """)
        }
    }

    /// The text as it is kept: its lines as written, with no control characters, which could
    /// reorder or hide what the output shows, no blank lines at either end, and no `$$`, `$` or
    /// `\[ \]` around it, which the output adds. Nil when nothing is left.
    public static func cleaned(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        let scalars = lines.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        var kept = String(String.UnicodeScalarView(scalars))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop { $0 == " " }.reversed()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a pair around the whole: "$a$ and $b$" keeps its signs.
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("$", "$")]
        where kept.count > open.count + close.count && kept.hasPrefix(open) && kept.hasSuffix(close) {
            let inner = String(kept.dropFirst(open.count).dropLast(close.count))
            guard !inner.contains(close) else { break }
            kept = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return kept.isEmpty ? nil : kept
    }

    public func save(_ transcript: Transcript) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO transcript (page_key, kind, number, text, made_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [transcript.pageKey, transcript.kind.rawValue, transcript.number, transcript.text,
                                 transcript.madeAt.timeIntervalSince1970])
        }
    }

    /// Removes one, and says whether there was one.
    public func remove(pageKey: String, kind: Region.Kind, number: String) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM transcript WHERE page_key = ? AND kind = ? AND number = ?",
                           arguments: [pageKey, kind.rawValue, Region.normalized(number)])
            return db.changesCount > 0
        }
    }

    /// Every transcript on these pages, by page key.
    public func transcripts(keys: [String]) throws -> [String: [Transcript]] {
        guard !keys.isEmpty else { return [:] }
        return try queue.read { db in
            var found: [String: [Transcript]] = [:]
            for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT * FROM transcript WHERE page_key IN (\(marks))",
                                            arguments: StatementArguments(chunk)) {
                    guard let kind = Region.Kind(rawValue: row["kind"]) else { continue }
                    let transcript = Transcript(pageKey: row["page_key"], kind: kind, number: row["number"], text: row["text"],
                                                madeAt: Date(timeIntervalSince1970: row["made_at"]))
                    found[transcript.pageKey, default: []].append(transcript)
                }
            }
            return found
        }
    }
}
