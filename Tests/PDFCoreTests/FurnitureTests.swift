import Foundation
import Testing

@testable import PDFCore

/// Running headers, footers, page numbers and publisher stamps (ROADMAP.md → M2.5).
@Suite struct FurnitureTests {
    /// A page of one-line blocks, each at its box.
    func page(_ blocks: [(String, Box)]) -> PageText {
        PageText(
            blocks: blocks.map { text, box in TextBlock(text: text, box: box, lines: [TextLine(text: text, box: box)]) },
            words: 0, runTogether: 0)
    }

    func top(_ y: Double = 0.04) -> Box { Box(x: 0.1, y: y, width: 0.5, height: 0.012) }
    func bottom(_ y: Double = 0.94) -> Box { Box(x: 0.45, y: y, width: 0.1, height: 0.012) }
    let body = Box(x: 0.1, y: 0.3, width: 0.8, height: 0.4)

    @Test func aHeaderThatRepeatsNearbyIsSetAside() {
        let pages = (0..<3).map { number in
            page([
                ("Journal of Things, Vol. 4 \(number + 10)", top()), ("Body text of the page \(number).", body),
                ("\(number + 10)", bottom()),
            ])
        }
        let found = Furniture.find(pages[1], near: [pages[0], pages[2]])
        #expect(found == [0: .header, 2: .footer])
    }

    /// The body, a footnote at the bottom that differs on each page, and a heading at the top that
    /// does not repeat, stay.
    @Test func whatDoesNotRepeatStays() {
        let one = page([("1 Introduction", top()), ("Body.", body), ("^{1} A footnote of this page.", bottom(0.9))])
        let two = page([("2 Method", top()), ("Body.", body), ("^{2} Another footnote.", bottom(0.9))])
        #expect(Furniture.find(one, near: [two]).isEmpty)
    }

    /// A page number needs no neighbour: "12", "- 12 -", "Page 3 of 30", "xii".
    @Test func aPageNumberAloneIsAFooter() {
        for number in ["12", "- 12 -", "Page 3 of 30", "xii"] {
            #expect(Furniture.find(page([("Body.", body), (number, bottom())]), near: []) == [1: .footer])
        }
        // An old TeX paper sets its number 87.6% down: as the page's lowest block, it counts.
        #expect(Furniture.find(page([("Body.", body), ("3", bottom(0.876))]), near: []) == [1: .footer])
    }

    @Test func arXivsStampInTheMarginIsAPublisherStamp() {
        let stamp = Box(x: 0.03, y: 0.25, width: 0.03, height: 0.4)
        let found = Furniture.find(page([("arXiv:2609.23257v2 [cs.LG] 8 Oct 2026", stamp), ("Body.", body)]), near: [])
        #expect(found == [0: .stamp])
    }

    /// OCR reads a scan's running header a new way on each page: nearly the same letters match.
    @Test func aMisreadHeaderStillMatches() {
        let one = page([("REPORT 1034-NATIONAL ADVISORY COMMITTEE FOR AERONAUTICS", top()), ("Body.", body)])
        let two = page([("24 REPORT 10&i-NATIONAL ADVISORY COMMITTEE FOR AElXONAUTICS", top()), ("Body.", body)])
        #expect(Furniture.find(two, near: [one]) == [0: .header])
    }

    /// A box's heading below the running header, on two pages a page apart, is no header: what
    /// repeats at the top is the page's outermost text there.
    @Test func aHeadingBelowTheRunningHeaderStays() {
        let one = page([("1 • What Are Data?", top()), ("EXPLORING FURTHER", top(0.09)), ("Body.", body)])
        let two = page([("What Are Data? 41", top()), ("EXPLORING FURTHER", top(0.09)), ("Body.", body)])
        #expect(Furniture.find(two, near: [one]) == [0: .header])
    }

    /// `pdf read` sets them aside, counts them in its first line, and shows them with `--headers`.
    @Test func readSetsThemAsideAndHeadersShowsThem() throws {
        let layer = page([("Journal of Things 12", top()), ("Body text.", body), ("12", bottom())])
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        let result = PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1, data: data)
        let output = Output.Page(index: 0, result: result, key: "k", furniture: [0: .header, 2: .footer])
        let normal = Output.render(file: "paper.pdf", pageCount: 1, pages: [output]).text
        #expect(normal.contains("running headers and footers: 2 set aside (show: --headers)"))
        #expect(!normal.contains("Journal of Things") && normal.contains("¶2 Body text."))
        let shown = Output.render(file: "paper.pdf", pageCount: 1, pages: [output], headers: true).text
        #expect(shown.contains("¶1 [header] Journal of Things 12") && shown.contains("¶3 [footer] 12"))
    }
}
