import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

/// "Same file, same answer" (plan/ROADMAP.md → M2.25). Page 17 of `arxiv-2609.23257.pdf` read as
/// "Output (JSON)" in some fresh processes and "Output(JSON)" in others: the space repair took its
/// word breaks from Apple's document recognizer, whose text for one and the same image differed
/// between processes (the image's bytes were identical). Within one process it never differed, so
/// no in-process loop can show the flip; the test pins the repair to the engine that does not flip.
@Suite struct SameAnswerTests {
    static func page17() throws -> PDFPage {
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2609.23257.pdf")
        return try #require(PDFDocument(url: url)?.page(at: 16))
    }

    @Test func theRepairTakesItsBreaksFromTheTextRecognizer() async throws {
        let page = try Self.page17()
        let image = try #require(OCR.render(page, dpi: 200))
        let lines = try #require(OCR.textRecognizerLines(image))
        let expected = SpaceRepair.align(kit: page.string ?? "", ocr: lines.map(\.text).joined(separator: "\n"))
        let repaired = try #require(await SpaceRepair.breaks(page))
        #expect(repaired == expected, "the repair must not depend on the document recognizer, which flips between processes")
    }
}

/// PDFKit on macOS 27 puts U+FFFC in its text for the pictures of a tagged figure. The regions need
/// those characters to find their boxes (page 13 of `arxiv-2608.24191.pdf`: a table whose crop
/// shrank from 0.21 to 0.07 of the page when they were taken for spaces), so the layer keeps them
/// and only the output leaves out a block of nothing else (M2.25 review, H1).
@Suite struct PlaceholderTests {
    @Test func aTablePageKeepsItsRegionsAndReadsNoPlaceholder() throws {
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2608.24191.pdf")
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 12))
        let layer = withExtendedLifetime(document) { TextLayer.read(page, visibility: Visibility(page: page)) }
        let table = try #require(layer.regions?.first { $0.name == "table 5" })
        #expect(table.box.height > 0.15, "the crop of table 5 is \(table.box.height) of the page")
        let output = Output.render(
            file: "f.pdf", pageCount: 1,
            pages: [
                Output.Page(
                    index: 0,
                    result: PageResult(
                        status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1,
                        data: String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)), key: "k")
            ]
        ).text
        #expect(!output.contains("4.5106.69"), "table rows read as paragraphs")
        #expect(!output.contains("\u{FFFC}"))
    }
}
