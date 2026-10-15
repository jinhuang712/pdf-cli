import Foundation
import GRDB

/// One place a search found: a block of a page of a document.
public struct SearchHit: Equatable, Sendable {
    public var docID: String
    /// Counted from 0.
    public var page: Int
    /// Counted from 1.
    public var block: Int
    /// The words around the match, with the match in **bold**.
    public var snippet: String
    /// Lower is better: SQLite's BM25 for keywords, the match's place in the file for patterns.
    public var rank: Double

    public init(docID: String, page: Int, block: Int, snippet: String, rank: Double) {
        self.docID = docID
        self.page = page
        self.block = block
        self.snippet = snippet
        self.rank = rank
    }
}

/// Keyword search over the cached pages (FEATURES.md → F4), with SQLite's FTS5 index of every
/// block's text (DESIGNS.md → Decision: SQLite over qmd and Tantivy).
public enum Search {
    /// Marks the split the index puts around each character of a script written without
    /// spaces, as Chinese is, so a snippet can take it out again.
    static let split: Character = "\u{2009}"

    /// Whether a character is one the index splits apart: Chinese and Japanese characters, which
    /// their scripts write without spaces, and Korean syllables, which the tokenizer would
    /// otherwise read as one word with whatever follows them.
    static func unspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return true
        default: return scalar.properties.isIdeographic
        }
    }

    /// Text as the index stores it: each character of a script written without spaces is a
    /// word of its own, so a query of two characters finds them inside a longer run.
    public static func indexable(_ text: String) -> String {
        guard text.contains(where: unspaced) else { return text }
        var out = ""
        for character in text {
            if unspaced(character) {
                out.append(split)
                out.append(character)
                out.append(split)
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// A snippet as a reader sees it, with the index's splits taken out: a thin space beside a
    /// split character, with the snippet's `**` marks looked past. A thin space the text holds
    /// itself, as in "5 mm", stays.
    public static func readable(_ text: String) -> String {
        guard text.contains(split) else { return text }
        let characters = Array(text)
        func neighbour(_ index: Int, step: Int) -> Character? {
            var position = index + step
            while characters.indices.contains(position), characters[position] == split || characters[position] == "*" {
                position += step
            }
            return characters.indices.contains(position) ? characters[position] : nil
        }
        var out = ""
        for (index, character) in characters.enumerated() {
            if character == split, [neighbour(index, step: -1), neighbour(index, step: 1)].contains(where: { $0.map(unspaced) ?? false }) {
                continue
            }
            out.append(character)
        }
        return out
    }

    /// An FTS5 query for the words of `text`: each word quoted, so no character is read as
    /// FTS5 syntax, and a run of Chinese or Japanese characters kept as one phrase. With `any`,
    /// one word is enough; otherwise every word must be in the block. Nil for a text with no
    /// word in it.
    public static func query(_ text: String, any: Bool = false) -> String? {
        var terms: [String] = []
        var word = ""
        var phrase: [Character] = []
        func flush() {
            if !word.isEmpty { terms.append("\"\(word)\"") }
            if !phrase.isEmpty { terms.append("\"" + phrase.map(String.init).joined(separator: " ") + "\"") }
            word = ""
            phrase = []
        }
        for character in text {
            if unspaced(character) {
                if !word.isEmpty { flush() }
                phrase.append(character)
            } else if character.isLetter || character.isNumber {
                if !phrase.isEmpty { flush() }
                word.append(character)
            } else {
                flush()
            }
        }
        flush()
        return terms.isEmpty ? nil : terms.joined(separator: any ? " OR " : " AND ")
    }

    // MARK: Patterns

    /// Every match of a regular expression in the pages' text, in the order of the file. The
    /// text runs from block to block and page to page with a line break between, so a match can
    /// cross a line, a column or a page. At most `limit` matches are kept.
    public static let maxMatches = 10_000

    public static func matches(_ pattern: NSRegularExpression, docID: String, pages: [(index: Int, layer: PageText)],
                               limit: Int = maxMatches) -> [SearchHit] {
        var text = ""
        var starts: [(offset: Int, page: Int, block: Int)] = []
        var length = 0
        for (index, layer) in pages {
            for (number, block) in layer.blocks.enumerated() {
                starts.append((length, index, number + 1))
                text += block.text + "\n"
                length += block.text.utf16.count + 1
            }
        }
        let whole = text as NSString
        var hits: [SearchHit] = []
        pattern.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: whole.length)) { match, _, stop in
            guard let range = match?.range, range.length > 0 else { return }
            // The block the match starts in: the last whose start is at or before it.
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle].offset <= range.location { low = middle } else { high = middle - 1 }
            }
            let place = starts[low]
            // The context widens to whole characters, so no emoji or accent is cut in half.
            let context = whole.rangeOfComposedCharacterSequences(for: NSRange(
                location: max(0, range.location - 60),
                length: min(whole.length, range.location + range.length + 60) - max(0, range.location - 60)))
            let before = min(context.location, range.location)
            let after = max(context.location + context.length, range.location + range.length)
            func flat(_ part: String) -> String { part.replacingOccurrences(of: "\n", with: " ") }
            let snippet = (before > 0 ? "…" : "") + flat(whole.substring(with: NSRange(location: before, length: range.location - before)))
                + "**" + flat(whole.substring(with: range)) + "**"
                + flat(whole.substring(with: NSRange(location: range.location + range.length,
                                                     length: after - range.location - range.length)))
                + (after < whole.length ? "…" : "")
            hits.append(SearchHit(docID: docID, page: place.page, block: place.block, snippet: snippet,
                                  rank: Double(hits.count)))
            if hits.count >= limit { stop.pointee = true }
        }
        return hits
    }
}

// MARK: The index

extension Store {
    /// Version 7: the keyword index. `search_block` names each indexed block, and its id is the
    /// row of the block's text in `block_text`. `search_page` marks the pages indexed, an empty
    /// one included. Deleting a page's result deletes its rows from the index.
    static func createSearchIndex(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS search_block (
                id INTEGER PRIMARY KEY,
                page_key TEXT NOT NULL,
                parser_version INTEGER NOT NULL,
                block INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS search_block_by_key ON search_block (page_key, parser_version);
            CREATE TABLE IF NOT EXISTS search_page (
                page_key TEXT NOT NULL,
                parser_version INTEGER NOT NULL,
                PRIMARY KEY (page_key, parser_version)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS block_text USING fts5(text, tokenize = 'porter unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS page_result_leaves_the_index AFTER DELETE ON page_result BEGIN
                DELETE FROM block_text WHERE rowid IN
                    (SELECT id FROM search_block WHERE page_key = old.page_key AND parser_version = old.parser_version);
                DELETE FROM search_block WHERE page_key = old.page_key AND parser_version = old.parser_version;
                DELETE FROM search_page WHERE page_key = old.page_key AND parser_version = old.parser_version;
            END;
            """)
    }

    /// Adds a page's blocks to the keyword index, once.
    static func indexForSearch(_ db: Database, key: String, version: Int, result: PageResult) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO search_page (page_key, parser_version) VALUES (?, ?)",
                       arguments: [key, version])
        guard db.changesCount > 0, let layer = result.pageText else { return }
        for (index, block) in layer.blocks.enumerated() {
            try db.execute(sql: "INSERT INTO search_block (page_key, parser_version, block) VALUES (?, ?, ?)",
                           arguments: [key, version, index + 1])
            try db.execute(sql: "INSERT INTO block_text (rowid, text) VALUES (?, ?)",
                           arguments: [db.lastInsertedRowID, Search.indexable(block.text)])
        }
    }

    /// Indexes the cached pages of these documents that the index does not hold yet, as pages
    /// cached before the index existed.
    public func indexForSearch(docIDs: [String]) throws {
        guard !docIDs.isEmpty else { return }
        let marks = Array(repeating: "?", count: docIDs.count).joined(separator: ",")
        let missing = try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT r.page_key FROM document_page d
                JOIN page_result r ON r.page_key = d.page_key AND r.parser_version = ?
                LEFT JOIN search_page s ON s.page_key = r.page_key AND s.parser_version = r.parser_version
                WHERE d.doc_id IN (\(marks)) AND s.page_key IS NULL
                """, arguments: StatementArguments([Env.parserVersion] + docIDs)!)
        }
        // A few hundred pages at a time, so no transaction holds the write lock long enough to
        // stall a runner, and each page is indexed only if its result is still cached: a
        // cleanup between the read above and the write would leave rows with no page behind them.
        for start in stride(from: 0, to: missing.count, by: 200) {
            let results = try results(keys: Array(missing[start..<min(start + 200, missing.count)]))
            try write { db in
                for (key, result) in results {
                    guard try Bool.fetchOne(db, sql: "SELECT 1 FROM page_result WHERE page_key = ? AND parser_version = ?",
                                            arguments: [key, Env.parserVersion]) ?? false else { continue }
                    try Store.indexForSearch(db, key: key, version: Env.parserVersion, result: result)
                }
            }
        }
    }

    /// The blocks of these documents that match an FTS5 query, best first, and how many match
    /// in all. A page that two documents share, or that a document holds twice, is a hit in each.
    public func search(_ match: String, docIDs: [String], limit: Int, offset: Int) throws -> (hits: [SearchHit], total: Int) {
        guard !docIDs.isEmpty else { return ([], 0) }
        let marks = Array(repeating: "?", count: docIDs.count).joined(separator: ",")
        let from = """
            FROM block_text
            JOIN search_block b ON b.id = block_text.rowid
            JOIN document_page d ON d.page_key = b.page_key
            WHERE block_text MATCH ? AND b.parser_version = ? AND d.doc_id IN (\(marks))
            """
        let arguments: [DatabaseValueConvertible] = [match, Env.parserVersion] + docIDs
        return try pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) " + from, arguments: StatementArguments(arguments)!) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.doc_id, d.page_index, b.block, snippet(block_text, 0, '**', '**', '…', 16) AS snippet,
                       bm25(block_text) AS rank
                \(from)
                ORDER BY rank, d.doc_id, d.page_index, b.block
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments + [limit, offset])!)
            let hits = rows.map { row in
                SearchHit(docID: row["doc_id"], page: row["page_index"], block: row["block"],
                          snippet: Search.readable(row["snippet"]), rank: row["rank"])
            }
            return (hits, total)
        }
    }
}
