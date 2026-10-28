import CoreGraphics
import Foundation
import Testing

@testable import PDFCore

/// Lists of references, citations and cross-references (plan/ROADMAP.md → M2.8).
@Suite struct ReferencesTests {
    /// A one-block page element: its text, box and font size, in one line or more.
    struct Item {
        var text: String
        var box: Box
        var size: Double = 10
        var lines = 1
    }

    func block(_ item: Item) -> TextBlock {
        let height = item.box.height / Double(item.lines)
        let lines = (0..<item.lines).map { number in
            TextLine(
                text: item.text, box: Box(x: item.box.x, y: item.box.y + height * Double(number), width: item.box.width, height: height),
                size: item.size)
        }
        return TextBlock(text: item.text, box: item.box, lines: lines)
    }

    /// A page as the parse leaves it, its notes found.
    func page(_ items: [Item], regions: [Region] = []) -> PageText {
        var layer = PageText(blocks: items.map(block), words: 0, runTogether: 0)
        layer.regions = regions.isEmpty ? nil : regions
        let found = Notes.find(layer.blocks, regions: regions)
        if !found.notes.isEmpty { layer.notes = found.notes }
        if found.heading { layer.noteHeading = true }
        return layer
    }

    func notes(_ layers: [PageText]) -> [Int: PageNotes] {
        let digests = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.offset, Notes.digest($0.element, index: $0.offset)) })
        return Notes.resolve(pages: Array(layers.indices), digests: digests)
    }

    func judge(_ layers: [PageText], outline: [FileFacts.Section] = []) -> References.Judged {
        let digests = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.offset, References.digest($0.element)) })
        return References.resolve(digests: digests, notes: notes(layers), outline: outline)
    }

    func outputPage(_ index: Int, _ layer: PageText, _ judged: References.Judged, notes: PageNotes = PageNotes()) throws -> Output.Page {
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        let result = PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1, data: data)
        return Output.Page(index: index, result: result, key: "k\(index)", notes: notes, citations: judged.pages[index] ?? PageCitations())
    }

    let sentence = "The committee argued that the proposal would change how the laboratory shares its data with others."
    func body(_ y: Double, _ text: String? = nil) -> Item {
        Item(text: text ?? sentence + " " + sentence, box: Box(x: 0.1, y: y, width: 0.8, height: 0.08), lines: 4)
    }
    func heading(_ text: String, _ y: Double = 0.1, size: Double = 12) -> Item {
        Item(text: text, box: Box(x: 0.1, y: y, width: 0.3, height: 0.02), size: size)
    }
    func entry(_ text: String, _ y: Double, x: Double = 0.1) -> Item {
        Item(text: text, box: Box(x: x, y: y, width: 0.8, height: 0.03), size: 9, lines: 2)
    }
    /// A page that holds a list of references under a heading, one entry a block.
    func list(_ entries: [String], heading title: String = "References") -> PageText {
        page([heading(title)] + entries.enumerated().map { entry($0.element, 0.15 + 0.05 * Double($0.offset)) })
    }

    // MARK: Lists and entries

    @Test func numberedEntriesAndTheBracketsThatCiteThem() {
        let text = page([body(0.1, "As shown before [1, 3–4] and later [2], the claim holds. " + sentence), body(0.3)])
        let references = list((1...5).map { "[\($0)] A. Author\($0). A title of work \($0). In Proceedings, 2020." })
        let judged = judge([text, references])
        #expect(judged.entries.map(\.id) == ["1", "2", "3", "4", "5"])
        #expect(judged.pages[0]?.cites[0] == ["1", "3", "4", "2"])
        #expect(judged.pages[0]?.entries["3"]?.text == "A. Author3. A title of work 3. In Proceedings, 2020.")
        // The list's own entries cite nothing.
        #expect(judged.pages[1] == nil)
    }

    @Test func entriesThatPDFKitJoinsComeApartAndALostLabelLosesNoMore() {
        let references = list([
            "[1] A. Author. First work. 2019. [2] B. Author. Second work, cited in [1]. 2020.",
            "[4] D. Author. Fourth work. 2021.", "[5] E. Author. Fifth work. 2022.",
        ])
        let judged = judge([references])
        #expect(judged.entries.map(\.id) == ["1", "2", "4", "5"])
        #expect(judged.entries[1].entry.text == "B. Author. Second work, cited in [1]. 2020.")
    }

    @Test func aListEndsAtTheNextPartsHeadingAndTheTextAfterItCites() {
        let references = page([
            heading("References"), entry("1. Abadie, A. A first study. Review, 2005.", 0.15), entry("2. Brown, T. A second study. 2020.", 0.2),
            entry("3. Chen, X. A third study. 2021.", 0.25), heading("Appendix A. Proofs", 0.35, size: 12),
            body(0.4, "The proof follows the method of ^{2} and of [3]. " + sentence),
        ])
        let judged = judge([references])
        #expect(judged.entries.map(\.id) == ["1", "2", "3"])
        #expect(judged.pages[0]?.cites[5] == ["3"])
    }

    @Test func keyedEntriesAndTheirCitations() {
        let text = page([body(0.1, "As [BK06] and [Gaw, Thm. 2] show, the bound holds. " + sentence)])
        let references = list([
            "[BK06] M. Broadie and O. Kaya, Exact simulation of stochastic volatility, Operations Research 54 (2006).",
            "[Gaw] K. Gawedzki, Lectures on conformal field theory, 1999.",
        ])
        let judged = judge([text, references])
        #expect(judged.entries.map(\.id) == ["BK06", "Gaw"])
        #expect(judged.pages[0]?.cites[0] == ["BK06", "Gaw"])
    }

    @Test func labelsInAColumnOfTheirOwnMatchTheirEntriesByCount() {
        let entries = [
            "1. 2. 3. Adams DK, Arellano SM, Govenar B. 2012 Larval dispersal: vent life in the water column. Oceanography 25.",
            "Beaulieu SE, Baker ET. 2015 Where are the undiscovered vents? Deep-Sea Res. 121. Baker ET, Resing JA. 2016 How many vent fields? Earth Lett. 449.",
        ]
        let judged = judge([list(entries)])
        #expect(judged.entries.map(\.id) == ["1", "2", "3"])
        #expect(judged.entries[2].entry.text.hasPrefix("Baker ET, Resing JA. 2016"))
        // Names that count otherwise than the labels give no entries rather than wrong ones.
        let short = judge([list(["1. 2. 3. Adams DK, Arellano SM. 2012 Larval dispersal. Oceanography 25.", "Beaulieu SE. 2015 Vents."])])
        #expect(short.entries.isEmpty)
    }

    // MARK: Citations

    @Test func raisedNumbersThatCiteTheListShowInBracketsAndNotesKeepTheirs() throws {
        let text = page([
            body(0.1, "Disease at diagnosis^{1}. The chair^{4} said survival is only 50%^{2,3} and falling^{5–6}. " + sentence), body(0.3),
            Item(text: "^{4}Chair of the board, 2019.", box: Box(x: 0.1, y: 0.88, width: 0.8, height: 0.012), size: 8),
        ])
        let references = list(
            (1...6).map { "\($0). Gatta, G. et al. Prognoses and improvement for head and neck cancers \($0). Eur. J. Cancer (2015)." })
        let layers = [text, references]
        let judged = judge(layers)
        let notes = notes(layers)
        var document = Output.Document(file: "paper.pdf", pageCount: 2)
        _ = document.add(try outputPage(0, text, judged, notes: notes[0] ?? PageNotes()))
        let report = document.report().text
        #expect(report.contains("Disease at diagnosis[1]. The chair[^4] said survival is only 50%[2,3] and falling[5–6]."))
    }

    @Test func inAPaperThatCitesInBracketsARaisedNumberStaysMaths() {
        let text = page([body(0.1, "Energy grows as mc^{2} for the mass [1], and the cost as such^{2} [2]. " + sentence)])
        let judged = judge([text, list(["[1] A. One. 2019.", "[2] B. Two. 2020.", "[3] C. Three. 2021."])])
        #expect(judged.pages[0]?.raised.isEmpty != false)
        #expect(judged.pages[0]?.cites[0] == ["1", "2"])
    }

    @Test func authorYearCitationsLeadToTheirEntries() {
        let text = page([
            body(0.1, "As found before (Abadie, 2005; Smith and Jones, 2020a), and by Brown et al. (2020), the effect holds. " + sentence)
        ])
        let references = list([
            "Abadie, A. (2005), “Semiparametric difference-in-difference estimators,” Review of Economic Studies, 72, 1–19.",
            "Smith, J., and Jones, K. (2020a), “A first paper,” Journal, 1.", "Smith, J. (2020b), “A second paper,” Journal, 2.",
            "Tom B. Brown, Benjamin Mann, and Nick Ryder. 2020. Language models are few-shot learners. In NeurIPS.",
        ])
        let judged = judge([text, references])
        #expect(judged.entries.map(\.id) == ["Abadie2005", "Smith2020a", "Smith2020b", "Brown2020"])
        #expect(judged.pages[0]?.cites[0] == ["Abadie2005", "Smith2020a", "Brown2020"])
    }

    @Test func aHangingIndentStartsABlockAndAFirstLineIndentDoesNot() {
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat) -> TextLayer.RawLine {
            TextLayer.RawLine(text: text, rect: CGRect(x: x, y: y, width: 400, height: 9), softBreak: false, size: 9)
        }
        let none = Dehyphenator(pageText: "")
        let hanging = [
            line("Abadie, A. (2005), “Semiparametric difference-in-difference", 50, 100), line("estimators,” Review, 72, 1–19.", 60, 110),
            line("Abbring, J. H. (2003), “The nonparametric identification of", 50, 120), line("treatment effects,” Econometrica, 71.", 60, 130),
        ]
        #expect(TextLayer.group(hanging, crop: CGRect(x: 0, y: 0, width: 600, height: 800), dehyphenator: none).count == 2)
        let paragraph = [line(sentence, 60, 100), line(sentence, 50, 110), line(sentence, 50, 120)]
        #expect(TextLayer.group(paragraph, crop: CGRect(x: 0, y: 0, width: 600, height: 800), dehyphenator: none).count == 1)
    }

    // MARK: Cross-references

    @Test func aSquareAfterABracketAndAFewAffiliationMarkersAreNoCitations() {
        let text = page([
            body(0.1, "We set a(r) = sin(r+1)^{2} and e^{-x}[0,1]^{2}. Tan^{2}, Jasperse^{1} wrote it. " + sentence)
        ])
        let judged = judge([text, list((1...12).map { "[\($0)] A. Author\($0). A title of work \($0). 2020." })])
        #expect(judged.pages[0]?.raised.isEmpty != false)
    }

    @Test func aRunningHeaderOfTheListsOwnNameDoesNotCutItInTwo() {
        let first = list((1...3).map { "[\($0)] A. Author\($0). A title of work \($0). In Proceedings, 2020." })
        let secondPage = page(
            [heading("References", 0.08)]
                + (4...6).map { entry("[\($0)] A. Author\($0). A title of work \($0). In Proceedings, 2020.", 0.15 + 0.05 * Double($0 - 4)) })
        let judged = judge([page([body(0.1, "It holds [5]. " + sentence)]), first, secondPage])
        #expect(judged.lists.count == 1)
        #expect(judged.entries.count == 6)
        #expect(judged.pages[0]?.cites[0] == ["5"])
    }

    @Test func aNumberWithADotInItLinksToo() throws {
        let text = page([body(0.1, "See Figure 3.7 and Table 2.1 for the data. " + sentence)])
        let second = page(
            [Item(text: "Figure 3.7: The results.", box: Box(x: 0.1, y: 0.5, width: 0.8, height: 0.02))],
            regions: [Region(kind: .figure, number: "3.7", box: Box(x: 0.1, y: 0.3, width: 0.8, height: 0.22), caption: [0], blocks: [])])
        let judged = judge([text, second])
        var document = Output.Document(file: "paper.pdf", pageCount: 2)
        _ = document.add(try outputPage(0, text, judged))
        #expect(document.report().text.contains("See [Figure 3.7](#p.2) and Table 2.1 for"))
    }

    @Test func crossReferencesLeadToThePagesThatHoldThem() throws {
        let text = page([body(0.1, "As Fig. 2 shows and Table 1 lists, by Eq. (3) in Section 2.1, the claim holds. " + sentence)])
        let second = page(
            [heading("2.1 Method"), Item(text: "Figure 2: The results.", box: Box(x: 0.1, y: 0.5, width: 0.8, height: 0.02))],
            regions: [Region(kind: .figure, number: "2", box: Box(x: 0.1, y: 0.3, width: 0.8, height: 0.22), caption: [1], blocks: [])])
        let third = page(
            [Item(text: "Table 1: The data.", box: Box(x: 0.1, y: 0.1, width: 0.8, height: 0.02)), body(0.5, "x + y = z (3)")],
            regions: [
                Region(kind: .table, number: "1", box: Box(x: 0.1, y: 0.1, width: 0.8, height: 0.3), caption: [0], blocks: []),
                Region(kind: .equation, number: "3", box: Box(x: 0.1, y: 0.5, width: 0.8, height: 0.08), caption: [], blocks: [1]),
            ])
        let judged = judge([text, second, third])
        var document = Output.Document(file: "paper.pdf", pageCount: 3)
        _ = document.add(try outputPage(0, text, judged))
        let report = document.report().text
        #expect(report.contains("As [Fig. 2](#p.2) shows and [Table 1](#p.3) lists, by [Eq. (3)](#p.3) in [Section 2.1](#p.2), the claim"))
    }

    @Test func aNumberThatTwoPagesHoldLeadsNowhere() {
        let text = page([body(0.1, "As Fig. 2 shows, the claim holds. " + sentence)])
        func figurePage() -> PageText {
            page(
                [Item(text: "Figure 2: The results.", box: Box(x: 0.1, y: 0.5, width: 0.8, height: 0.02))],
                regions: [Region(kind: .figure, number: "2", box: Box(x: 0.1, y: 0.3, width: 0.8, height: 0.22), caption: [0], blocks: [])])
        }
        let judged = judge([text, figurePage(), page([body(0.1)]), figurePage()])
        #expect(judged.pages[0]?.pointers.isEmpty != false)
    }

    // MARK: Output

    @Test func linksOnSeveralOnesEachTakeTheirOwn() {
        let text = "[1] A. Author. A study, 2019. 1 [2] B. Author. Another, 2020. 1"
        let links = [Output.Block.Link(text: "1", target: "p.1", at: 30), Output.Block.Link(text: "1", target: "p.1", at: 62)]
        #expect(Output.placed(text, links: links, style: .md) == "[1] A. Author. A study, 2019. [1](#p.1) [2] B. Author. Another, 2020. [1](#p.1)")
        // With no place to go by, each takes the next one free, and none goes inside another.
        let unplaced = links.map { Output.Block.Link(text: $0.text, target: $0.target) }
        #expect(!Output.placed(text, links: unplaced, style: .md).contains("](#p.1)](#p.1)"))
    }

    @Test func refsEndListsEachEntryOnceAndCountsItAgainstTheBudget() throws {
        let text = page([body(0.1, "First [1] and [2]. " + sentence), body(0.3, "Again [1]. " + sentence)])
        let words = String(repeating: "a long title of the work that goes on ", count: 6)
        let references = list((1...2).map { "[\($0)] A. Author. \(words)\($0). 2020." })
        let judged = judge([text, references])
        var document = Output.Document(file: "paper.pdf", pageCount: 2, refs: .end)
        _ = document.add(try outputPage(0, text, judged))
        let report = document.report().text
        #expect(report.components(separatedBy: "\n[1] (p.2) ").count == 2)
        #expect(report.contains("\n[2] (p.2) A. Author."))
        // The entries cost tokens where the text cites them: a budget that holds the text alone
        // stops the read before the second paragraph.
        var tight = Output.Document(file: "paper.pdf", pageCount: 2, refs: .end, budget: 120)
        _ = tight.add(try outputPage(0, text, judged))
        #expect(tight.next != nil)
        var off = Output.Document(file: "paper.pdf", pageCount: 2, budget: 120)
        _ = off.add(try outputPage(0, text, judged))
        #expect(off.next == nil)
        #expect(!off.report().text.contains("## References"))
    }

    @Test func refsEndSaysWhenTheListIsNotParsedYet() throws {
        let text = page([body(0.1, "First [1] and [2]. " + sentence)])
        let judged = judge([text])
        var document = Output.Document(file: "paper.pdf", pageCount: 2, refs: .end)
        _ = document.add(try outputPage(0, text, judged))
        let first = document.report(parsed: 1).text.components(separatedBy: "\n")[0]
        #expect(first.contains("references: none listed, no list seen in the pages parsed so far"))
        // Every page parsed: nothing is waiting to be found, and nothing is said.
        #expect(!document.report(parsed: 2).text.contains("no list seen"))
        var off = Output.Document(file: "paper.pdf", pageCount: 2)
        _ = off.add(try outputPage(0, text, judged))
        #expect(!off.report(parsed: 1).text.contains("no list seen"))
        // A list that is parsed but cited by nothing read: it was seen, so nothing says it was not.
        var seen = Output.Document(file: "paper.pdf", pageCount: 3, refs: .end)
        seen.listEntries = 12
        _ = seen.add(try outputPage(0, text, judged))
        #expect(!seen.report(parsed: 2).text.contains("no list seen"))
    }

    @Test func aParagraphThatCitesFortyEntriesListsAboutAThousandTokens() throws {
        let words = String(repeating: "a long title of the work that goes on ", count: 8)
        let text = page([body(0.1, "Many works [" + (1...40).map(String.init).joined(separator: ", ") + "]. " + sentence)])
        let references = page(
            [heading("References", 0.02)]
                + (1...40).map { entry("[\($0)] A. Author. \(words)\($0). 2020.", 0.05 + 0.021 * Double($0 - 1)) })
        let judged = judge([text, references])
        #expect(judged.entries.count == 40)
        var document = Output.Document(file: "paper.pdf", pageCount: 2, refs: .end)
        _ = document.add(try outputPage(0, text, judged))
        let report = document.report().text
        #expect(report.contains("more entries cited here, not listed: pdf ref paper.pdf "))
        #expect(Output.tokens(report) < 2_000)
    }
}
