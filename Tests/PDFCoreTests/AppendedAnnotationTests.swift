import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFCore

/// Apps such as Acrobat save a new highlight by appending to the file, and leave the page's
/// content objects as they were. The page key must not change then.
@Suite struct AppendedAnnotationTests {
    @Test func anAppendedHighlightLeavesEveryKeyUnchanged() throws {
        let original = try makeTwoPagePDF()
        let updated = try appendHighlight(to: original)
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: updated)
        }
        // The reader sees the new highlight, so the update is real.
        let document = try #require(PDFDocument(url: updated))
        #expect(document.page(at: 0)?.annotations.count == 1)
        #expect(try coreGraphicsKeys(updated) == coreGraphicsKeys(original))
    }

    /// A small PDF written by Core Graphics, which keeps each object readable as text.
    func makeTwoPagePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for number in 1...2 {
            context.beginPage(mediaBox: &box)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let text = NSAttributedString(string: "Page \(number) of a small test file.",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPage()
        }
        context.closePDF()
        return url
    }

    /// Appends an incremental update: a highlight object, page 1 again with an `/Annots`
    /// entry, and a cross-reference section that points back to the original one.
    func appendHighlight(to url: URL) throws -> URL {
        var bytes = try Data(contentsOf: url)
        let text = String(decoding: bytes, as: UTF8.self)
        let pageObject = try #require(firstPageObject(in: text))
        let size = try #require(integer(after: "/Size ", in: text))
        let root = try #require(text.range(of: "/Root ").map { text[$0.upperBound...].prefix { $0 != "R" } + "R" })
        let previous = try #require(integer(after: "startxref", in: text, last: true))

        let annotation = size
        var offsets: [(Int, Int)] = []
        func append(_ string: String) { bytes.append(Data(string.utf8)) }
        append("\n")
        offsets.append((annotation, bytes.count))
        append("\(annotation) 0 obj\n<< /Type /Annot /Subtype /Highlight /Rect [72 690 300 712] "
               + "/QuadPoints [72 712 300 712 72 690 300 690] /C [1 1 0] >>\nendobj\n")
        offsets.append((pageObject.number, bytes.count))
        append("\(pageObject.number) 0 obj\n<<\(pageObject.body) /Annots [\(annotation) 0 R] >>\nendobj\n")
        let xref = bytes.count
        append("xref\n")
        for (number, offset) in offsets.sorted(by: { $0.0 < $1.0 }) {
            append("\(number) 1\n" + String(format: "%010d 00000 n \n", offset))
        }
        append("trailer\n<< /Size \(annotation + 1) /Root \(root) /Prev \(previous) >>\nstartxref\n\(xref)\n%%EOF\n")

        let updated = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-\(UUID()).pdf")
        try bytes.write(to: updated)
        return updated
    }

    func firstPageObject(in text: String) -> (number: Int, body: String)? {
        var search = text.startIndex..<text.endIndex
        while let match = text.range(of: "/Type /Page", range: search) {
            search = match.upperBound..<text.endIndex
            guard text[match.upperBound...].first != "s",
                  let open = text.range(of: "<<", options: .backwards, range: text.startIndex..<match.lowerBound),
                  let header = text.range(of: " 0 obj", options: .backwards, range: text.startIndex..<open.lowerBound)
            else { continue }
            let number = Int(text[..<header.lowerBound].reversed().prefix { $0.isNumber }.reversed().map(String.init).joined())
            var depth = 0
            var index = open.lowerBound
            while index < text.endIndex {
                if text[index...].hasPrefix("<<") { depth += 1; index = text.index(index, offsetBy: 2); continue }
                if text[index...].hasPrefix(">>") {
                    depth -= 1
                    if depth == 0 { break }
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                index = text.index(after: index)
            }
            guard let number else { return nil }
            return (number, String(text[text.index(open.lowerBound, offsetBy: 2)..<index]))
        }
        return nil
    }

    func integer(after marker: String, in text: String, last: Bool = false) -> Int? {
        guard let range = text.range(of: marker, options: last ? .backwards : []) else { return nil }
        return Int(text[range.upperBound...].drop { $0.isWhitespace }.prefix { $0.isNumber })
    }
}
