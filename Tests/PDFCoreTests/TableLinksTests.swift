import Foundation
import Testing

@testable import PDFCore

/// Tables that run over page breaks (plan/ROADMAP.md → M3.2): which table regions on neighbouring
/// pages are linked, and which are not.
@Suite struct TableLinksTests {
    /// A page with one table region: its caption block, then its cells.
    func page(caption: String, box: Box, number: String = "1", hidden: [Hidden]? = nil, regions: [Region]? = nil) -> PageText {
        let captionBox = Box(x: box.x, y: box.y, width: box.width, height: 0.015)
        var layer = PageText(
            blocks: [
                TextBlock(text: caption, box: captionBox, lines: [TextLine(text: caption, box: captionBox)], hidden: hidden),
                TextBlock(text: "Row 1 0.1 4.5", box: box, lines: []),
            ], words: 0, runTogether: 0)
        layer.regions = regions ?? [Region(kind: .table, number: number, box: box, caption: [0], blocks: [1])]
        return layer
    }

    let bottomPart = Box(x: 0.12, y: 0.40, width: 0.76, height: 0.50)
    let topPart = Box(x: 0.12, y: 0.08, width: 0.76, height: 0.80)

    func link(_ pages: [PageText], page index: Int = 0) -> TableLink? {
        TableLinks.link(of: 0, on: index, layer: { pages.indices.contains($0) ? pages[$0] : nil })
    }

    @Test func aContinuedCaptionOnTheSameColumnsLinksThreeParts() {
        let pages = [
            page(caption: "Table 1: Results", box: bottomPart),
            page(caption: "Table 1 (continued)", box: topPart),
            page(caption: "Table 1: Results (continued)", box: Box(x: 0.12, y: 0.08, width: 0.76, height: 0.3)),
        ]
        let first = link(pages)
        #expect(first?.pages == [1, 2, 3] && first?.continuesOn == 2 && first?.continuedFrom == nil && first?.part == 1)
        let last = link(pages, page: 2)
        #expect(last?.id == first?.id && last?.part == 3 && last?.continuedFrom == 2 && last?.continuesOn == nil)
    }

    @Test func theWordsThatSayItGoesOn() {
        for caption in [
            "Table 1 (continued)", "Table 1. Cont.", "TABLE 1 — Continued", "Table 1 (Continued from previous page)",
            "Tabelle 1 (Fortsetzung)", "Table 1 (suite)", "表 1（续）", "Table 1 continued",
        ] {
            #expect(TableLinks.saysContinued(caption), "\(caption)")
        }
        for caption in [
            "Table 1: Continued fractions of the data", "Table 1: Results", "Table 1: Contents of the file", "Table 1: Content.",
            "Table 1: Baseline (control vs. treatment)", "Table 1 (contrast between arms)", "Table 1 (continuous variables)",
            "Table 1 (context length)", "Table 1 [suite A]", "Table 1 (continental data)", "Table 1: Control",
            "Table 1: Results are continued in Table 2", "Table 1 (contingency table)",
        ] {
            #expect(!TableLinks.saysContinued(caption), "\(caption)")
        }
    }

    @Test func aShortCaptionRepeatedIsNoContinuationButALongOneIs() {
        let short = [page(caption: "Table 1: Results", box: bottomPart), page(caption: "Table 1: Results", box: topPart)]
        #expect(link(short) == nil)
        let long = [
            page(caption: "Table 1: Measured values by sample.", box: bottomPart),
            page(caption: "Table 1: Measured values by sample.", box: topPart),
        ]
        #expect(link(long)?.pages == [1, 2])
    }

    @Test func aTableThatEndsMidPageDoesNotLink() {
        let middle = Box(x: 0.12, y: 0.30, width: 0.76, height: 0.30)
        let pages = [page(caption: "Table 1: Results", box: middle), page(caption: "Table 1 (continued)", box: topPart)]
        #expect(link(pages) == nil)
        // Its caption says it goes on, but nothing is linked: one part, named open.
        #expect(link(pages, page: 1)?.parts == 1 && link(pages, page: 1)?.openBefore == true)
    }

    @Test func aContinuationThatStartsMidPageDoesNotLink() {
        let pages = [
            page(caption: "Table 1: Results", box: bottomPart),
            page(caption: "Table 1 (continued)", box: Box(x: 0.12, y: 0.5, width: 0.76, height: 0.3)),
        ]
        #expect(link(pages) == nil)
    }

    @Test func otherColumnsOrAnotherNumberDoNotLink() {
        let narrow = [
            page(caption: "Table 1: Results", box: bottomPart),
            page(caption: "Table 1 (continued)", box: Box(x: 0.12, y: 0.08, width: 0.5, height: 0.8)),
        ]
        #expect(link(narrow) == nil)
        let shifted = [
            page(caption: "Table 1: Results", box: bottomPart),
            page(caption: "Table 1 (continued)", box: Box(x: 0.25, y: 0.08, width: 0.76, height: 0.8)),
        ]
        #expect(link(shifted) == nil)
        let other = [page(caption: "Table 1: Results", box: bottomPart), page(caption: "Table 2 (continued)", box: topPart, number: "2")]
        #expect(link(other) == nil)
    }

    @Test func aFigureIsNoTable() {
        var figure = page(caption: "Figure 1: Results", box: bottomPart)
        figure.regions = [Region(kind: .figure, number: "1", box: bottomPart, caption: [0], blocks: [])]
        var next = page(caption: "Figure 1 (continued)", box: topPart)
        next.regions = [Region(kind: .figure, number: "1", box: topPart, caption: [0], blocks: [])]
        #expect(link([figure, next]) == nil)
    }

    @Test func aFigureBelowTheTableInItsColumnsStopsTheLink() {
        let figureBox = Box(x: 0.12, y: 0.60, width: 0.76, height: 0.35)
        let table = Box(x: 0.12, y: 0.30, width: 0.76, height: 0.46)
        var first = page(caption: "Table 1: Results", box: table)
        first.regions?.append(Region(kind: .figure, number: "2", box: figureBox, caption: [0], blocks: []))
        #expect(link([first, page(caption: "Table 1 (continued)", box: topPart)]) == nil)
    }

    @Test func twoCandidatesLinkNeither() {
        var second = page(caption: "Table 1 (continued)", box: Box(x: 0.12, y: 0.08, width: 0.3, height: 0.3))
        second.regions?.append(Region(kind: .table, number: "1", box: Box(x: 0.12, y: 0.08, width: 0.3, height: 0.5), caption: [0], blocks: [1]))
        #expect(link([page(caption: "Table 1: Results", box: Box(x: 0.12, y: 0.40, width: 0.3, height: 0.5)), second]) == nil)
    }

    @Test func textAReaderCannotSeeIsNoContinuation() {
        // "Table 1: Results" + hidden " (continued)": the word is in the block's text, under its marker.
        let text = "Table 1: Results (continued)"
        let hidden = [Hidden(offset: 16, length: 12, reason: .invisible)]
        let pages = [page(caption: "Table 1: Results", box: bottomPart), page(caption: text, box: topPart, hidden: hidden)]
        #expect(link(pages) == nil)
        #expect(link([page(caption: "Table 1: Results", box: bottomPart), page(caption: text, box: topPart)])?.pages == [1, 2])
    }

    @Test func aPageNotParsedLeavesTheTablesApart() {
        let first = page(caption: "Table 1: Results", box: bottomPart)
        #expect(TableLinks.link(of: 0, on: 0, layer: { $0 == 0 ? first : nil }) == nil)
    }

    @Test func openEndsAreNamed() {
        // A chain whose last part ends the page, and a lone part whose caption says it goes on.
        let pages = [page(caption: "Table 1: Results", box: bottomPart), page(caption: "Table 1 (continued)", box: topPart)]
        #expect(link(pages)?.openBefore == false && link(pages)?.openAfter == false)
        #expect(link(pages, page: 1)?.openAfter == true && link(pages, page: 1)?.openBefore == false)
        let lone = [page(caption: "Table 1: Results (continued)", box: Box(x: 0.12, y: 0.08, width: 0.76, height: 0.3))]
        let alone = link(lone)
        #expect(alone?.parts == 1 && alone?.openBefore == true && alone?.continuedFrom == nil)
        // A lone table that ends the page says nothing: it may well end there.
        #expect(link([page(caption: "Table 1: Results", box: bottomPart)]) == nil)
    }
}
