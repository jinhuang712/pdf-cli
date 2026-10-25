import CoreGraphics
import Foundation
import Testing
@testable import PDFCore

@Suite struct DrawingJoinTests {
    typealias Piece = Drawing.Piece

    /// The join as it was before M2.21: every pair compared on each pass, the first match taken.
    static func everyPair(_ pieces: [Piece], close: (CGRect, CGRect) -> Bool) -> [Piece] {
        var found = pieces
        var merged = true
        while merged {
            merged = false
            var next: [Piece] = []
            for item in found {
                if let at = next.firstIndex(where: { close($0.rect, item.rect) }) {
                    let other = next[at]
                    next[at] = (other.kind == "image" || item.kind == "image" ? "image" : "drawing", other.rect.union(item.rect),
                                other.curves + item.curves, other.bars + item.bars)
                    merged = true
                } else {
                    next.append(item)
                }
            }
            found = next
        }
        return found
    }

    static func nearSix(_ first: CGRect, _ second: CGRect) -> Bool { first.insetBy(dx: -6, dy: -6).intersects(second) }
    static func sideBySide(_ other: CGRect, _ item: CGRect) -> Bool {
        let shared = min(other.maxY, item.maxY) - max(other.minY, item.minY)
        let gap = max(other.minX - item.maxX, item.minX - other.maxX)
        return shared >= 0.5 * min(other.height, item.height) && gap <= 30
    }

    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11 &* 0x9E37_79B9_7F4A_7C15
        }
    }

    /// The grid finds the groups the pairwise join ends with, in the same order, on random pages
    /// of boxes, thin and wide ones, some far, some touching, for both joins of `findPictures`.
    @Test func theGridJoinsAsEveryPairDid() {
        var random = Generator(state: 7)
        for round in 0..<300 {
            let count = Int.random(in: 2...(round < 250 ? 40 : 400), using: &random)
            let pieces: [Piece] = (0..<count).map { _ in
                let wide = Bool.random(using: &random)
                let width = CGFloat.random(in: wide ? 20...200 : 1...30, using: &random)
                let height = CGFloat.random(in: wide ? 1...30 : 20...200, using: &random)
                let rect = CGRect(x: CGFloat.random(in: 0...(612 - 10), using: &random), y: CGFloat.random(in: 0...(792 - 10), using: &random),
                                  width: width, height: height)
                let image = Int.random(in: 0..<10, using: &random) == 0
                return (image ? "image" : "drawing", rect, image ? 0 : Int.random(in: 0...1, using: &random), Int.random(in: 0...1, using: &random))
            }
            let near = Drawing.join(pieces, reach: CGSize(width: 6.5, height: 6.5), close: Self.nearSix)
            let expectedNear = Self.everyPair(pieces, close: Self.nearSix)
            #expect(near.map(\.rect) == expectedNear.map(\.rect), "round \(round)")
            #expect(near.map(\.kind) == expectedNear.map(\.kind))
            #expect(near.map(\.curves) == expectedNear.map(\.curves))
            #expect(near.map(\.bars) == expectedNear.map(\.bars))
            let side = Drawing.join(pieces, reach: CGSize(width: 30.5, height: 0.5), close: Self.sideBySide)
            let expectedSide = Self.everyPair(pieces, close: Self.sideBySide)
            #expect(side.map(\.rect) == expectedSide.map(\.rect), "round \(round)")
            #expect(side.map(\.bars) == expectedSide.map(\.bars))
        }
    }

    /// 2,000 bars, 8 pt apart, none near another, and a line of 20 that joins: the pairwise join
    /// compared each bar with every group before it, two million times a pass (M1.14's review:
    /// a page built to need a join a pass, 80 strokes in a spiral, took 6.4 s in the debug
    /// build; that page is not in hand, so this counts the comparisons, which do not depend on
    /// the machine). The grid compares each bar with its neighbours.
    @Test func theGridComparesNeighboursNotEveryPair() {
        var pieces: [Piece] = (0..<1_980).map { index in
            ("drawing", CGRect(x: 20 + (index % 45) * 13, y: 200 + (index / 45) * 13, width: 5, height: 5), 0, 1)
        }
        pieces += (0..<20).map { ("drawing", CGRect(x: 20 + $0 * 9, y: 100, width: 5, height: 5), 0, 1) }
        var grid = 0, pairs = 0
        let joined = Drawing.join(pieces, reach: CGSize(width: 6.5, height: 6.5)) { first, second in
            grid += 1
            return Self.nearSix(first, second)
        }
        let expected = Self.everyPair(pieces) { first, second in
            pairs += 1
            return Self.nearSix(first, second)
        }
        #expect(joined.map(\.rect) == expected.map(\.rect))
        #expect(joined.count == 1_981)
        #expect(pairs > 1_000_000)
        #expect(grid < 50_000)
    }

    /// The same page through the drawing of a file: 2,000 shapes found, joined in well under a second.
    @Test func aPageOf2000ShapesJoinsFast() throws {
        var content = "0 g\n"
        for index in 0..<1_980 { content += "\(20 + (index % 45) * 13) \(200 + (index / 45) * 13) 5 5 re f\n" }
        for index in 0..<20 { content += "\(20 + index * 9) 100 5 5 re f\n" }
        let url = try madePDF(content: content)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let started = Date()
        let drawing = Drawing(page: page, crop: page.getBoxRect(.cropBox))
        let pictures = drawing.pictures()
        #expect(drawing.shapes.count == 2_000)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(pictures.count <= 1)
    }
}
