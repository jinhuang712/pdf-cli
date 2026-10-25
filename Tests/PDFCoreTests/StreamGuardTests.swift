import CoreGraphics
import Foundation
import Testing

@testable import PDFCore

/// A one-page PDF whose content stream is `content`, written to a temporary file.
func madePDF(content: String, name: String = UUID().uuidString) throws -> URL {
    try madePDF(objects: [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
    ], name: name)
}

/// A PDF of these objects, numbered from 1, written to a temporary file.
func madePDF(objects: [String], name: String = UUID().uuidString) throws -> URL {
    var file = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, body) in objects.enumerated() {
        offsets.append(file.utf8.count)
        file += "\(index + 1) 0 obj\n\(body)\nendobj\n"
    }
    let table = file.utf8.count
    file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
    file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-\(name).pdf")
    try Data(file.utf8).write(to: url)
    return url
}

@Suite struct StreamGuardTests {
    /// M2.21: the key of a page whose content stream of 600 KB inflates to 600 MB is made without
    /// decoding it into memory, and says the page is not read. Before, the key alone took 15 s and
    /// 1.2 GB; the same page cost the worker 30 s more.
    @Test func aContentStreamBombIsRefusedAtOnce() throws {
        let url = repoRoot.appendingPathComponent("testdata/safety/broken-content-bomb.pdf")
        let document = try #require(CGPDFDocument(url as CFURL))
        var keyer = PageKeyer(catalog: document.catalog)
        _ = keyer.key(for: try #require(document.page(at: 1)))
        #expect(keyer.refusal == nil)
        let started = Date()
        let key = keyer.key(for: try #require(document.page(at: 2)))
        #expect(keyer.refusal != nil)
        #expect(Date().timeIntervalSince(started) < 5)
        // The same page keeps its key, in another keyer, and a shared stream refuses the next page too.
        var other = PageKeyer(catalog: document.catalog)
        #expect(other.key(for: try #require(document.page(at: 2))) == key)
        #expect(other.refusal == keyer.refusal)
        #expect(other.key(for: try #require(document.page(at: 2))) == key)
        #expect(other.refusal != nil)
    }

    /// A page under the limit keeps the key it always had: only a page over it is keyed apart.
    @Test func aPageUnderTheLimitKeepsItsKey() throws {
        let small = try madePDF(content: String(repeating: "q Q\n", count: 100))
        let large = try madePDF(content: String(repeating: "q Q\n", count: 5_000))
        defer { [small, large].forEach { try? FileManager.default.removeItem(at: $0) } }
        func keys(_ url: URL, limit: Int) throws -> (key: String, refusal: String?) {
            let document = try #require(CGPDFDocument(url as CFURL))
            // 0 checks every stream, whatever its stored size.
            var keyer = PageKeyer(catalog: document.catalog, operatorLimit: limit, checkedAbove: 0)
            return (keyer.key(for: try #require(document.page(at: 1))), keyer.refusal)
        }
        let plain = try keys(small, limit: .max - 1)
        #expect(plain.refusal == nil)
        #expect(try keys(small, limit: 1_000) == plain)
        let over = try keys(large, limit: 1_000)
        #expect(over.refusal != nil)
        #expect(over.key != (try keys(large, limit: .max - 1)).key)
        #expect(try keys(large, limit: 1_000) == over)
    }

    /// Two pages that share a resources dictionary holding a form of 5,000 operators (the limit is
    /// 1,000 here), keyed one after the other by one keyer, as a parse or index job does: both are
    /// refused. The review of M2.21 found the second went on to PDFKit, because the shared dictionary
    /// was remembered without the refusal inside it.
    @Test func aRefusalIsKeptForLaterPagesThatShareTheForm() throws {
        let form = "q Q\n" + String(repeating: "q Q\n", count: 2_500)
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources 7 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources 7 0 R >>",
            "<< /Length 6 >>\nstream\n/Fm Do\nendstream", "<< /Length 7 >>\nstream\n/Fm Do \nendstream",
            "<< /XObject << /Fm 8 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Length \(form.utf8.count) >>\nstream\n\(form)endstream",
        ]
        let url = try madePDF(objects: objects)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        var keyer = PageKeyer(catalog: document.catalog, operatorLimit: 1_000, checkedAbove: 0)
        _ = keyer.key(for: try #require(document.page(at: 1)))
        #expect(keyer.refusal != nil)
        _ = keyer.key(for: try #require(document.page(at: 2)))
        #expect(keyer.refusal != nil, "the second page of one keyer lost the refusal")
        var alone = PageKeyer(catalog: document.catalog, operatorLimit: 1_000, checkedAbove: 0)
        _ = alone.key(for: try #require(document.page(at: 2)))
        #expect(alone.refusal != nil)
    }

    /// Streams the stored length does not bound: two Flate filters in an array (about 1 KB stored,
    /// 600 MB decoded), and a Type 3 glyph procedure, which is a content stream too.
    @Test func aFilterArrayAndAGlyphProcedureAreCountedToo() throws {
        let url = repoRoot.appendingPathComponent("testdata/safety/broken-content-bomb-more.pdf")
        let document = try #require(CGPDFDocument(url as CFURL))
        // Every page shares the resources that hold the glyph procedure, so each is refused.
        let started = Date()
        for number in [1, 2, 3] {
            var one = PageKeyer(catalog: document.catalog)
            _ = one.key(for: try #require(document.page(at: number)))
            #expect(one.refusal != nil, "p.\(number) was copied out whole")
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
