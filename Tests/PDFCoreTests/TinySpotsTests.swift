import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import PDFCore

/// Squeezed or tiny glyphs near visible prose (M2.25, found on pages 3, 8 and 10 of `sottigra.pdf`, a
/// MusiXTeX manual): the text layer's "too small to read" spots are the boxes of such glyphs, and an
/// OCR line of prose that one lies over must stay text. `testdata/hidden/tiny-near-prose.pdf` has two
/// prose lines with 1.5-point words drawn over them.
@Suite struct TinySpotsTests {
    static let fixture = repoRoot.appendingPathComponent("testdata/hidden/tiny-near-prose.pdf")

    /// The page read by OCR, as a reparse reads it, with the text layer's spots applied.
    static func read() async throws -> (read: PageText, spots: Int) {
        let document = try #require(PDFDocument(url: fixture))
        let page = try #require(document.page(at: 0))
        let spots = TextLayer.HiddenSpots()
        _ = TextLayer.read(page, visibility: Visibility(page: page), spots: spots)
        var read = try #require(await OCR.pageText(page, check: false))
        OCR.markHidden(&read, spots: spots.spots)
        return (read, spots.spots.count)
    }

    @Test func proseOverTinyGlyphsStaysTextAfterOCR() async throws {
        let (read, spots) = try await Self.read()
        #expect(spots >= 2, "the fixture's tiny words give spots")
        for words in ["The prose between", "A second prose line"] {
            let block = try #require(read.blocks.first { $0.text.contains(words) }, "\(read.blocks.map(\.text))")
            #expect(block.visibleText.contains(words), "\(words) is hidden: \(block.text) \(block.hidden ?? [])")
        }
    }

    @Test func anOCRLineThatIsNoProseStaysHiddenUnderATinySpot() {
        func spot(_ x: Double) -> [(box: Box, reason: HiddenReason)] { [(Box(x: x, y: 0.5, width: 0.01, height: 0.01), .tiny)] }
        func line(_ text: String) -> PageText {
            let box = Box(x: 0.1, y: 0.49, width: 0.5, height: 0.03)
            let block = TextBlock(text: text, box: box, lines: [TextLine(text: text, box: box)])
            return PageText(blocks: [block], words: text.split(separator: " ").count, runTogether: 0)
        }
        for text in ["В.... в....", "3 3ğ", "ˇ ˇ ˇ", "cresc."] {
            var read = line(text)
            OCR.markHidden(&read, spots: spot(0.3))
            #expect(read.blocks[0].visibleText.isEmpty, "\(text) should stay under the marker")
        }
        var prose = line("Pour noter un intervalle de seconde dans un accord")
        OCR.markHidden(&prose, spots: spot(0.3))
        #expect(prose.blocks[0].visibleText == "Pour noter un intervalle de seconde dans un accord")
        // Another reason keeps the whole line, as before: a word hidden among visible ones.
        var covered = line("Pour noter un intervalle de seconde dans un accord")
        OCR.markHidden(&covered, spots: [(Box(x: 0.3, y: 0.5, width: 0.01, height: 0.01), .covered)])
        #expect(covered.blocks[0].visibleText.isEmpty)
    }
}
