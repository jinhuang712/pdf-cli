import CoreGraphics
import Foundation
import Testing
@testable import PDFCore

@Suite struct FactsTests {
    /// A two-page PDF written by hand, with one of each thing the facts count: an attached file,
    /// scripts on document open and on page open, a link that launches a program, a comment, a
    /// highlight, a filled form field, a bookmark and roman page labels.
    func makePDF() throws -> URL {
        let objects = [
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
        ]
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

    @Test func headingsLeaveOutRunningHeadersTableRowsAndChartLabels() throws {
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
        let pages = try [
            page(0, [("Journal of Things 12", 0.03), ("1 Introduction", 0.2), ("Abstract", 0.15)]),
            page(1, [("Journal of Things 13", 0.03), ("2 Method", 0.3), ("2.1 Data", 0.5)]),
            page(2, [("Journal of Things 14", 0.03), ("5 Italian 4–5", 0.4), ("0 I I I /", 0.5), ("3 Results", 0.6)]),
        ]
        let titles = Info.headings(pages).map(\.title)
        #expect(titles == ["1 Introduction", "Abstract", "2 Method", "2.1 Data", "3 Results"])
    }

    @Test func aFileTellsWhatItCarries() throws {
        let url = try makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        var facts = FactReader.document(document, url: url)
        for index in 0..<document.numberOfPages {
            facts.merge(FactReader.page(try #require(document.page(at: index + 1)), index: index))
        }
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
    }
}
