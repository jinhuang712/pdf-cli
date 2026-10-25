import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let samplePaper = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2608.04589.pdf")

func coreGraphicsKeys(_ url: URL) throws -> [String] {
    let document = try #require(CGPDFDocument(url as CFURL))
    var keyer = PageKeyer(catalog: document.catalog)
    return (1...document.numberOfPages).map { keyer.key(for: document.page(at: $0)!) }
}

func pdfKitKeys(_ url: URL) throws -> [String] {
    let document = try #require(PDFDocument(url: url))
    var keyer = PageKeyer(catalog: document.documentRef?.catalog)
    return (0..<document.pageCount).map { keyer.key(for: document.page(at: $0)!.pageRef!) }
}

@Suite struct PageKeyTests {
    @Test func indexAndParseAgree() throws {
        // The index reads keys through Core Graphics, and the parse through PDFKit. A
        // mismatch would look like a file that changed under the parser.
        #expect(try coreGraphicsKeys(samplePaper) == pdfKitKeys(samplePaper))
    }

    /// A page's alt text, from the file's structure tree, is part of its key: the same page
    /// under another tree, or none, is parsed again (the M2.6 review found another file's alt
    /// text served from the cache). A page with no tag keeps its key.
    @Test func altTextIsInTheKey() throws {
        let url = repoRoot.appendingPathComponent("testdata/safety/hidden-figure-alt.pdf")
        #expect(try coreGraphicsKeys(url) == pdfKitKeys(url))
        let document = try #require(CGPDFDocument(url as CFURL))
        var tree = PageKeyer(catalog: document.catalog), none = PageKeyer()
        let tagged = try #require(document.page(at: 1)), untagged = try #require(document.page(at: 2))
        #expect(tree.key(for: tagged) != none.key(for: tagged))
        #expect(tree.key(for: untagged) == none.key(for: untagged))
    }

    @Test func keysAreStable() throws {
        #expect(try coreGraphicsKeys(samplePaper) == coreGraphicsKeys(samplePaper))
    }

    @Test func pagesWithDifferentContentHaveDifferentKeys() throws {
        let keys = try coreGraphicsKeys(samplePaper)
        #expect(Set(keys).count == keys.count)
    }

    /// A PDFKit save rewrites every page, so the keys change. When M1.1 measured it, the rewrite
    /// also damaged the text: "∗" came back as "→" and the math letter "𝑒" as "!". The test used to
    /// expect that change and failed on 2026-10-25, the sign its comment named for Apple having
    /// fixed it: on this macOS (27), the text of all 11 pages of this paper is the same after a
    /// save (M2.25), so only the keys are checked. DESIGNS.md → Decision: a file that PDFKit saved
    /// counts as a new file, with a warning, stays: files saved by older macOS keep their damage,
    /// and nothing in the file tells the saves apart.
    @Test func aPDFKitSaveChangesTheKeys() throws {
        let document = try #require(PDFDocument(url: samplePaper))
        let page = try #require(document.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 200, height: 14),
                                      forType: .highlight, withProperties: nil)
        page.addAnnotation(highlight)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-highlight-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(document.write(to: copy))
        let saved = try #require(PDFDocument(url: copy))
        // The text of a saved page is the same on this macOS: the keys change for the rewrite alone.
        #expect(saved.pageCount == document.pageCount)
        #expect(try coreGraphicsKeys(copy) != coreGraphicsKeys(samplePaper))
    }
}
