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
