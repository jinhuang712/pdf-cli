import CoreGraphics
import Foundation
import Testing

@testable import PDFCore

/// M2.21b: a page's annotations live in a table of their own, so a file with more than 1,000
/// links shows all of them on their pages without every read decoding all of them.
@Suite struct PageAnnotationTests {
    /// 1,034 links in all: 1,010 on page 1 (10 past the cap of one page), 12 on each of pages 2 and 3.
    static let manyLinks = repoRoot.appendingPathComponent("testdata/safety/carries-many-links.pdf")

    func makeStore() throws -> Store {
        try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-annots-\(UUID())"))
    }

    let stat = FileStat(size: 100, modifiedNanos: 1, inode: 2, device: 3)

    func facts() throws -> FileFacts {
        FactReader.read(try #require(CGPDFDocument(Self.manyLinks as CFURL)), url: Self.manyLinks)
    }

    /// The walk keeps 1,000 links of a page and counts the rest by page; the pages after it keep theirs.
    @Test func theWalkCapsEachPageAndNotTheFile() throws {
        let found = try facts()
        let byPage = Dictionary(grouping: found.annotations, by: \.page)
        #expect(byPage[0]?.count == 1_000)
        #expect(byPage[1]?.count == 12 && byPage[2]?.count == 12)
        #expect(found.moreAnnotations == 10 && found.moreOnPage == [0: 10])
        // The words under a link on a page after the first thousand are read too.
        #expect(byPage[2]?.first { $0.target == "https://example.org/p3/5" }?.words == "Reference 5 of page 3")
    }

    /// The cache hands back each page's links, the facts hold none, and a page asked for is the
    /// only one decoded.
    @Test func theTableKeepsLinksPerPage() throws {
        let store = try makeStore()
        let found = try facts()
        try store.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: found)
        let kept = try #require(try store.facts(path: "/m.pdf", stat: stat))
        #expect(kept.annotations.isEmpty && kept.moreOnPage.isEmpty)
        #expect(kept.moreAnnotations == 10)
        let third = try store.annotations(path: "/m.pdf", stat: stat, pages: [2])
        #expect(Set(third.keys) == [2])
        #expect(third[2]?.annotations.count == 12 && third[2]?.more == 0)
        let first = try store.annotations(path: "/m.pdf", stat: stat, pages: [0, 1])
        #expect(first[0]?.annotations.count == 1_000 && first[0]?.more == 10 && first[1]?.annotations.count == 12)
        // A file changed since is another version: no rows.
        let touched = FileStat(size: 100, modifiedNanos: 9, inode: 2, device: 3)
        #expect(try store.annotations(path: "/m.pdf", stat: touched, pages: [2]).isEmpty)
    }

    /// Indexing a file again replaces its rows; a file with no annotations leaves none; removing the
    /// file and a cleanup of a file that is gone remove them.
    @Test func rowsFollowTheirFileEntry() throws {
        let store = try makeStore()
        func rows() throws -> Int { try store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_annotation") ?? 0 } }
        try store.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: try facts())
        #expect(try rows() == 3)
        try store.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: FileFacts())
        #expect(try rows() == 0)
        try store.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: try facts())
        try store.saveFailure(path: "/m.pdf", stat: stat, reason: "damaged")
        #expect(try rows() == 0)
        try store.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: try facts())
        try store.saveIndex(path: "/n.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: try facts())
        #expect(try rows() == 6)
        _ = try store.remove(paths: ["/m.pdf"])
        #expect(try rows() == 3)
        try store.forgetEntry(path: "/n.pdf")
        #expect(try rows() == 0)
        // /gone.pdf does not exist, so a cleanup drops its entry and its rows.
        try store.saveIndex(path: "/gone-\(UUID()).pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: try facts())
        #expect(try rows() == 3)
        _ = try store.collectGarbage()
        #expect(try rows() == 0)
    }

    /// A page past its cap says so, on its own line, numbered after its last block.
    @Test func aPageSaysWhenItsCapIsHit() throws {
        let layer = PageText(
            blocks: [
                TextBlock(
                    text: "Words.", box: Box(x: 0.1, y: 0.1, width: 0.4, height: 0.02),
                    lines: [TextLine(text: "Words.", box: Box(x: 0.1, y: 0.1, width: 0.4, height: 0.02))])
            ],
            words: 1, runTogether: 0)
        let data = try String(bytes: JSONEncoder().encode(layer), encoding: .utf8)
        let result = PageResult(status: .ok, method: "pdfkit", text: "Words.", reason: "", parseMillis: 1, data: try #require(data))
        let page = Output.Page(index: 0, result: result, key: "k", moreAnnotations: 10)
        let blocks = Output.pageBlocks(page, picks: [:], path: "m.pdf", raw: false)
        let texts = blocks.units.flatMap(\.blocks).compactMap(\.text)
        #expect(texts.contains("10 more annotations on this page, past 1.0k links and as many others, not shown"))
        let quiet = Output.pageBlocks(Output.Page(index: 0, result: result, key: "k"), picks: [:], path: "m.pdf", raw: false)
        #expect(!quiet.units.flatMap(\.blocks).compactMap(\.text).contains { $0.contains("more annotation") })
    }
}
