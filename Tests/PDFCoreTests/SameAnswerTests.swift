import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

/// "Same file, same answer" (ROADMAP.md → M2.25). Page 17 of `arxiv-2609.23257.pdf` read as
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

    @Test func theParseOfThePageIsOneAnswerEveryTime() async throws {
        let page = try Self.page17()
        var texts = Set<String>()
        for _ in 0..<5 {
            let (layer, method) = await Worker.readTextLayer(page, atRisk: true)
            #expect(method == "pdfkit+ocr-spaces")
            texts.insert(layer.text)
        }
        #expect(texts.count == 1)
        #expect(texts.first?.contains("(JSON)") == true)
    }
}
