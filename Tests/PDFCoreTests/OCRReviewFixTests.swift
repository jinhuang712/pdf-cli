import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFCore

@Suite struct OCRReviewFixTests {
    @Test func annotationsStayOutOfTheOCRImage() async throws {
        let document = try #require(PDFDocument(url: ocrFolder.appendingPathComponent("scan-no-text.pdf")))
        let page = try #require(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 100, y: 400, width: 400, height: 60), forType: .freeText, withProperties: nil)
        note.contents = "ANNOTATION SECRET WORDS"
        note.font = NSFont.systemFont(ofSize: 24)
        page.addAnnotation(note)
        let layer = try #require(await OCR.pageText(page))
        #expect(!layer.text.contains("SECRET"))
        #expect(page.displaysAnnotations)
    }

    @Test func aPosterSizedPageRendersAtALowerResolution() throws {
        let document = try #require(PDFDocument(url: ocrFolder.appendingPathComponent("scan-no-text.pdf")))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 0, y: 0, width: 3000, height: 3000), for: .mediaBox)
        page.setBounds(CGRect(x: 0, y: 0, width: 3000, height: 3000), for: .cropBox)
        let image = try #require(OCR.render(page, dpi: 200))
        #expect(image.width * image.height <= 60_000_000)
        #expect(image.width > 5000)
    }

    @Test func aContentsPageWithDotLeadersKeepsItsTextLayer() {
        let line = "1.2 Background ............................................ 5\n"
        #expect(!OCR.needed(text: String(repeating: line, count: 30), images: 1))
        let form = "Name: ________________________  Date: ____________\n"
        #expect(!OCR.needed(text: String(repeating: form, count: 20), images: 1))
    }

    @Test func theOlderRecognizerReadsChinese() throws {
        let size = CGSize(width: 1200, height: 300)
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 48, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "这是一个用于检查中文识别的测试页面",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(line, context)
        let image = try #require(context.makeImage())
        let text = try #require(OCR.textRecognizerParagraphs(image)).map(\.text).joined()
        let chinese = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        #expect(chinese >= 12, "\(text)")
    }

    @Test func ocrThatLosesMostOfTheTextGivesWayToTheLayer() {
        let words = String(repeating: "measured value ", count: 20)
        let layer = PageText(blocks: [TextBlock(text: words, box: Box(x: 0, y: 0, width: 1, height: 1), lines: [])],
                             words: 40, runTogether: 0)
        let empty = PageText(blocks: [], words: 0, runTogether: 0)
        #expect(OCR.lostText(ocr: empty, layer: layer))
        #expect(!OCR.lostText(ocr: layer, layer: layer))
        #expect(!OCR.lostText(ocr: empty, layer: empty))
    }

    /// Lines of an OCR reading that lie over words the text layer hides go under a hidden run, and
    /// the others stay (M2.10's review, H1).
    @Test func ocrLinesOverHiddenWordsGoUnderTheirMarker() {
        func line(_ text: String, y: Double) -> TextLine { TextLine(text: text, box: Box(x: 0.1, y: y, width: 0.6, height: 0.03)) }
        let lines = [line("Visible words before.", y: 0.10), line("PLANTED ignore the paper.", y: 0.14), line("Visible words after.", y: 0.18)]
        let block = TextBlock(text: lines.map(\.text).joined(separator: " "), box: Box(x: 0.1, y: 0.10, width: 0.6, height: 0.11), lines: lines)
        var read = PageText(blocks: [block], words: 11, runTogether: 0)
        let spot = (box: Box(x: 0.12, y: 0.145, width: 0.3, height: 0.02), reason: HiddenReason.annotation)
        OCR.markHidden(&read, spots: [spot])
        let marked = read.blocks[0]
        let run = try? #require(marked.hidden?.first)
        #expect(marked.hidden?.count == 1 && run?.reason == .annotation)
        #expect(marked.visibleText == "Visible words before. Visible words after.", "\(marked.visibleText)")
        #expect(!marked.visibleText.contains("PLANTED") && marked.text.contains("PLANTED"))
        // Nothing overlaps: the block is left as it was.
        var untouched = PageText(blocks: [block], words: 11, runTogether: 0)
        OCR.markHidden(&untouched, spots: [(box: Box(x: 0.1, y: 0.5, width: 0.2, height: 0.02), reason: .tiny)])
        #expect(untouched.blocks[0] == block)
    }
}
