import CoreGraphics
import Foundation
import Testing

@testable import PDFCore

/// A one-page PDF whose content stream is `content`, written to a temporary file.
func madePDF(content: String, name: String = UUID().uuidString) throws -> URL {
    var file = "%PDF-1.4\n"
    var offsets: [Int] = []
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << >> >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
    ]
    for (index, body) in objects.enumerated() {
        offsets.append(file.utf8.count)
        file += "\(index + 1) 0 obj\n\(body)\nendobj\n"
    }
    let table = file.utf8.count
    file += "xref\n0 5\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
    file += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
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
}
