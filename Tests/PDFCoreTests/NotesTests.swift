import Foundation
import Testing

@testable import PDFCore

/// Footnotes, endnotes, headnotes and margin notes (ROADMAP.md → M2.7).
@Suite struct NotesTests {
    /// A one-block page element: its text, box and font size, in one line or more.
    struct Item {
        var text: String
        var box: Box
        var size: Double
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

    func page(_ items: [Item], regions: [Region] = []) -> PageText {
        var layer = PageText(blocks: items.map(block), words: 0, runTogether: 0)
        layer.regions = regions.isEmpty ? nil : regions
        let found = Notes.find(layer.blocks, regions: regions)
        if !found.notes.isEmpty { layer.notes = found.notes }
        if found.heading { layer.noteHeading = true }
        return layer
    }

    let sentence = "The committee argued that the proposal would change how the laboratory shares its data with others."
    func body(_ y: Double, _ text: String? = nil, x: Double = 0.1, width: Double = 0.8) -> Item {
        Item(text: text ?? sentence + " " + sentence, box: Box(x: x, y: y, width: width, height: 0.1), size: 10, lines: 4)
    }
    func note(_ y: Double, _ text: String, x: Double = 0.1, width: Double = 0.8, lines: Int = 1) -> Item {
        Item(text: text, box: Box(x: x, y: y, width: width, height: 0.012 * Double(lines)), size: 8, lines: lines)
    }

    // MARK: Footnotes

    @Test func aSmallBlockWithItsMarkerBelowTheTextIsAFootnote() {
        let layer = page([
            body(0.1, "It was said by the chair^{1}, and repeated. " + sentence + " " + sentence), body(0.3), body(0.5),
            note(0.85, "^{1}Chair of the board, 2019.", lines: 1), note(0.865, "continued on the next line of the note", lines: 1),
        ])
        #expect(layer.notes == [PageNote(kind: .footnote, marker: "1", blocks: [3, 4])])
    }

    /// On a page where the footnotes hold more characters than the text, theirs is not the body's size.
    @Test func footnotesLongerThanTheTextAreStillFootnotes() {
        let long = String(repeating: "a long note that goes on and on about the claim ", count: 20)
        let layer = page([body(0.1), body(0.3), note(0.7, "^{1}" + long), note(0.8, "^{2}" + long), note(0.9, "^{3}" + long)])
        #expect(layer.notes?.map(\.marker) == ["1", "2", "3"])
    }

    @Test func aSmallNumberedListAboveTheTextIsNone() {
        // Body-size text below it in its column: a list, not a footnote.
        let layer = page([body(0.1), note(0.3, "1 First item of a small list."), body(0.5), body(0.7)])
        #expect(layer.notes == nil)
    }

    @Test func aPageNumberAndACaptionAreNoFootnote() {
        let layer = page([body(0.1), body(0.3), body(0.5), note(0.88, "Figure 3. A caption in small type."), note(0.95, "12")])
        #expect(layer.notes == nil)
    }

    @Test func aNumberThatNoTextRefersToIsNoFootnoteUnlessRaised() {
        let plain = page([body(0.1), body(0.3), body(0.5), note(0.88, "7 patients were excluded after review.")])
        #expect(plain.notes == nil)
        let referred = page([
            body(0.1, "Seven were excluded^{7}. " + sentence + " " + sentence), body(0.3), body(0.5),
            note(0.88, "7 patients were excluded after review."),
        ])
        #expect(referred.notes?.first?.marker == "7")
        let raised = page([body(0.1), body(0.3), body(0.5), note(0.88, "^{7}Patients were excluded after review.")])
        #expect(raised.notes?.first?.marker == "7")
    }

    @Test func aSignIsAMarkerOnItsOwn() {
        let layer = page([body(0.1), body(0.3), body(0.5), note(0.88, "† Equal contribution of both authors.")])
        #expect(layer.notes == [PageNote(kind: .footnote, marker: "†", blocks: [3])])
    }

    @Test func linesThatStartWithARaisedMarkerStartABlock() {
        func line(_ text: String, _ y: Double, _ size: Double) -> TextLayer.RawLine {
            TextLayer.RawLine(text: text, rect: CGRect(x: 50, y: y, width: 400, height: 9), softBreak: false, size: size)
        }
        let lines = [
            line(sentence + " " + sentence + " " + sentence, 100, 10), line("^{1}First note goes here", 700, 8),
            line("and on a second line.", 710, 8), line("^{2}Second note goes here", 720, 8),
        ]
        #expect(Notes.starts(lines) == [false, true, false, true])
        // The same lines at the body's size are running text.
        let same = [line(sentence, 100, 10), line("^{1}Text", 700, 10)]
        #expect(Notes.starts(same) == [false, false])
    }

    // MARK: References

    @Test func aMarkerAfterAWordLinksButAnExponentDoesNot() {
        let references = [PageNotes.Reference(token: "2", ids: ["2"])]
        #expect(Notes.linked("As Newton^{2} said, x^{2} grows.", references) == "As Newton[^2] said, x^{2} grows.")
        #expect(Notes.linked("It ended.^{2} Then", references) == "It ended.[^2] Then")
        #expect(Notes.linked("The 10^{2} cases", references) == "The 10^{2} cases")
        // Only the first marker that can follow, and only the token the reference names.
        #expect(Notes.linked("a^{2} then word^{2} and word^{3}", references) == "a^{2} then word[^2] and word^{3}")
    }

    @Test func aReferenceNamesSeveralNotes() {
        let layer = page([
            body(0.1, "Haoru Tan^{1,†} wrote it. " + sentence + " " + sentence), body(0.3), body(0.5),
            note(0.86, "^{1}Department of Things, University."), note(0.88, "†Equal contribution of the authors."),
        ])
        let found = Notes.resolve(pages: [0], digests: [0: Notes.digest(layer, index: 0)])
        #expect(found[0]?.references[0] == [PageNotes.Reference(token: "1,†", ids: ["1", "†"])])
        #expect(found[0]?.entries.map(\.author) == [false, true])
    }

    // MARK: The document's numbering and endnotes

    @Test func numberingThatRestartsMakesSeriesInTheIds() {
        func chapter(_ number: Int) -> PageText {
            page([
                body(0.1, "A claim^{\(number)} by someone. " + sentence + " " + sentence), body(0.3), body(0.5),
                note(0.88, "^{\(number)}Note on the claim, as the chapter has it."),
            ])
        }
        // One series: ids are the numbers.
        let one = Notes.resolve(pages: [0, 1], digests: [0: Notes.digest(chapter(1), index: 0), 1: Notes.digest(chapter(2), index: 1)])
        #expect(one[1]?.entries.first?.id == "2")
        // Numbering that starts again at 1 on the second page: the first series' ids stay plain, the next carries its own.
        let two = Notes.resolve(pages: [0, 1], digests: [0: Notes.digest(chapter(1), index: 0), 1: Notes.digest(chapter(1), index: 1)])
        #expect(two[0]?.entries.first?.id == "1")
        #expect(two[1]?.entries.first?.id == "2.1")
    }

    func entries(_ numbers: ClosedRange<Int>, from y: Double = 0.2) -> [Item] {
        numbers.enumerated().map { position, number in
            Item(
                text: "\(number). Smith, a source of the claim, page \(number).",
                box: Box(x: 0.1, y: y + 0.06 * Double(position), width: 0.8, height: 0.02),
                size: 10)
        }
    }

    @Test func endnotesAreTheEntriesUnderANotesHeadingAndThePagesThatGoOn() {
        let first = page(
            [body(0.05), body(0.15), Item(text: "Notes", box: Box(x: 0.1, y: 0.3, width: 0.1, height: 0.02), size: 14)]
                + entries(1...5, from: 0.35))
        #expect(first.noteHeading == true)
        #expect(first.notes?.filter { $0.kind == .endnote }.map(\.marker) == ["1", "2", "3", "4", "5"])
        let second = page([body(0.05)] + entries(6...9))
        let third = page([body(0.05)] + entries(1...4))
        // A page that goes on from the list; a page that starts at 1 again goes on too, as the next
        // chapter's notes.
        let found = Notes.resolve(
            pages: [0, 1, 2],
            digests: [
                0: Notes.digest(first, index: 0), 1: Notes.digest(second, index: 1),
                2: Notes.digest(third, index: 2),
            ])
        #expect(found[0]?.entries.compactMap(\.id) == ["1", "2", "3", "4", "5"])
        #expect(found[1]?.entries.compactMap(\.id) == ["6", "7", "8", "9"])
        #expect(found[2]?.entries.compactMap(\.id) == ["2.1", "2.2", "2.3", "2.4"])
        // The same list without the page after it has one series, and plain ids.
        let alone = Notes.resolve(pages: [0, 1], digests: [0: Notes.digest(first, index: 0), 1: Notes.digest(second, index: 1)])
        #expect(alone[1]?.entries.compactMap(\.id) == ["6", "7", "8", "9"])
    }

    @Test func endnotesThatRunTogetherInOneBlockComeApart() {
        let run = "Michael Woodward interview (Jan. 25, 2004). 35.AAL transcript, telephone call, Sept. 11, 2001. 36. Ibid. 37. See Smith (2002)."
        let parts = Notes.split(run, after: 34)
        #expect(parts.map(\.number) == [34, 35, 36, 37])
        #expect(
            parts.map(\.text) == [
                "Michael Woodward interview (Jan. 25, 2004).", "AAL transcript, telephone call, Sept. 11, 2001.", "Ibid.", "See Smith (2002).",
            ])
        // A number that is not the next splits nothing.
        #expect(Notes.split("Report of 2004. 99. Later.", after: 34).count == 1)
    }

    @Test func aNumberedReferenceListWithNoNotesHeadingIsNoEndnotes() {
        let layer = page(
            [body(0.05), Item(text: "References", box: Box(x: 0.1, y: 0.3, width: 0.2, height: 0.02), size: 14)] + entries(1...6, from: 0.35))
        #expect(layer.noteHeading == nil)
        #expect(Notes.resolve(pages: [0], digests: [0: Notes.digest(layer, index: 0)]).isEmpty)
    }

    @Test func endnoteReferencesInTheChapterBeforeLink() {
        let text = page([body(0.1, "A fact^{1} was found, and another^{2} too. " + sentence + " " + sentence), body(0.3), body(0.5)])
        let list = page([Item(text: "Notes", box: Box(x: 0.1, y: 0.1, width: 0.1, height: 0.02), size: 14)] + entries(1...3, from: 0.2) + [body(0.5)])
        let found = Notes.resolve(pages: [0, 1], digests: [0: Notes.digest(text, index: 0), 1: Notes.digest(list, index: 1)])
        #expect(found[0]?.references[0]?.map(\.ids) == [["1"], ["2"]])
        let linked = Notes.linked(text.blocks[0].text, found[0]?.references[0] ?? [])
        #expect(linked.contains("fact[^1] was found, and another[^2] too"))
    }

    // MARK: Headnotes and margin notes

    @Test func aSmallParagraphUnderTheFirstHeadingBeforeBodyTextIsAHeadnote() {
        let heading = Item(text: "Chapter 4 The Long Road", box: Box(x: 0.1, y: 0.1, width: 0.8, height: 0.03), size: 18)
        let summary = Item(
            text: String(repeating: "In this chapter the road is walked from end to end. ", count: 4),
            box: Box(x: 0.1, y: 0.15, width: 0.8, height: 0.05), size: 8, lines: 3)
        let layer = page([heading, summary, body(0.25), body(0.4), body(0.55)])
        #expect(layer.notes == [PageNote(kind: .headnote, marker: nil, blocks: [1])])
        // An abstract is none.
        let abstract = Item(text: "Abstract. " + summary.text, box: summary.box, size: 8, lines: 3)
        #expect(page([heading, abstract, body(0.25), body(0.4), body(0.55)]).notes == nil)
    }

    @Test func aBlockBesideTheColumnsIsAMarginNote() {
        let margin = Item(text: "See also the chapter on rivers and lakes", box: Box(x: 0.76, y: 0.32, width: 0.2, height: 0.05), size: 8, lines: 3)
        let layer = page([body(0.1, width: 0.6), body(0.3, width: 0.6), body(0.5, width: 0.6), margin])
        #expect(layer.notes == [PageNote(kind: .margin, marker: nil, blocks: [3])])
        // Sideways text and page numbers are none.
        let tall = Item(text: "arXiv:2609.23257v2 [cs.LG] 8 Oct 2026", box: Box(x: 0.01, y: 0.2, width: 0.02, height: 0.4), size: 8)
        #expect(page([body(0.1, width: 0.6), body(0.3, width: 0.6), body(0.5, width: 0.6), tall]).notes == nil)
    }

    // MARK: Output

    func outputPage(_ index: Int, _ layer: PageText, notes: PageNotes) throws -> Output.Page {
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        let result = PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1, data: data)
        return Output.Page(index: index, result: result, key: "k\(index)", notes: notes)
    }

    func withFootnote() throws -> Output.Page {
        let layer = page([
            body(0.1, "It was said by the chair^{1}, and repeated. " + sentence + " " + sentence), body(0.3), body(0.5),
            note(0.85, "^{1}Chair of the board, 2019."),
        ])
        let notes = Notes.resolve(pages: [0], digests: [0: Notes.digest(layer, index: 0)])
        return try outputPage(0, layer, notes: notes[0] ?? PageNotes())
    }

    @Test func footnotesFollowTheOutputByDefault() throws {
        let page = try withFootnote()
        let text = Output.render(file: "paper.pdf", pageCount: 1, pages: [page]).text
        #expect(text.contains("by the chair[^1], and repeated."))
        #expect(!text.contains("¶4"))
        #expect(text.contains("## Notes\n\n[^1] (p.1) Chair of the board, 2019."))
        #expect(!text.contains("set aside"))
    }

    @Test func footnotesCanGoByTheirParagraphOrOut() throws {
        let page = try withFootnote()
        let inline = Output.render(file: "paper.pdf", pageCount: 1, pages: [page], notes: .inline).text
        let paragraph = inline.range(of: "¶1 ")!.lowerBound
        let noteAt = inline.range(of: "[^1] Chair of the board")!.lowerBound
        #expect(paragraph < noteAt && noteAt < inline.range(of: "¶2 ")!.lowerBound)
        #expect(!inline.contains("## Notes"))
        let off = Output.render(file: "paper.pdf", pageCount: 1, pages: [page], notes: .off).text
        #expect(!off.contains("Chair of the board"))
        #expect(off.contains("footnotes and endnotes: 1 set aside (show: --notes end)"))
    }

    @Test func aFootnoteWithNoReferenceStillShows() throws {
        let layer = page([body(0.1), body(0.3), body(0.5), note(0.85, "^{3}Chair of the board, 2019.")])
        let notes = Notes.resolve(pages: [0], digests: [0: Notes.digest(layer, index: 0)])
        let page = try outputPage(0, layer, notes: notes[0] ?? PageNotes())
        #expect(Output.render(file: "paper.pdf", pageCount: 1, pages: [page]).text.contains("[^3] (p.1) Chair of the board"))
        #expect(Output.render(file: "paper.pdf", pageCount: 1, pages: [page], notes: .inline).text.contains("[^3] Chair of the board"))
    }

    @Test func aMarginNoteGoesAfterItsParagraphAndAHeadnoteStaysLabelled() throws {
        let margin = Item(text: "See also the chapter on rivers and lakes", box: Box(x: 0.76, y: 0.32, width: 0.2, height: 0.05), size: 8, lines: 3)
        let layer = page([body(0.1, width: 0.6), body(0.3, width: 0.6), body(0.5, width: 0.6), margin])
        let notes = Notes.resolve(pages: [0], digests: [0: Notes.digest(layer, index: 0)])
        let text = Output.render(file: "paper.pdf", pageCount: 1, pages: [try outputPage(0, layer, notes: notes[0] ?? PageNotes())]).text
        let second = text.range(of: "¶2 ")!.lowerBound
        let aside = text.range(of: "¶4 [margin] See also")!.lowerBound
        #expect(second < aside && aside < text.range(of: "¶3 ")!.lowerBound)
    }

    @Test func notesAreInTheJSON() throws {
        let page = try withFootnote()
        var document = Output.Document(file: "paper.pdf", pageCount: 1)
        _ = document.add(page)
        let json = String(decoding: try document.json(), as: UTF8.self)
        #expect(json.contains("\"kind\":\"note\""))
        #expect(json.contains("\"id\":\"1\""))
        #expect(json.contains("\"place\":\"p.1\""))
    }

    /// A page of footnotes the size of its text, or of thousands of notes, goes out with a bound.
    @Test func aPageOfLongNotesIsHeldToItsBound() throws {
        let long = String(repeating: "a long note that goes on and on about the claim ", count: 70)
        var items =
            [body(0.02, "Claims^{1}, more^{2}, again^{3}, and^{4}, then^{5}, last^{6}. " + sentence)] + (1...9).map { body(0.04 * Double($0) + 0.02) }
        for number in 1...6 { items.append(note(0.45 + 0.07 * Double(number), "^{\(number)}" + long)) }
        let layer = page(items)
        let notes = Notes.resolve(pages: [0], digests: [0: Notes.digest(layer, index: 0)])
        let page = try outputPage(0, layer, notes: notes[0] ?? PageNotes())
        let text = Output.render(file: "paper.pdf", pageCount: 1, pages: [page]).text
        // Each note is cut at 800 tokens, whole by --footnote; the page holds about 4,000 in all.
        #expect(text.contains("(whole: pdf read paper.pdf --footnote 1)"))
        #expect(text.contains("more note"))
        #expect(Output.tokens(text) < 5_500)
    }
}
