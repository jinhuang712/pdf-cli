import Foundation
import Testing
@testable import PDFCore

@Suite struct SearchTests {
    func makeStore() throws -> Store {
        try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())"))
    }

    /// A parsed page whose blocks are one line each.
    func result(_ texts: [String]) throws -> PageResult {
        let blocks = texts.enumerated().map { index, text in
            TextBlock(text: text, box: Box(x: 0.1, y: Double(index) / 10, width: 0.8, height: 0.05),
                      lines: [TextLine(text: text, box: Box(x: 0.1, y: Double(index) / 10, width: 0.8, height: 0.05))])
        }
        let layer = PageText(blocks: blocks, words: 0, runTogether: 0)
        return PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1,
                          data: String(decoding: try JSONEncoder().encode(layer), as: UTF8.self))
    }

    @Test func everyWordIsQuotedSoNoneReadsAsSyntax() {
        #expect(Search.query("dropout ablation") == "\"dropout\" AND \"ablation\"")
        #expect(Search.query("self-attention NEAR(x) OR", any: true) == "\"self\" OR \"attention\" OR \"NEAR\" OR \"x\" OR \"OR\"")
        #expect(Search.query("*** ---") == nil)
    }

    /// Chinese and Japanese write no spaces, so each character is indexed as a word, and a run
    /// of them in a query is a phrase.
    @Test func chineseIsFoundInsideALongerRun() throws {
        #expect(Search.query("深度学习 model") == "\"深 度 学 习\" AND \"model\"")
        let indexed = Search.indexable("基于深度学习的方法")
        #expect(Search.readable(indexed) == "基于深度学习的方法")
        // A thin space the text holds itself stays.
        #expect(Search.readable(Search.indexable("5\u{2009}mm of 水")) == "5\u{2009}mm of 水")
        let store = try makeStore()
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: ["k0"])
        try store.saveResult(key: "k0", result(["我们提出一种基于深度学习的方法。", "Unrelated text"]))
        let found = try store.search(Search.query("深度学习")!, docIDs: [id], limit: 10, offset: 0)
        #expect(found.total == 1)
        #expect(found.hits.first?.snippet == "我们提出一种基于**深度学习**的方法。")
    }

    /// Words are found in any form the stemmer joins, accents or not, and every page of each
    /// document that holds the block is a hit.
    @Test func aSavedPageIsFoundAndDeletingItsResultDropsItFromTheIndex() throws {
        let store = try makeStore()
        let stat = FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1)
        let id = try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k0", "k1"])
        try store.saveResult(key: "k0", result(["Introduction", "We study dropout in transformers."]))
        try store.saveResult(key: "k1", result(["Ablations of the dropout rate", "A café table"]))
        let found = try store.search(Search.query("dropouts")!, docIDs: [id], limit: 10, offset: 0)
        #expect(found.total == 2)
        #expect(Set(found.hits.map { "\($0.page).\($0.block)" }) == ["0.2", "1.1"])
        #expect(try store.search(Search.query("cafe")!, docIDs: [id], limit: 10, offset: 0).total == 1)
        #expect(try store.search(Search.query("dropout cafe")!, docIDs: [id], limit: 10, offset: 0).total == 0)
        // Another document is searched only when asked.
        #expect(try store.search(Search.query("dropout")!, docIDs: ["other"], limit: 10, offset: 0).total == 0)
        _ = try store.remove(paths: ["/a.pdf"])
        #expect(try store.search(Search.query("dropout")!, docIDs: [id], limit: 10, offset: 0).total == 0)
    }

    /// A page cached before the index existed joins it on the first search of its document.
    @Test func pagesCachedBeforeTheIndexJoinItOnASearch() throws {
        let store = try makeStore()
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1),
                                     pageKeys: ["k0"])
        try store.saveResult(key: "k0", result(["Old page about lattices"]))
        try store.write { db in
            try db.execute(sql: "DELETE FROM block_text")
            try db.execute(sql: "DELETE FROM search_block")
            try db.execute(sql: "DELETE FROM search_page")
        }
        #expect(try store.search(Search.query("lattices")!, docIDs: [id], limit: 10, offset: 0).total == 0)
        try store.indexForSearch(docIDs: [id])
        #expect(try store.search(Search.query("lattices")!, docIDs: [id], limit: 10, offset: 0).total == 1)
    }

    /// A pattern runs across blocks and pages, and each match names the block it starts in.
    @Test func aPatternCrossesBlocksAndPages() throws {
        let first = try #require(try result(["Results of the", "dataset"]).pageText)
        let second = try #require(try result(["distillation runs", "end"]).pageText)
        let pattern = try NSRegularExpression(pattern: #"dataset\s+distillation"#)
        let hits = Search.matches(pattern, docID: "d", pages: [(0, first), (1, second)])
        #expect(hits.count == 1)
        #expect(hits.first.map { "\($0.page).\($0.block)" } == "0.2")
        #expect(hits.first?.snippet.contains("**dataset distillation**") == true)
    }

    @Test func aHitFallsInTheSectionThatStartsLastBeforeIt() {
        let sections = [Section(title: "1 Intro", level: 1, page: 1, block: 2),
                        Section(title: "2 Method", level: 1, page: 2, block: 5),
                        Section(title: "2.1 Data", level: 2, page: 2, block: 5)]
        #expect(Info.section(at: 1, block: 1, in: sections) == nil)
        #expect(Info.section(at: 2, block: 4, in: sections)?.title == "1 Intro")
        #expect(Info.section(at: 2, block: 5, in: sections)?.title == "2.1 Data")
        #expect(Info.section(at: 9, block: 1, in: sections)?.title == "2.1 Data")
    }
}

/// Running headers in the search (M2.22), judged on the query against the pages parsed now.
@Suite struct SearchRunningHeadersTests {
    func page(_ number: Int, body: String) throws -> PageResult {
        func block(_ text: String, y: Double) -> TextBlock {
            let box = Box(x: 0.1, y: y, width: 0.5, height: 0.012)
            return TextBlock(text: text, box: box, lines: [TextLine(text: text, box: box)])
        }
        let layer = PageText(
            blocks: [block("Annual Ledger Report", y: 0.04), block(body, y: 0.4), block("Ledger confidential", y: 0.94)],
            words: 0, runTogether: 0)
        return PageResult(
            status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1,
            data: String(decoding: try JSONEncoder().encode(layer), as: UTF8.self))
    }

    func hits(_ store: Store, _ id: String, _ query: String) throws -> [SearchCandidate] {
        try store.indexForSearch(docIDs: [id])
        return try store.searchCandidates(Search.query(query)!, docIDs: [id])
    }

    /// With the pages around parsed, the header and footer are found, the body is not, and the
    /// words of the header in a body stay a hit.
    @Test func aRepeatedHeaderIsFoundAndTheSameWordsInABodyAreNot() throws {
        let store = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())"))
        let keys = (0..<5).map { "k\($0)" }
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: keys)
        for (number, key) in keys.enumerated() {
            try store.saveResult(key: key, page(number, body: number == 2 ? "The ledger shows every payment." : "Plain words \(number)."))
        }
        let all = try hits(store, id, "ledger")
        #expect(all.count == 11)
        let found = try Search.runningHeaders(among: all.map { ($0.docID, $0.page, $0.block) }, store: store)
        #expect(found.count == 10)
        #expect(found[Search.Place(docID: id, page: 2, block: 2)] == nil)
        #expect(found[Search.Place(docID: id, page: 2, block: 1)] == .header)
        #expect(found[Search.Place(docID: id, page: 4, block: 3)] == .footer)
    }

    /// Before the pages around are parsed, nothing repeats yet: the header shows as a hit rather
    /// than a real hit being dropped on a guess; a page with no parsed neighbour drops nothing.
    @Test func aHeaderIsNotGuessedBeforeItsNeighboursAreParsed() throws {
        let store = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())"))
        let keys = (0..<4).map { "k\($0)" }
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: keys)
        try store.saveResult(key: "k0", page(0, body: "Plain words."))
        try store.saveResult(key: "k1", page(1, body: "Plain words."))
        var all = try hits(store, id, "ledger")
        var found = try Search.runningHeaders(among: all.map { ($0.docID, $0.page, $0.block) }, store: store)
        #expect(all.count == 4)
        // Two parsed pages repeat them (15 letters or more count on one neighbour): found.
        #expect(found[Search.Place(docID: id, page: 0, block: 1)] == .header)
        #expect(found[Search.Place(docID: id, page: 1, block: 3)] == .footer)
        #expect(found.count == 4)
        // A page alone has no neighbour: nothing is dropped.
        let lone = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())"))
        let loneID = try lone.saveIndex(path: "/b.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: ["a", "b", "c"])
        try lone.saveResult(key: "a", page(0, body: "Plain words."))
        all = try hits(lone, loneID, "ledger")
        found = try Search.runningHeaders(among: all.map { ($0.docID, $0.page, $0.block) }, store: lone)
        #expect(all.count == 2 && found.isEmpty)
        for number in 1..<3 { try lone.saveResult(key: ["a", "b", "c"][number], page(number, body: "Plain words.")) }
        try lone.indexForSearch(docIDs: [loneID])
        all = try hits(lone, loneID, "ledger")
        found = try Search.runningHeaders(among: all.map { ($0.docID, $0.page, $0.block) }, store: lone)
        #expect(all.count == 6 && found.count == 6)
    }
}

extension SearchRunningHeadersTests {
    /// A heading at a page's top that no page repeats is a real hit, though it sits where a
    /// header would.
    @Test func aUniqueTextAtThePageEdgeIsNotLeftOut() throws {
        let store = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())"))
        let keys = (0..<4).map { "k\($0)" }
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: keys)
        for (number, key) in keys.enumerated() {
            let box = Box(x: 0.1, y: 0.04, width: 0.5, height: 0.012)
            let heading = number == 2 ? "Chapter on lattices" : "Chapter \(number) on other things"
            let layer = PageText(
                blocks: [TextBlock(text: heading, box: box, lines: [TextLine(text: heading, box: box)])], words: 0, runTogether: 0)
            try store.saveResult(
                key: key,
                PageResult(
                    status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1,
                    data: String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)))
        }
        try store.indexForSearch(docIDs: [id])
        let all = try store.searchCandidates(Search.query("lattices")!, docIDs: [id])
        #expect(all.count == 1)
        #expect(try Search.runningHeaders(among: all.map { ($0.docID, $0.page, $0.block) }, store: store).isEmpty)
    }
}

/// M2.26: a page's edge summary is stored beside the index, judges as the layers do, and goes
/// with the page's result when it is replaced.
extension SearchRunningHeadersTests {
    func store5() throws -> (Store, String, [String]) {
        let store = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())"))
        let keys = (0..<5).map { "k\($0)" }
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: keys)
        for (number, key) in keys.enumerated() { try store.saveResult(key: key, page(number, body: "Plain words \(number).")) }
        return (store, id, keys)
    }

    func judged(_ store: Store, _ id: String, _ keys: [String]) throws -> [Search.Place: Furniture.Kind] {
        let all = try hits(store, id, "ledger")
        return try Search.runningHeaders(among: all.map { ($0.docID, $0.page, $0.block) }, store: store)
    }

    /// The summaries judge exactly as the layers do.
    @Test func theSummariesJudgeAsTheLayersDo() throws {
        let (store, _, keys) = try store5()
        let summaries = try store.edgeSummaries(keys: keys)
        #expect(summaries.count == 5)
        let fromLayers = try Furniture.find(pages: Array(0..<5), keys: keys, store: store)
        #expect(!fromLayers.isEmpty)
        #expect(try Search.judge(pages: Array(0..<5), keys: keys, store: store) == fromLayers)
    }

    /// A page indexed before the summaries existed gets its summary made on the first search.
    @Test func aPageWithNoSummaryGetsItsSummaryMade() throws {
        let (store, id, keys) = try store5()
        let before = try judged(store, id, keys)
        try store.write { try $0.execute(sql: "DELETE FROM search_edge") }
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM search_edge") } == 0)
        #expect(try judged(store, id, keys) == before)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM search_edge") } == 5)
    }

    /// A reparse replaces the page's result and its summary: a header the page lost is no
    /// header any more, though the old summary held it.
    @Test func aReparseReplacesTheSummary() throws {
        let (store, id, keys) = try store5()
        #expect(try judged(store, id, keys)[Search.Place(docID: id, page: 2, block: 1)] == .header)
        let box = Box(x: 0.1, y: 0.4, width: 0.5, height: 0.012)
        let layer = PageText(
            blocks: [TextBlock(text: "Ledger notes", box: box, lines: [TextLine(text: "Ledger notes", box: box)])], words: 0, runTogether: 0)
        try store.replaceResults([
            keys[2]: PageResult(
                status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1,
                data: String(decoding: try JSONEncoder().encode(layer), as: UTF8.self))
        ])
        let found = try judged(store, id, keys)
        #expect(found[Search.Place(docID: id, page: 2, block: 1)] == nil)
        #expect(found[Search.Place(docID: id, page: 1, block: 1)] == .header)
        #expect(try store.edgeSummaries(keys: [keys[2]])[keys[2]]?.edges.isEmpty == true)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM search_edge") } == 5)
    }
}

/// M2.26's review: an old cache gets the table, the index is made once, a stale summary is made again.
extension SearchRunningHeadersTests {
    func count(_ store: Store, _ table: String) throws -> Int {
        try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") ?? -1 }
    }

    /// HIGH: a cache of schema 9 made before the table has none; opening it creates the table and
    /// its trigger, and a page saved after is summarised and found.
    @Test func aCacheMadeBeforeTheTableGetsTheTableWhenItOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-search-\(UUID())")
        let old = try Store(directory: directory)
        try old.write { db in
            try db.execute(sql: "DROP TRIGGER page_result_leaves_the_edges")
            try db.execute(sql: "DROP TABLE search_edge")
        }
        let store = try Store(directory: directory)
        #expect(try count(store, "search_edge") == 0)
        let keys = (0..<5).map { "k\($0)" }
        let id = try store.saveIndex(path: "/a.pdf", stat: FileStat(size: 1, modifiedNanos: 1, inode: 1, device: 1), pageKeys: keys)
        for (number, key) in keys.enumerated() { try store.saveResult(key: key, page(number, body: "Plain words \(number).")) }
        #expect(try count(store, "search_edge") == 5)
        let found = try judged(store, id, keys)
        #expect(found[Search.Place(docID: id, page: 2, block: 1)] == .header)
        try store.write { try $0.execute(sql: "DELETE FROM page_result WHERE page_key = 'k1'") }
        #expect(try count(store, "search_edge") == 4)
    }

    /// MEDIUM 1: indexing a page twice puts its blocks in the index once.
    @Test func aPageIsIndexedOnceWhateverTheOrder() throws {
        let (store, _, keys) = try store5()
        let blocks = try count(store, "search_block")
        #expect(blocks == 15)
        let result = try #require(try store.results(keys: [keys[0]])[keys[0]])
        try store.write { try Store.indexForSearch($0, key: keys[0], version: Env.parserVersion, result: result) }
        #expect(try count(store, "search_block") == blocks && count(store, "block_text") == blocks)
    }

    /// MEDIUM 2: a row of another version, or one that cannot be decoded, is made again and replaced.
    @Test func aStaleOrUndecodableSummaryIsMadeAgain() throws {
        let (store, id, keys) = try store5()
        let good = try store.edgeSummaries(keys: keys)
        for (key, data) in [
            (keys[1], "{\"label\":null,\"edges\":[]}"), (keys[2], "not json"),
            (keys[3], good[keys[3]]!.stored.replacingOccurrences(of: "\"v\":1", with: "\"v\":0")),
        ] {
            try store.write { try $0.execute(sql: "UPDATE search_edge SET data = ? WHERE page_key = ?", arguments: [data, key]) }
        }
        let again = try store.edgeSummaries(keys: keys)
        #expect(again == good)
        let rows = try store.pool.read { try String.fetchAll($0, sql: "SELECT data FROM search_edge WHERE page_key IN ('k1','k2','k3')") }
        #expect(rows.allSatisfy { Furniture.Summary(stored: $0) != nil })
        #expect(try judged(store, id, keys)[Search.Place(docID: id, page: 1, block: 1)] == .header)
    }
}
