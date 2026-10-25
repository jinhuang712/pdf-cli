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
        #expect(found.moreAnnotations == 10 && found.moreOnPage == [0: 10] && found.whyOnPage == [0: FactReader.Cap.page])
        // The walk reads no words under links: the page that is read asks for them (M2.21b review, M1).
        #expect(byPage[2]?.allSatisfy { $0.words == nil } == true)
    }

    /// The file's cap is told from the page's: past 1,005 links in the file, page 2 keeps 5 of its 12
    /// and page 3 none, and each page names the cap that stopped it (review, L3).
    @Test func theFilesCapIsNamedAsTheFilesAndKeepsEachKind() throws {
        let url = Self.manyLinks
        let found = FactReader.read(try #require(CGPDFDocument(url as CFURL)), url: url, fileCap: 1_005)
        let byPage = Dictionary(grouping: found.annotations, by: \.page)
        #expect(byPage[0]?.count == 1_000 && byPage[1]?.count == 5 && byPage[2] == nil)
        #expect(found.whyOnPage == [0: FactReader.Cap.page, 1: FactReader.Cap.file, 2: FactReader.Cap.file])
        #expect(found.moreOnPage == [0: 10, 1: 7, 2: 12])
        // The comments of a file are no part of the links' count.
        let comments = repoRoot.appendingPathComponent("testdata/safety/carries-comments.pdf")
        let few = FactReader.read(try #require(CGPDFDocument(comments as CFURL)), url: comments, fileCap: 0)
        #expect(few.annotations.isEmpty && few.whyOnPage.values.allSatisfy { $0 == FactReader.Cap.file })
    }

    /// The bytes a page keeps are capped as well as their count, and the cap is named.
    @Test func aPageKeepsNoMoreThanItsBytes() throws {
        let url = Self.manyLinks
        let found = FactReader.read(try #require(CGPDFDocument(url as CFURL)), url: url, pageBytes: 20_000)
        let page = found.annotations.filter { $0.page == 0 }.count
        #expect(page > 50 && page < 200)
        #expect(found.whyOnPage[0] == FactReader.Cap.size && found.moreOnPage[0] == 1_010 - page)
    }

    /// Twenty pages that share one array of 300 references to a link and a comment of 900
    /// characters each list two annotations, not 6,000, and count the repeats (review, M3).
    @Test func pagesThatShareAnnotationsListThemOnce() throws {
        let url = repoRoot.appendingPathComponent("testdata/safety/carries-shared-annots.pdf")
        let found = FactReader.read(try #require(CGPDFDocument(url as CFURL)), url: url)
        #expect(found.annotations.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.comment, .link])
        #expect(found.moreAnnotations == 20 * 300 - 2)
        #expect(found.whyOnPage.values.allSatisfy { $0 == FactReader.Cap.repeated })
        let store = try makeStore()
        try store.saveIndex(path: "/s.pdf", stat: stat, pageKeys: (0..<20).map { "k\($0)" }, facts: found)
        let bytes = try store.pool.read { try Int.fetchOne($0, sql: "SELECT SUM(LENGTH(data)) FROM page_annotation") ?? 0 }
        #expect(bytes < 4_000, "the table holds \(bytes) bytes")
    }

    /// The words under a page's links wait in the row until a read fills them, once, and only for the
    /// version of the file that asked (review, M1/M2).
    @Test func linkWordsAreFilledOnceAndOnlyForTheirVersion() throws {
        let store = try makeStore()
        try store.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b", "c"], facts: try facts())
        var third = try #require(try store.annotations(path: "/m.pdf", stat: stat, pages: [2])[2])
        #expect(third.words == .pending && third.annotations.allSatisfy { $0.words == nil })
        let touched = FileStat(size: 100, modifiedNanos: 9, inode: 2, device: 3)
        try store.saveWords(path: "/m.pdf", stat: touched, page: 2, words: [0: "stale"])
        #expect(try store.annotations(path: "/m.pdf", stat: stat, pages: [2])[2]?.words == .pending)
        try store.saveWords(path: "/m.pdf", stat: stat, page: 2, words: [0: "Reference 1", 3: "Reference 4"])
        third = try #require(try store.annotations(path: "/m.pdf", stat: stat, pages: [2])[2])
        #expect(third.words == .read && third.annotations[0].words == "Reference 1" && third.annotations[3].words == "Reference 4")
        try store.saveWords(path: "/m.pdf", stat: stat, page: 2, words: [0: "again"])
        #expect(try store.annotations(path: "/m.pdf", stat: stat, pages: [2])[2]?.annotations[0].words == "Reference 1")
        try store.saveWords(path: "/m.pdf", stat: stat, page: 1, words: nil)
        #expect(try store.annotations(path: "/m.pdf", stat: stat, pages: [1])[1]?.words == .failed)
    }

    /// A cache of schema 8 opens, gains the table, and its files' entries wait to be indexed again
    /// without being lost (review, L7).
    @Test func aSchema8CacheMigrates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-mig-\(UUID())")
        let first = try Store(directory: directory)
        try first.saveIndex(path: "/m.pdf", stat: stat, pageKeys: ["a", "b"], facts: try facts())
        try first.write { db in
            try db.execute(sql: "DROP TABLE page_annotation")
            try db.execute(sql: "UPDATE file_entry SET checks = 10")
            try db.execute(sql: "PRAGMA user_version = 8")
        }
        #expect(throws: Store.OlderCache.self) { try Store(directory: directory, readOnly: true) }
        let store = try Store(directory: directory)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == Store.schemaVersion)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_annotation") } == 0)
        // The entry is the file's, from an older pdf: no cached entry, but known, and its pages stay.
        #expect(try store.entry(path: "/m.pdf", stat: stat) == nil && store.hasEntry(path: "/m.pdf", stat: stat))
        #expect(try store.pageKeys(docID: Store.documentID(pageKeys: ["a", "b"])) == ["a", "b"])
        // Its outline still reads for what does not change with the checks (review, L2).
        #expect(try store.facts(path: "/m.pdf", stat: stat) == nil)
        #expect(try store.facts(path: "/m.pdf", stat: stat, olderChecks: true) != nil)
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
        let page = Output.Page(index: 0, result: result, key: "k", moreAnnotations: 10, whyAnnotations: FactReader.Cap.page)
        let blocks = Output.pageBlocks(page, picks: [:], path: "m.pdf", raw: false)
        let texts = blocks.units.flatMap(\.blocks).compactMap(\.text)
        #expect(texts.contains("10 more annotations on this page, past 1.0k links and as many others, not shown"))
        let quiet = Output.pageBlocks(Output.Page(index: 0, result: result, key: "k"), picks: [:], path: "m.pdf", raw: false)
        #expect(!quiet.units.flatMap(\.blocks).compactMap(\.text).contains { $0.contains("more annotation") })
    }

    /// A link to a page of the file with no words under it is counted, not shown; a link to a web
    /// address stays for its address; the two counts share the page's one line (review, M2).
    @Test func aLinkToAPageWithoutWordsIsCountedNotShown() throws {
        let layer = PageText(
            blocks: [
                TextBlock(
                    text: "Words.", box: Box(x: 0.1, y: 0.1, width: 0.4, height: 0.02),
                    lines: [TextLine(text: "Words.", box: Box(x: 0.1, y: 0.1, width: 0.4, height: 0.02))])
            ],
            words: 1, runTogether: 0)
        let data = try #require(try String(bytes: JSONEncoder().encode(layer), encoding: .utf8))
        let result = PageResult(status: .ok, method: "pdfkit", text: "Words.", reason: "", parseMillis: 1, data: data)
        func link(_ target: String) -> FileFacts.Annotation {
            var found = FileFacts.Annotation(kind: .link, page: 0, box: Box(x: 0.7, y: 0.5, width: 0.1, height: 0.02))
            found.target = target
            return found
        }
        let page = Output.Page(index: 0, result: result, key: "k", annotations: [link("p.7"), link("p.8"), link("https://example.org/x")],
                               moreAnnotations: 2, whyAnnotations: FactReader.Cap.repeated)
        let texts = Output.pageBlocks(page, picks: [:], path: "m.pdf", raw: false).units.flatMap(\.blocks)
        #expect(texts.contains { $0.target == "https://example.org/x" })
        #expect(!texts.contains { $0.target == "p.7" || $0.target == "p.8" })
        #expect(texts.compactMap(\.text).contains(
            "2 more annotations on this page, repeats of an annotation listed already, not shown; 2 links to pages of the file with no words under them, not shown"))
    }
}
