import Foundation
import Testing

@testable import PDFCore

/// Running headers, footers, page numbers and publisher stamps (plan/ROADMAP.md → M2.5).
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

    /// The page's furniture, judged against the others, each with its index.
    func find(_ pages: [PageText], at index: Int) -> [Int: Furniture.Kind] {
        Furniture.find(pages[index], index: index, near: pages.indices.filter { $0 != index }.map { ($0, pages[$0]) })
    }

    @Test func aHeaderThatRepeatsNearbyIsSetAside() {
        let pages = (0..<3).map { number in
            page([
                ("Journal of Things, Vol. 4 \(number + 10)", top()), ("Body text of the page \(number).", body),
                ("\(number + 10)", bottom()),
            ])
        }
        #expect(find(pages, at: 1) == [0: .header, 2: .footer])
    }

    /// The body, a footnote at the bottom that differs on each page, and a heading at the top that
    /// does not repeat, stay.
    @Test func whatDoesNotRepeatStays() {
        let one = page([("1 Introduction", top()), ("Body.", body), ("^{1} A footnote of this page.", bottom(0.9))])
        let two = page([("2 Method", top()), ("Body.", body), ("^{2} Another footnote.", bottom(0.9))])
        #expect(find([one, two], at: 0).isEmpty)
    }

    /// A page number that agrees with the page's own: "12", "- 12 -", "Page 12 of 30", "xii".
    @Test func aPageNumberAloneIsAFooter() {
        for number in ["12", "- 12 -", "Page 12 of 30", "xii"] {
            #expect(Furniture.find(page([("Body.", body), (number, bottom())]), index: 11, near: []) == [1: .footer])
        }
        // An old TeX paper sets its number 87.6% down: as the page's lowest block, it counts.
        #expect(Furniture.find(page([("Body.", body), ("3", bottom(0.876))]), index: 2, near: []) == [1: .footer])
        // A journal numbers its pages on from its volume's: the numbers nearby agree.
        let journal = (0..<2).map { page([("Body.", body), ("\(11841 + $0)", bottom())]) }
        #expect(find(journal, at: 1) == [1: .footer])
    }

    /// No page number: a chart's tick label below the running header, a cover's year, words
    /// that read as roman numerals in capitals, and a number that agrees with no page.
    @Test func numbersAndWordsThatAreNoPageNumbersStay() {
        let tick = page([("Journal of Things and Their Uses", top()), ("400", top(0.08)), ("Body.", body)])
        #expect(Furniture.find(tick, index: 399, near: []) == [:])
        let cover = page([("Annual Report", body), ("2024", bottom())])
        #expect(Furniture.find(cover, index: 0, near: []).isEmpty)
        let words = page([("MIX", top()), ("Body.", body), ("Civil", bottom())])
        #expect(Furniture.find(words, index: 1008, near: []).isEmpty)
        #expect(Furniture.find(page([("Body.", body), ("6131", bottom())]), index: 4, near: []).isEmpty)
    }

    @Test func arXivsStampInTheMarginIsAPublisherStamp() {
        let stamp = Box(x: 0.03, y: 0.25, width: 0.03, height: 0.4)
        let found = Furniture.find(page([("arXiv:2609.23257v2 [cs.LG] 8 Oct 2026", stamp), ("Body.", body)]), index: 0, near: [])
        #expect(found == [0: .stamp])
        // A reference that runs on to the top of a page and starts so is text.
        let reference = page([("arXiv:2106.09685 [cs.CL] Low-rank adaptation of large language models.", top()), ("Body.", body)])
        #expect(Furniture.find(reference, index: 0, near: []).isEmpty)
    }

    /// OCR reads a scan's running header a new way on each page: nearly the same letters match.
    @Test func aMisreadHeaderStillMatches() {
        let one = page([("REPORT 1034-NATIONAL ADVISORY COMMITTEE FOR AERONAUTICS", top()), ("Body.", body)])
        let two = page([("24 REPORT 10&i-NATIONAL ADVISORY COMMITTEE FOR AElXONAUTICS", top()), ("Body.", body)])
        #expect(find([one, two], at: 1) == [0: .header])
    }

    /// A box's heading below the running header, on two pages a page apart, is no header: what
    /// repeats at the top is the page's outermost text there.
    @Test func aHeadingBelowTheRunningHeaderStays() {
        let one = page([("1 • What Are Data and Data Science?", top()), ("EXPLORING FURTHER", top(0.09)), ("Body.", body)])
        let two = page([("What Are Data and Data Science? 41", top()), ("EXPLORING FURTHER", top(0.09)), ("Body.", body)])
        #expect(find([one, two], at: 1) == [0: .header])
    }

    /// Labels that differ in a number are different labels, and a short one needs two pages to
    /// repeat on: "ENDNOTES" can head two pages of a report.
    @Test func differentNumbersAndShortHeadingsStay() {
        let tables = (1...3).map { page([("Table B-\($0).", top()), ("Body.", body)]) }
        #expect(find(tables, at: 1).isEmpty)
        let notes = (0..<2).map { _ in page([("ENDNOTES", top()), ("Body.", body)]) }
        #expect(find(notes, at: 1).isEmpty)
        #expect(find(notes + [notes[0]], at: 1) == [0: .header])
    }

    /// A block that holds text a reader cannot see stays in the text, with its marker: set aside,
    /// a page number with words planted after it hid them from the count of hidden text.
    @Test func aBlockWithHiddenTextStays() {
        var footer = TextBlock(text: "3 PLANTED words", box: bottom(), lines: [TextLine(text: "3 PLANTED words", box: bottom())])
        footer.hidden = [Hidden(offset: 2, length: 13, reason: .background)]
        let layer = PageText(blocks: [TextBlock(text: "Body.", box: body, lines: []), footer], words: 0, runTogether: 0)
        #expect(Furniture.find(layer, index: 2, near: []).isEmpty)
    }

    /// A page of a thousand blocks in its margins costs no more than a page of four.
    @Test func atMostFourCandidatesAnEdge() {
        let margins = (0..<1_000).map { index in
            (String(repeating: "x", count: 150) + "\(index)", Box(x: 0.02, y: 0.12 + Double(index) * 0.0007, width: 0.05, height: 0.0005))
        }
        #expect(Furniture.edges(page(margins + [("Body.", body)])).count <= 4)
        #expect(Furniture.within(Array("a".unicodeScalars), Array("b".unicodeScalars), limit: 1))
        #expect(!Furniture.within(Array("abcdefghij".unicodeScalars), Array("jihgfedcba".unicodeScalars), limit: 2))
    }

    /// `pdf read` sets them aside, counts them in its first line, and shows them with `--show headers`.
    @Test func readSetsThemAsideAndHeadersShowsThem() throws {
        let output = try outputPage(
            0, [("Journal of Things 12", top()), ("Body text.", body), ("12", bottom())], furniture: [0: .header, 2: .footer])
        let normal = Output.render(file: "paper.pdf", pageCount: 1, pages: [output]).text
        #expect(normal.contains("running headers and footers: 2 set aside (show: --show headers)"))
        #expect(!normal.contains("Journal of Things") && normal.contains("¶2 Body text."))
        let shown = Output.render(file: "paper.pdf", pageCount: 1, pages: [output], headers: true).text
        #expect(shown.contains("¶1 [header] Journal of Things 12") && shown.contains("¶3 [footer] 12"))
    }

    /// Each one counts where it stands: on a page of nothing else, above a section's end, and
    /// before a read the budget cuts. On the unit after it, all three lost the count.
    @Test func eachCountsWhereItStands() throws {
        let alone = try outputPage(0, [("Journal of Things 12", top()), ("12", bottom())], furniture: [0: .header, 1: .footer])
        #expect(Output.render(file: "paper.pdf", pageCount: 1, pages: [alone]).text.contains("running headers and footers: 2 set aside"))

        let first = try outputPage(0, [("Body of the first page.", body)])
        let second = try outputPage(1, [("Journal of Things 13", top()), ("2 Method", body)], furniture: [0: .header])
        var section = Output.Document(file: "paper.pdf", pageCount: 2)
        section.until = (page: 2, block: 2)
        _ = section.add(first)
        _ = section.add(second)
        #expect(section.report().text.contains("running headers and footers: 1 set aside"))

        let long = String(repeating: "Words of a long paragraph. ", count: 200)
        let cut = try outputPage(0, [("Journal of Things 12", top()), (long, body)], furniture: [0: .header])
        var budget = Output.Document(file: "paper.pdf", pageCount: 1, budget: 150)
        _ = budget.add(cut)
        #expect(budget.report().text.contains("running headers and footers: 1 set aside"))
    }

    func outputPage(_ index: Int, _ blocks: [(String, Box)], furniture: [Int: Furniture.Kind] = [:]) throws -> Output.Page {
        let layer = page(blocks)
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        let result = PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1, data: data)
        return Output.Page(index: index, result: result, key: "k\(index)", furniture: furniture)
    }
}

/// M2.22 review: what is no furniture although it repeats.
@Suite struct FurnitureNotesTests {
    func page(_ blocks: [(String, Box)]) -> PageText {
        PageText(
            blocks: blocks.map { text, box in TextBlock(text: text, box: box, lines: [TextLine(text: text, box: box)]) },
            words: 0, runTogether: 0)
    }

    /// A footnote starts with its raised marker; the same note on each page is not a footer.
    @Test func aFootnoteThatEachPageRepeatsIsNoFooter() {
        let foot = Box(x: 0.1, y: 0.94, width: 0.5, height: 0.012)
        let body = Box(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
        let pages = (0..<3).map { page([("Body.", body), ("^{2}Second note of page \($0 + 1), about the board.", foot)]) }
        let near = [(1, pages[1]), (2, pages[2])]
        #expect(Furniture.find(pages[0], index: 0, near: near).isEmpty)
        // The same text without the marker is a footer, as before.
        let plain = (0..<3).map { page([("Body.", body), ("Second note of page \($0 + 1), about the board.", foot)]) }
        #expect(Furniture.find(plain[0], index: 0, near: [(1, plain[1]), (2, plain[2])]) == [1: .footer])
    }

    /// An upright note in the side margin repeats a word on many pages: the text's. Text set
    /// sideways (taller than twice its width), as arXiv's stamp, is the margin's.
    @Test func onlySidewaysTextInTheSideMarginCounts() {
        let body = Box(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
        let upright = Box(x: 0.92, y: 0.5, width: 0.07, height: 0.01)
        let sideways = Box(x: 0.93, y: 0.2, width: 0.02, height: 0.5)
        let notes = (0..<3).map { _ in page([("Body.", body), ("scrlttr2", upright)]) }
        #expect(Furniture.find(notes[0], index: 0, near: [(1, notes[1]), (2, notes[2])]).isEmpty)
        let stamps = (0..<3).map { _ in page([("Body.", body), ("Preprint of the journal", sideways)]) }
        #expect(Furniture.find(stamps[0], index: 0, near: [(1, stamps[1]), (2, stamps[2])]) == [1: .stamp])
    }
}
