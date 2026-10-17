import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import PDFCore

/// The order of a page's lines across its columns (ROADMAP.md → M2.5).
@Suite struct ReadingOrderTests {
    /// A line of a page 612 pt wide: in the left column, the right one, or across both.
    func left(_ y: CGFloat, width: CGFloat = 230) -> CGRect { CGRect(x: 72, y: y, width: width, height: 10) }
    func right(_ y: CGFloat, width: CGFloat = 230) -> CGRect { CGRect(x: 312, y: y, width: width, height: 10) }
    func across(_ y: CGFloat) -> CGRect { CGRect(x: 72, y: y, width: 470, height: 10) }

    func order(_ rects: [CGRect], _ texts: [String]? = nil) -> [Int] {
        ReadingOrder.order(rects, texts: texts ?? rects.map { _ in "words" }).order
    }

    /// PDFKit gave the lines of two columns in turn, line by line: each column goes together.
    @Test func linesOfTwoColumnsInTurnGoTogether() {
        let rects = [left(100), right(100), left(112), right(112), left(124), right(124)]
        #expect(order(rects) == [0, 2, 4, 1, 3, 5])
    }

    /// A page PDFKit read column by column keeps its order exactly.
    @Test func columnsReadInOrderStay() {
        let rects = [left(100), left(112), left(124), right(100), right(112), right(124)]
        #expect(order(rects) == [0, 1, 2, 3, 4, 5])
    }

    /// A caption across both columns parts two bands, each read column by column, and keeps its place.
    @Test func aFullWidthCaptionPartsTheBands() {
        let rects = [left(100), right(100), left(112), right(112), across(140), left(170), right(170), left(182), right(182)]
        let result = ReadingOrder.order(rects, texts: rects.map { _ in "words" })
        #expect(result.order == [0, 2, 1, 3, 4, 5, 7, 6, 8])
        // Each column, and the line after a band, starts a block: below the caption, the left
        // column's first line once joined the caption's block.
        #expect(result.breaks.isSuperset(of: [0, 1, 4, 5, 6]))
    }

    /// A caption's last line, a column wide and set at the caption's size right below it, stays
    /// with the caption: in the band below, a search for the caption's words missed it.
    @Test func aCaptionsLastLineStaysWithIt() {
        let rects = [
            left(100), right(100), left(112), right(112), across(140), CGRect(x: 72, y: 151, width: 230, height: 10),
            left(180), right(180), left(192), right(192),
        ]
        let result = ReadingOrder.order(rects, texts: rects.map { _ in "words" })
        #expect(result.order == [0, 2, 1, 3, 4, 5, 6, 8, 7, 9])
        #expect(!result.breaks.contains(5))
    }

    /// One column: nothing moves.
    @Test func oneColumnStays() {
        let rects = (0..<6).map { across(100 + 12 * CGFloat($0)) }
        #expect(order(rects) == Array(0..<6))
    }

    /// A table's cells, short lines on both sides, are no columns of running text.
    @Test func aTablesCellsStay() {
        let rects = [
            left(100, width: 60), right(100, width: 60), left(112, width: 60), right(112, width: 60),
            left(124, width: 60), right(124, width: 60),
        ]
        #expect(order(rects) == Array(0..<6))
    }

    /// Hebrew and Arabic columns read from the right.
    @Test func rightToLeftColumnsStartOnTheRight() {
        let rects = [right(100), left(100), right(112), left(112)]
        #expect(order(rects, rects.map { _ in "שלום עולם" }) == [0, 2, 1, 3])
    }

    /// A page number set in the gutter, below the columns, keeps its place.
    @Test func aPageNumberInTheGutterKeepsItsPlace() {
        let rects = [left(100), right(100), left(112), right(112), CGRect(x: 302, y: 740, width: 8, height: 10)]
        #expect(order(rects) == [0, 2, 1, 3, 4])
    }

    /// Authors side by side above the columns, parted from them by a blank, keep their place;
    /// split at the gutter, an author on the right came after the left column.
    @Test func authorsAboveTheColumnsKeepTheirPlace() {
        let authors = [
            CGRect(x: 100, y: 60, width: 80, height: 10), CGRect(x: 266, y: 60, width: 80, height: 10),
            CGRect(x: 430, y: 60, width: 80, height: 10),
        ]
        let rects = authors + [left(100), right(100), left(112), right(112)]
        #expect(order(rects) == [0, 1, 2, 3, 5, 4, 6])
    }

    /// arXiv's stamp set sideways in the margin neither widens the left column nor moves the
    /// columns ahead of the title above them: it joins the left column, by where it lies.
    @Test func aStampInTheMarginMovesNothingAhead() {
        let stamp = CGRect(x: 20, y: 200, width: 20, height: 300)
        let rects = [stamp, across(60), left(100), right(100), left(112), right(112)]
        #expect(order(rects) == [1, 0, 2, 4, 3, 5])
    }

    /// Below the figure on p.5 of the smoke set's arxiv-2608.24191.pdf, PDFKit gives the lines of
    /// both columns in turn; the left column's paragraph reads whole, apart from the caption.
    @Test func aRealPageOfColumnsInTurnReadsWhole() throws {
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2608.24191.pdf")
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 4))
        let layer = withExtendedLifetime(document) { TextLayer.read(page, visibility: Visibility(page: page)) }
        let paragraph = try #require(layer.blocks.first { $0.text.hasPrefix("proportion of instances") })
        #expect(paragraph.text.contains("under C1 versus C2. Missed-in-Urdu is the proportion of instances classified"))
        #expect(layer.blocks.first { $0.text.hasPrefix("Figure 1:") }?.text.contains("proportion") == false)
    }
}
