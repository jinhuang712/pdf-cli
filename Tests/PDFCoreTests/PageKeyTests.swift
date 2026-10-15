import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let samplePaper = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2608.04589.pdf")

func coreGraphicsKeys(_ url: URL) throws -> [String] {
    let document = try #require(CGPDFDocument(url as CFURL))
    var keyer = PageKeyer()
    return (1...document.numberOfPages).map { keyer.key(for: document.page(at: $0)!) }
}

func pdfKitKeys(_ url: URL) throws -> [String] {
    let document = try #require(PDFDocument(url: url))
    var keyer = PageKeyer()
    return (0..<document.pageCount).map { keyer.key(for: document.page(at: $0)!.pageRef!) }
}

@Suite struct PageKeyTests {
    @Test func indexAndParseAgree() throws {
        // The index reads keys through Core Graphics, and the parse through PDFKit. A
        // mismatch would look like a file that changed under the parser.
        #expect(try coreGraphicsKeys(samplePaper) == pdfKitKeys(samplePaper))
    }

    @Test func keysAreStable() throws {
        #expect(try coreGraphicsKeys(samplePaper) == coreGraphicsKeys(samplePaper))
    }

    @Test func pagesWithDifferentContentHaveDifferentKeys() throws {
        let keys = try coreGraphicsKeys(samplePaper)
        #expect(Set(keys).count == keys.count)
    }

    /// A PDFKit save rewrites every page and damages its text: on this paper, "∗" comes back
    /// as "→" and the math letter "𝑒" as "!". The keys change because the text changed. If
    /// this test fails, Apple has fixed the damage, and DESIGNS.md → Decision: a file that
    /// PDFKit saved counts as a new file, with a warning, can be revisited.
    @Test func aPDFKitSaveChangesTheTextSoTheKeysChange() throws {
        let document = try #require(PDFDocument(url: samplePaper))
        let page = try #require(document.page(at: 0))
        let before = page.string
        let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 200, height: 14),
                                      forType: .highlight, withProperties: nil)
        page.addAnnotation(highlight)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-highlight-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(document.write(to: copy))
        let saved = try #require(PDFDocument(url: copy))
        #expect(saved.page(at: 0)?.string != before)
        #expect(try coreGraphicsKeys(copy) != coreGraphicsKeys(samplePaper))
    }
}
