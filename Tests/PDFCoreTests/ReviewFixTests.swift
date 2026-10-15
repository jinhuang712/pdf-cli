import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

@Suite struct ReviewFixTests {
    @Test func aCompoundThePageSpellsWithAHyphenKeepsIt() {
        // "cooperate" is in macOS's word list, but this page writes "co-operate".
        let page = Dehyphenator(pageText: "We co-operate closely. Teams co-")
        #expect(!page.joins("teams co", "operate"))
        #expect(Dehyphenator(pageText: "").joins("teams co", "operate"))
    }

    @Test func aDashOnItsOwnAtALinesEndIsNotAHyphen() {
        let lines = [TextLayer.RawLine(text: "from 3 to -", rect: .zero, softBreak: false),
                     TextLayer.RawLine(text: "5 more", rect: .zero, softBreak: false)]
        #expect(TextLayer.join(lines, Dehyphenator(pageText: "")) == "from 3 to - 5 more")
    }

    @Test func aRepairedPageHasItsOwnKey() {
        #expect(PageKeys.repaired("abc") == "abc+spaces")
        #expect(PageKeys.repaired(PageKeys.missing) == PageKeys.missing)
        #expect(PageKeys.repaired("unreadable-1234-5") == "unreadable-1234-5")
    }

    @Test func aRotatedPageRendersUpright() throws {
        let document = try #require(PDFDocument(url: samplePaper))
        let page = try #require(document.page(at: 0))
        let upright = try #require(OCR.render(page, dpi: 72))
        page.rotation = 90
        let turned = try #require(OCR.render(page, dpi: 72))
        #expect(upright.height > upright.width)
        #expect(turned.width == upright.height && turned.height == upright.width)
    }

    @Test func theRepairWorksOnARotatedPage() async throws {
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2609.23257.pdf")
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 1))
        let upright = await SpaceRepair.breaks(page)?.spaces.count ?? 0
        page.rotation = 90
        let turned = await SpaceRepair.breaks(page)?.spaces.count ?? 0
        #expect(upright > 100)
        #expect(Double(turned) > 0.9 * Double(upright))
    }

    @Test func aFormDrawnManyTimesIsReadOnceAndCountedEachTime() throws {
        let source = try #require(CGPDFDocument(samplePaper as CFURL)?.page(at: 3))
        func makePage(draws: Int) throws -> CGPDFPage {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-forms-\(UUID()).pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            context.beginPage(mediaBox: &box)
            for _ in 0..<draws { context.drawPDFPage(source) }
            context.endPage()
            context.closePDF()
            return try #require(CGPDFDocument(url as CFURL)?.page(at: 1))
        }
        let once = FontCheck(page: try makePage(draws: 1))
        let many = FontCheck(page: try makePage(draws: 50))
        #expect(once.gaps > 100)
        #expect(many.gaps == 50 * once.gaps)
    }
}

@Suite struct MigrationTests {
    @Test func upgradingFromVersion4ReadsFilesAgainAndKeepsTheirPages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-migrate-\(UUID())")
        let path = folder.appendingPathComponent("a.pdf").path
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("%PDF-".utf8))
        let stat = try #require(FileStat(path: path))
        do {
            let store = try Store(directory: folder)
            try store.saveIndex(path: path, stat: stat, pageKeys: ["k"])
            try store.saveResult(key: "k", PageResult(status: .ok, method: "pdfkit", text: "t", reason: "", parseMillis: 1))
            // A version 4 cache has no record of the checks each entry ran.
            try store.write { db in
                try db.execute(sql: "ALTER TABLE file_entry DROP COLUMN checks")
                try db.execute(sql: "PRAGMA user_version = 4")
            }
        }
        let upgraded = try Store(directory: folder)
        #expect(try upgraded.entry(path: path, stat: stat) == nil)
        #expect(try upgraded.collectGarbage() == Store.Removed())
        #expect(try upgraded.results(keys: ["k"])["k"] != nil)
    }

    @Test func indexingAgainUpdatesTheVerdict() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-verdict-\(UUID())")
        let store = try Store(directory: folder)
        let stat = FileStat(size: 1, modifiedNanos: 2, inode: 3, device: 4)
        let id = try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k"], spacesAtRisk: false)
        try store.saveIndex(path: "/a.pdf", stat: stat, pageKeys: ["k"], spacesAtRisk: true)
        #expect(try store.spacesAtRisk(docID: id))
    }
}
