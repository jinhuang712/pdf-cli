import Foundation
import GRDB

/// What the agent read from a crop, kept so that later reads show it in place (FEATURES.md → F3,
/// ROADMAP.md → M2.13): an equation's LaTeX, or a table's Markdown. The tool rebuilds neither
/// itself, as rules cannot promise them right (DESIGNS.md → Decision: the agent reads figures,
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

    /// What it is written in: "LaTeX" for an equation, "Markdown" for a table.
    public static func language(of kind: Region.Kind) -> String { kind == .table ? "Markdown" : "LaTeX" }
}

/// Transcripts live beside the picks, in the agent's own folder (DESIGNS.md → Principles →
/// Failure): the cache can be deleted and rebuilt, and the agent's work stays. One is kept by the
/// page's key, so it holds while the page draws the same, in any file, and leaves a page that
/// changed.
public final class Transcripts: Sendable {
    /// At most this many Unicode scalars of one transcript, so that combining marks stacked on a
    /// letter count each: an equation's, and a table's, which holds more.
    public static func limit(_ kind: Region.Kind) -> Int { kind == .table ? 12_000 : 4_000 }
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

    /// The text as it is kept: its lines as written, with no character that could reorder, hide
    /// or break what the output shows (control and format characters, those a renderer ignores,
    /// blank braille, and line and paragraph separators, which become newlines), no blank lines at
    /// either end and no spaces at a line's end. An equation's LaTeX loses the `$$`, `$`, `\[ \]`
    /// or `\( \)` around the whole, and a table's Markdown the code fence around it, which the
    /// output does without. Nil when nothing is left.
    public static func cleaned(_ text: String, kind: Region.Kind = .equation) -> String? {
        let scalars = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar {
            case "\r", "\u{2028}", "\u{2029}", "\u{85}": return "\n"
            case "\t": return " "
            case "\n": return scalar
            case "\u{2800}": return nil
            default:
                let ignored = scalar.properties.isDefaultIgnorableCodePoint || CharacterSet.controlCharacters.contains(scalar)
                return ignored ? nil : scalar
            }
        }
        var lines = String(String.UnicodeScalarView(scalars)).split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop { $0 == " " }.reversed()) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if kind == .table, lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            lines = Array(lines.dropFirst().dropLast())
        }
        var kept = lines.joined(separator: "\n")
        if kind == .equation { kept = unwrapped(kept) }
        let left = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        // Signs alone, as "$$$$", hold nothing.
        return left.isEmpty || left.allSatisfy({ "$ ".contains($0) }) ? nil : kept
    }

    /// LaTeX without one pair of delimiters around the whole, when nothing inside closes them
    /// first: "$a$ and $b$" keeps its signs, and an escaped `\$` is no sign.
    static func unwrapped(_ latex: String) -> String {
        let text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        where text.count > open.count + close.count && text.hasPrefix(open) && text.hasSuffix(close) && !text.hasSuffix("\\" + close) {
            let inner = String(text.dropFirst(open.count).dropLast(close.count))
            let unescaped = inner.replacingOccurrences(of: "\\$", with: "")
            guard !unescaped.contains(close), !(open == "$" && unescaped.contains("$")) else { return latex }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return latex
    }

    public func save(_ transcript: Transcript) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO transcript (page_key, kind, number, text, made_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [transcript.pageKey, transcript.kind.rawValue, transcript.number, transcript.text,
                                 transcript.madeAt.timeIntervalSince1970])
        }
    }

    /// Removes one, its number matched without regard to case, as `pdf crop` matches it, and says
    /// whether there was one.
    public func remove(pageKey: String, kind: Region.Kind, number: String) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM transcript WHERE page_key = ? AND kind = ? AND number = ? COLLATE NOCASE",
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
