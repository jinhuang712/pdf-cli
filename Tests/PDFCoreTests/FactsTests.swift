import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

@Suite struct FactsTests {
    /// A PDF written by hand from its objects, numbered from 1, with object 1 as its catalog.
    func makePDF(_ objects: [String]) throws -> URL {
        var data = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(data.utf8.count)
            data += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let table = data.utf8.count
        data += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { data += String(format: "%010d 00000 n \n", offset) }
        data += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-facts-\(UUID()).pdf")
        try Data(data.utf8).write(to: url)
        return url
    }

    func facts(_ objects: [String]) throws -> FileFacts {
        let url = try makePDF(objects)
        defer { try? FileManager.default.removeItem(at: url) }
        return FactReader.read(try #require(CGPDFDocument(url as CFURL)), url: url)
    }

    static let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"

    /// A page whose blocks are one line each, at the given heights.
    func page(_ index: Int, _ texts: [(String, Double)]) throws -> Output.Page {
        let blocks = texts.map { text, y in
            TextBlock(text: text, box: Box(x: 0.1, y: y, width: 0.4, height: 0.01),
                      lines: [TextLine(text: text, box: Box(x: 0.1, y: y, width: 0.4, height: 0.01))])
        }
        let layer = PageText(blocks: blocks, words: 0, runTogether: 0)
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        return Output.Page(index: index, result: PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "",
                                                            parseMillis: 1, data: data), key: "k\(index)")
    }

    // MARK: Facts

    /// One of each thing the facts count: an attached file, scripts on document open and on
    /// page open, a link that launches a program, a comment, a highlight, a filled form field,
    /// a bookmark and roman page labels.
    @Test func aFileTellsWhatItCarries() throws {
        let facts = try facts([
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 7 0 R /JavaScript 9 0 R >> /OpenAction 10 0 R "
                + "/Outlines 11 0 R /PageLabels << /Nums [0 << /S /r >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Annots [12 0 R 13 0 R 14 0 R 15 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /AA << /O 16 0 R >> >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Names [(data.csv) 8 0 R] >>",
            "<< /Type /Filespec /F (data.csv) /UF (data.csv) /EF << /F 17 0 R >> >>",
            "<< /Names [(init) 18 0 R] >>",
            "<< /S /JavaScript /JS (app.alert\\(1\\);) >>",
            "<< /Type /Outlines /First 19 0 R /Last 19 0 R /Count 1 >>",
            "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Please cite) >>",
            "<< /Type /Annot /Subtype /Highlight /Rect [50 50 100 60] /QuadPoints [50 60 100 60 50 50 100 50] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (Ada) /Rect [100 100 200 120] >>",
            "<< /Type /Annot /Subtype /Link /Rect [200 200 300 210] /A << /S /Launch /F (calc.exe) >> >>",
            "<< /S /JavaScript /JS (this.print\\(\\);) >>",
            "<< /Type /EmbeddedFile /Params << /Size 12 >> /Length 12 >>\nstream\nhello,world\n\nendstream",
            "<< /S /JavaScript /JS (var x = 1;) >>",
            "<< /Title (Second page) /Parent 11 0 R /Dest [4 0 R /XYZ 0 700 0] >>",
        ])
        #expect(facts.attachments == [FileFacts.Attachment(name: "data.csv", size: 12, page: nil)])
        #expect(Set(facts.scripts.map { "\($0.kind) on \($0.trigger) \($0.page.map(String.init) ?? "-")" })
                == ["JavaScript on document open -", "JavaScript on page open 1", "Launch on link click 0"])
        #expect(facts.scripts.count == 4)
        #expect(facts.scripts.contains { $0.kind == "Launch" && $0.detail == "calc.exe" })
        #expect(facts.comments == 1)
        #expect(facts.highlights == 1)
        #expect(facts.formFields == 1 && facts.filledFields == 1)
        #expect(facts.outline.map(\.title) == ["Second page"])
        #expect(facts.outline.first?.page == 1)
        #expect(facts.labels == ["i", "ii"])
        #expect(facts.failure == nil && !facts.partial)
    }

    /// A name tree whose node lists itself 40 times would take 40¹² visits if walked blindly.
    @Test func aNameTreeThatHoldsItselfIsWalkedOnce() throws {
        let started = Date()
        let facts = try facts([
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 4 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            Self.page,
            "<< /Kids [" + Array(repeating: "4 0 R", count: 40).joined(separator: " ") + "] >>",
        ])
        #expect(facts.attachments.isEmpty)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// An action whose chain lists itself 16 times would give a million scripts, once per path.
    /// It counts once for the document and once for the page whose link holds it.
    @Test func anActionChainedToItselfCountsOnce() throws {
        let facts = try facts([
            "<< /Type /Catalog /Pages 2 0 R /OpenAction 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /S /JavaScript /JS (x) /Next [" + Array(repeating: "4 0 R", count: 16).joined(separator: " ") + "] >>",
            "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /A 4 0 R >>",
        ])
        #expect(facts.scripts.map(\.trigger) == ["document open", "link click"])
    }

    /// A radio group with three buttons is one field; a text field shown on two pages is one;
    /// a push button holds no value. The text field's keystroke script sits on the field.
    @Test func eachFieldCountsOnceAndPushButtonsNotAtAll() throws {
        let widget = "/Type /Annot /Subtype /Widget /Rect [0 0 10 10]"
        let facts = try facts([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 9 0 R 10 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R 7 0 R 8 0 R 9 0 R 11 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [12 0 R] >>",
            "<< /FT /Btn /Ff 32768 /T (Choice) /V /Choice2 /Kids [6 0 R 7 0 R 8 0 R] >>",
            "<< \(widget) /Parent 5 0 R /AS /Off >>",
            "<< \(widget) /Parent 5 0 R /AS /Choice2 >>",
            "<< \(widget) /Parent 5 0 R /AS /Off >>",
            "<< \(widget) /FT /Btn /Ff 65536 /T (Go) >>",
            "<< /FT /Tx /T (Name) /Kids [11 0 R 12 0 R] /AA << /K 13 0 R >> >>",
            "<< \(widget) /Parent 10 0 R >>",
            "<< \(widget) /Parent 10 0 R >>",
            "<< /S /JavaScript /JS (AFNumber_Keystroke\\(2\\);) >>",
        ])
        #expect(facts.formFields == 2)
        #expect(facts.filledFields == 1)
        #expect(facts.scripts.map(\.trigger) == ["field keystroke"])
    }

    /// A page tree may list a node twice. CGPDF counts it twice, and so do the facts, so each
    /// script names the page CGPDF numbers.
    @Test func aPageTreeThatListsANodeTwiceKeepsCGPDFsPageNumbers() throws {
        let url = try makePDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [5 0 R 5 0 R] /Count 4 >>",
            "<< /Type /Page /Parent 5 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 5 0 R /MediaBox [0 0 612 792] /AA << /O << /S /JavaScript /JS (x) >> >> >>",
            "<< /Type /Pages /Parent 2 0 R /Kids [3 0 R 4 0 R] /Count 2 >>",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let facts = FactReader.read(document, url: url)
        #expect(document.numberOfPages == 4)
        #expect(facts.scripts.compactMap(\.page) == [1, 3])
    }

    /// A page label's start number at the integer limit would overflow once pages count on.
    @Test func aHugeLabelStartNumberIsNoCrash() throws {
        let facts = try facts([
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /St 9223372036854775807 >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            Self.page, Self.page,
        ])
        #expect(facts.labels == ["1000000000", "1000000001"])
    }

    /// A compressed attachment's stream length is not its size.
    @Test func anAttachmentThatDoesNotStateItsSizeHasNone() throws {
        let facts = try facts([
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 4 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            Self.page,
            "<< /Names [(data.csv) 5 0 R] >>",
            "<< /Type /Filespec /F (data.csv) /EF << /F 6 0 R >> >>",
            "<< /Type /EmbeddedFile /Filter /FlateDecode /Length 0 >>\nstream\n\nendstream",
        ])
        #expect(facts.attachments == [FileFacts.Attachment(name: "data.csv", size: nil, page: nil)])
    }

    /// Labels read from the catalog match PDFKit's, page by page.
    @Test func pageLabelsMatchPDFKit() throws {
        let url = try makePDF([
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /St 5 >> 3 << /P (A-) /S /A >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R] /Count 5 >>",
            Self.page, Self.page, Self.page, Self.page, Self.page,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = FactReader.read(try #require(CGPDFDocument(url as CFURL)), url: url)
        let pdf = try #require(PDFDocument(url: url))
        #expect(facts.labels == ["i", "ii", "5", "A-A", "A-B"])
        #expect(facts.labels == (0..<5).map { pdf.page(at: $0)?.label ?? "" })
        #expect(FactReader.letters(27) == "AA" && FactReader.roman(1994) == "MCMXCIV")
    }

    // MARK: Sections

    @Test func headingsLeaveOutRunningHeadersTableRowsAndChartLabels() throws {
        let pages = try [
            page(0, [("Journal of Things 12", 0.03), ("1 Introduction", 0.2), ("Abstract", 0.15)]),
            page(1, [("Journal of Things 13", 0.03), ("2 Method", 0.3), ("2.1 Data", 0.5)]),
            page(2, [("Journal of Things 14", 0.03), ("5 Italian 4–5", 0.4), ("0 I I I /", 0.5), ("3 Results", 0.6)]),
        ]
        let titles = Info.headings(pages).map(\.title)
        #expect(titles == ["1 Introduction", "Abstract", "2 Method", "2.1 Data", "3 Results"])
    }

    /// A book prints its chapter's title as the running header; the chapter's own heading stays.
    @Test func aChapterHeadingStaysBesideItsRunningHeader() throws {
        let pages = try [
            page(0, [("1 Introduction", 0.3)]),
            page(1, [("Introduction 2", 0.08), ("Body", 0.3)]),
            page(2, [("Introduction 3", 0.08), ("Body", 0.3)]),
            page(3, [("Introduction 4", 0.08), ("2 Method", 0.3)]),
        ]
        #expect(Info.headings(pages).map(\.title) == ["1 Introduction", "2 Method"])
    }

    /// An outline may list a later page first. Sections follow the pages, and each reaches to
    /// the next on the page.
    @Test func bookmarksOutOfPageOrderFollowThePages() throws {
        let outline = [FileFacts.Section(title: "Alpha", level: 1, page: 1, top: 0.1),
                       FileFacts.Section(title: "Beta", level: 1, page: 0, top: 0.5)]
        let pages = try [page(0, [("Opening words", 0.1), ("Beta", 0.5), ("Body", 0.6)]),
                         page(1, [("Alpha", 0.1), ("Body", 0.3)])]
        let sections = Info.sections(outline: outline, pages: pages, pageCount: 2, complete: true)
        #expect(sections.map(\.title) == ["Beta", "Alpha"])
        #expect(sections.map(\.lastPage) == [1, 2])
        #expect(sections.map(\.block) == [2, 1])
    }

    /// The text's reading order can put a right column's heading before the left column's.
    /// The outline's order stands on the page, and no section ends before it starts.
    @Test func onOnePageTheOutlinesOrderStands() throws {
        let outline = [FileFacts.Section(title: "Results", level: 1, page: 0, top: 0.1),
                       FileFacts.Section(title: "Methods", level: 1, page: 0, top: 0.2),
                       FileFacts.Section(title: "Tool", level: 2, page: 0, top: 0.6)]
        let pages = try [page(0, [("Results", 0.1), ("Body", 0.12), ("4.1. Tool", 0.6), ("Body of the tool", 0.65),
                                  ("4. Methods", 0.2), ("Body of the methods", 0.25)])]
        let sections = Info.sections(outline: outline, pages: pages, pageCount: 1, complete: true)
        #expect(sections.map(\.title) == ["Results", "Methods", "Tool"])
        #expect(sections.map(\.block) == [1, 5, 3])
        #expect(sections.allSatisfy { ($0.tokens ?? 0) > 0 })
        // A section whose next one sits above it on the page stops at the page's end.
        let inverted = Info.measure([Section(title: "Analysis", level: 2, page: 1, block: 2),
                                     Section(title: "Conclusion", level: 1, page: 1, block: 1)],
                                    pages: try [page(0, [("6. Conclusion", 0.1), ("5.4. Analysis", 0.5), ("Body", 0.6)]),
                                                page(1, [("References", 0.1)])],
                                    pageCount: 2, complete: true)
        #expect(inverted[0].lastPage == 1 && inverted[0].tokens ?? 0 > 0)
    }

    @Test func anAppendixHeadingIsFoundByItsNumberedTitle() throws {
        let layer = try #require(try page(0, [("A Implementation Details", 0.1), ("A.1 Dataset Statistics", 0.2)]).result.pageText)
        #expect(Info.place(FileFacts.Section(title: "Dataset Statistics", level: 2, page: 0, top: 0.1), in: layer) == 2)
    }

    /// Until the page where the next section starts is parsed, a section's end and size are
    /// unknown, not guessed.
    @Test func aSectionWhoseNextStartsOnAnUnparsedPageHasNoSizeYet() throws {
        let outline = [FileFacts.Section(title: "Beta", level: 1, page: 0, top: 0.5),
                       FileFacts.Section(title: "Alpha", level: 1, page: 1, top: 0.1)]
        let sections = Info.sections(outline: outline, pages: [try page(0, [("Beta", 0.5), ("Body", 0.6)])],
                                     pageCount: 2, complete: false)
        #expect(sections[0].lastPage == nil && sections[0].tokens == nil)

        // Once that page is parsed and has failed, the section takes it whole.
        let failed = Output.Page(index: 1, result: .failed("time limit"), key: "k1")
        let measured = Info.sections(outline: outline, pages: [try page(0, [("Beta", 0.5), ("Body", 0.6)]), failed],
                                     pageCount: 2, complete: true)
        #expect(measured[0].lastPage == 2 && measured[0].tokens ?? 0 > 0)
    }

    /// A bookmark lands on the heading that spells its title, not on a longer heading or a
    /// caption that ends with it.
    @Test func aBookmarkLandsOnTheHeadingThatSpellsItsTitle() throws {
        let layer = try #require(try page(0, [("Experimental Results", 0.2), ("Table 2: Main results", 0.3),
                                              ("4 Results", 0.5), ("A. Proofs", 0.8)]).result.pageText)
        #expect(Info.place(FileFacts.Section(title: "Results", level: 1, page: 0, top: 0.49), in: layer) == 3)
        #expect(Info.place(FileFacts.Section(title: "Proofs", level: 1, page: 0, top: nil), in: layer) == 4)
    }

    /// Facts that could not be read show as unknown, with the reason, never as none.
    @Test func unknownFactsShowAsUnknown() throws {
        let pages = [try page(0, [("Resources: Data and Baseline", 0.2), ("Body", 0.3)])]
        let info = Info(file: "a.pdf", pageCount: 1, pages: pages, facts: FileFacts(failure: "time limit"), metadataTitle: "")
        let text = info.render()
        #expect(info.comments == nil)
        #expect(text.contains("unknown, time limit"))
        #expect(!text.contains("scripts: none"))
        let outline = Info(file: "a.pdf", pageCount: 1, pages: pages, facts: {
            var facts = FileFacts()
            facts.outline = [FileFacts.Section(title: "Resources: Data and Baseline", level: 1, page: 0, top: 0.2)]
            return facts
        }(), metadataTitle: "")
        #expect(outline.render().contains("Resources: Data and Baseline p.1"))
    }

    /// Hundreds of bookmarks keep the table short: the top level first, then its first rows.
    @Test func aLongSectionTableIsCut() throws {
        func info(_ outline: [FileFacts.Section]) -> String {
            var facts = FileFacts()
            facts.outline = outline
            return Info(file: "a.pdf", pageCount: 300, pages: [], facts: facts, metadataTitle: "").render()
        }
        let chapters = (0..<30).flatMap { chapter in
            [FileFacts.Section(title: "Chapter \(chapter + 1)", level: 1, page: chapter * 10, top: nil)]
                + (0..<5).map { FileFacts.Section(title: "Part \(chapter + 1).\($0 + 1)", level: 2, page: chapter * 10 + $0, top: nil) }
        }
        let book = info(chapters)
        #expect(book.contains("Chapter 30") && !book.contains("Part 1.1"))
        #expect(book.contains("and 150 deeper sections; pdf info --json lists them"))
        let flat = info((0..<200).map { FileFacts.Section(title: "Entry \($0 + 1)", level: 1, page: $0, top: nil) })
        #expect(flat.contains("Entry 40 ") && !flat.contains("Entry 41 "))
        #expect(flat.contains("and 160 more sections; pdf info --json lists them"))
        let paper = info((0..<12).map { FileFacts.Section(title: "Section \($0 + 1)", level: 1 + $0 % 2, page: $0, top: nil) })
        #expect(paper.contains("Section 12") && !paper.contains("more sections") && !paper.contains("deeper sections"))
    }
}
