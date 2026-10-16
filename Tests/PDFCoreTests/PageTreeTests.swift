import CoreGraphics
import Foundation
import Testing
@testable import PDFCore

/// The index walks the page tree once (`PageTree`), and must read each page as it did through
/// CGPDF: the same page at each number, the same key, the same font check.
@Suite struct PageTreeTests {
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-tree-\(UUID()).pdf")
        try Data(data.utf8).write(to: url)
        return url
    }

    /// A file of `count` pages, each with its own text, under one /Pages node or under nodes of
    /// `fanout` kids.
    func makeTree(_ count: Int, fanout: Int? = nil) throws -> URL {
        // 1 catalog, 2 root, 3 font; page i is object 4 + 2i, its contents 5 + 2i; nodes follow.
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        var parents = [Int](repeating: 2, count: count)
        var level = (0..<count).map { (number: 4 + 2 * $0, pages: 1) }
        var nodes: [(number: Int, kids: [Int], pages: Int)] = []
        var next = 4 + 2 * count
        if let fanout {
            while level.count > fanout {
                var grouped: [(number: Int, pages: Int)] = []
                for start in stride(from: 0, to: level.count, by: fanout) {
                    let group = level[start..<min(start + fanout, level.count)]
                    nodes.append((next, group.map(\.number), group.reduce(0) { $0 + $1.pages }))
                    grouped.append((next, nodes.last!.pages))
                    next += 1
                }
                level = grouped
            }
        }
        var parentOf: [Int: Int] = [:]
        for node in nodes { for kid in node.kids { parentOf[kid] = node.number } }
        for kid in level { parentOf[kid.number] = 2 }
        for index in 0..<count { parents[index] = parentOf[4 + 2 * index]! }
        let kids = level.map { "\($0.number) 0 R" }.joined(separator: " ")
        objects[1] = "<< /Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> >>"
        for index in 0..<count {
            let content = "BT /F1 24 Tf 72 700 Td [(Page) -300 (\(index + 1))] TJ ET"
            objects.append("<< /Type /Page /Parent \(parents[index]) 0 R /Contents \(5 + 2 * index) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        for node in nodes {
            let kids = node.kids.map { "\($0) 0 R" }.joined(separator: " ")
            objects.append("<< /Type /Pages /Parent \(parentOf[node.number]!) 0 R /Kids [\(kids)] /Count \(node.pages) >>")
        }
        return try makePDF(objects)
    }

    /// Reads every page of `url` both ways, expects them to agree, and gives how many pages the
    /// walk left to CGPDF, or nil where it declined the tree.
    func compare(_ url: URL) throws -> Int? {
        let document = try #require(CGPDFDocument(url as CFURL))
        guard let tree = PageTree(document) else { return nil }
        #expect(tree.pages.count == document.numberOfPages)
        var walked = PageKeyer()
        var direct = PageKeyer()
        var left = 0
        for (index, dictionary) in tree.pages.enumerated() {
            let page = try #require(document.page(at: index + 1))
            #expect(FactReader.identity(try #require(page.dictionary)) == FactReader.identity(dictionary))
            guard let key = walked.key(forDictionary: dictionary), let check = FontCheck(pageDictionary: dictionary) else {
                left += 1
                continue
            }
            let expected = FontCheck(page: page)
            #expect(key == direct.key(for: page), "\(url.lastPathComponent) p.\(index + 1)")
            let counts: [Int] = [check.gaps, check.risky, check.images]
            let expectedCounts: [Int] = [expected.gaps, expected.risky, expected.images]
            #expect(counts == expectedCounts, "\(url.lastPathComponent) p.\(index + 1)")
        }
        return left
    }

    @Test func theWalkReadsEveryTestFileAsCGPDFDoes() throws {
        let files = try #require(FileManager.default.enumerator(at: repoRoot.appendingPathComponent("testdata"),
                                                                includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "pdf" && !$0.path.contains("/locked/") }
        #expect(files.count >= 16)
        for url in files {
            #expect(try compare(url) == 0, "\(url.lastPathComponent)")
        }
    }

    @Test(arguments: [nil, 6] as [Int?]) func flatAndBalancedTreesAreWalked(fanout: Int?) throws {
        let url = try makeTree(2_000, fanout: fanout)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try compare(url) == 0)
    }

    /// CGPDF passes over a malformed box or rotation for its parent's, and keeps /Rotate as
    /// written. The walk reads what it is sure of the same way, and leaves the rest to CGPDF.
    @Test func oddBoxesAndRotationsKeyAsCGPDFDoes() throws {
        let read = [
            "/MediaBox [0 0 612 792]", "/MediaBox [0.1 0.25 612.3 791.9]", "/MediaBox [612 792 0 0]",
            "/MediaBox [-100 -50 512 742]", "/CropBox [10 20 600 780]", "/CropBox [-10 -20 700 900]",
            "/CropBox [300 400 900 1000]", "/CropBox [1000 1000 1100 1100]", "/CropBox [600 780 10 20]",
            "/CropBox [10.123456789 20.5 600.75 780.333]", "/CropBox [10 20 10 20]", "/MediaBox [0 0 0 0]",
            "/MediaBox [0 0 99999999999 792]", "/Rotate 90", "/Rotate -90", "/Rotate 450", "/Rotate 45",
            "/Rotate -720", "/Rotate 2147483647", "",
        ]
        let left = [
            "/CropBox [10 20 600]", "/CropBox [10 20 600 780 5]", "/CropBox (x)", "/MediaBox [0 0 612]",
            "/MediaBox [0 0 (a) 792]", "/Rotate 90.0", "/Rotate (90)", "/Rotate 9000000000",
        ]
        let entries = read + left
        let kids = (0..<entries.count).map { "\($0 + 3) 0 R" }.joined(separator: " ")
        let url = try makePDF(["<< /Type /Catalog /Pages 2 0 R >>",
                               "<< /Type /Pages /Kids [\(kids)] /Count \(entries.count) /MediaBox [0 0 500 600] /CropBox [5 5 400 500] /Rotate 180 >>"]
            + entries.map { "<< /Type /Page /Parent 2 0 R \($0) >>" })
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try compare(url) == left.count)
        let document = try #require(CGPDFDocument(url as CFURL))
        let tree = try #require(PageTree(document))
        for (index, entry) in entries.enumerated() {
            #expect((PageGeometry(dictionary: tree.pages[index])?.rotation == nil) == left.contains(entry), "\(entry)")
        }
    }

    /// Trees CGPDF may number otherwise than a walk: each goes page by page, as before.
    @Test func aTreeTheWalkCannotBeSureOfIsDeclined() throws {
        let page = "/Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
        let trees: [String: [String]] = [
            "a node listed twice": ["<< /Type /Pages /Kids [5 0 R 5 0 R] /Count 4 >>", "<< \(page.replacingOccurrences(of: "2 0 R", with: "5 0 R")) >>",
                                    "<< \(page.replacingOccurrences(of: "2 0 R", with: "5 0 R")) >>",
                                    "<< /Type /Pages /Parent 2 0 R /Kids [3 0 R 4 0 R] /Count 2 >>"],
            "a wrong count": ["<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 3 >>", "<< \(page) >>", "<< \(page) >>"],
            "a page without a type": ["<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>", "<< \(page) >>",
                                      "<< /Parent 2 0 R /MediaBox [0 0 612 792] >>"],
            "a page naming another parent": ["<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>", "<< \(page) >>",
                                             "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 612 792] >>"],
            "a kid that is no dictionary": ["<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>", "<< \(page) >>", "(page)"],
            "a missing kid": ["<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>", "<< \(page) >>"],
            "a root with a parent": ["<< /Type /Pages /Parent 1 0 R /Kids [3 0 R] /Count 1 >>", "<< \(page) >>"],
        ]
        for (name, objects) in trees {
            let url = try makePDF(["<< /Type /Catalog /Pages 2 0 R >>"] + objects)
            defer { try? FileManager.default.removeItem(at: url) }
            let document = try #require(CGPDFDocument(url as CFURL))
            #expect(PageTree(document)?.pages == nil, "\(name)")
        }
    }

    /// A page's contents may be several streams, read in turn, and a page with no contents has
    /// nothing to check.
    @Test func contentsInSeveralStreamsOrNoneAreChecked() throws {
        let gap = "BT /F1 12 Tf [(a) -300 (b) -300 (c)] TJ ET"
        let url = try makePDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [4 0 R 5 0 R 6 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Page /Parent 2 0 R /Contents [7 0 R 8 0 R] >>",
            "<< /Type /Page /Parent 2 0 R >>",
            "<< /Type /Page /Parent 2 0 R /Contents 7 0 R >>",
            "<< /Length \(gap.utf8.count) >>\nstream\n\(gap)\nendstream",
            "<< /Length \(gap.utf8.count) >>\nstream\n\(gap)\nendstream",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try compare(url) == 0)
        let document = try #require(CGPDFDocument(url as CFURL))
        let tree = try #require(PageTree(document))
        #expect(tree.pages.compactMap { FontCheck(pageDictionary: $0)?.gaps } == [4, 0, 2])
    }
}
