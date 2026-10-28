import CoreGraphics
import Foundation

/// The order of a page's lines across its columns (FEATURES.md → F3, plan/ROADMAP.md → M2.5).
///
/// PDFKit gives a page's lines in an order that mostly reads well, but on some pages of two
/// columns it goes from one column to the other line by line: below the figure on p.5 of the
/// smoke set's arxiv-2608.24191.pdf, each paragraph came out as one-line blocks from both
/// columns in turn. Here the lines of a column go together: the page's gutter is the gap
/// between its columns, a line across both columns, as a title or a full-width figure's caption,
/// cuts the page into bands, and in a band of two columns of running text the left column's
/// lines come before the right's, right before left in a right-to-left script.
///
/// Only those bands move. Each goes out whole where PDFKit first reaches one of its full lines,
/// those bands from the top of the page down, and each column keeps PDFKit's own order of its lines;
/// every other line keeps its place. So a page PDFKit read column by column keeps its order
/// exactly, and so does what is no running text, as a table's cells, a grid of authors or a
/// figure's labels: placing the lines across a figure of three panels by their height cut each
/// panel's paragraphs into lines.
enum ReadingOrder {
    /// The lines' indices in reading order, and the lines that must start a block: where a band
    /// of columns starts, where each of its columns starts, and the line after it. Without them
    /// the first line of a column below a full-width caption joined the caption's block.
    /// - Parameters:
    ///   - rects: the lines' boxes, in points from the crop box's top-left corner.
    ///   - texts: the lines' text, which tells a right-to-left script.
    ///
    /// The page's pictures do not cut bands: M1.14 joins panels within 30 pt side by side, so a
    /// figure in the left column and a formula's drawn accent in the right made one picture
    /// across both, and the right column's first paragraph went into the figure's labels.
    static func order(_ rects: [CGRect], texts: [String]) -> (order: [Int], breaks: Set<Int>) {
        let all = Array(rects.indices)
        // A page set sideways, or one of vertical lines, keeps PDFKit's order.
        guard rects.filter({ $0.width >= $0.height }).count * 2 >= rects.count else { return (all, []) }
        var breaks = Set<Int>()
        return (arrange(all, rects: rects, texts: texts, depth: 0, breaks: &breaks), breaks)
    }

    static func arrange(_ lines: [Int], rects: [CGRect], texts: [String], depth: Int, breaks: inout Set<Int>) -> [Int] {
        // A line over three times as tall as most, as arXiv's stamp set sideways in the margin or
        // a table's row labels stacked, takes no part in finding the columns: the stamp made the
        // left column look wider than its lines. It joins a column by where it lies.
        let usual = median(lines.map { rects[$0].height })
        let flat = lines.filter { rects[$0].height <= 3 * usual }
        guard depth < 3, flat.count >= 4, let gutter = gutter(flat, rects: rects) else { return lines }
        let area = flat.reduce(CGRect.null) { $0.union(rects[$1]) }
        let leftWidth = gutter - area.minX
        let rightWidth = area.maxX - gutter
        // A line across both columns reaches a quarter of the way into each: a line of a column
        // that runs a little into the gutter is the column's.
        func spans(_ rect: CGRect) -> Bool { gutter - rect.minX >= 0.25 * leftWidth && rect.maxX - gutter >= 0.25 * rightWidth }

        let across = flat.filter { spans(rects[$0]) }.sorted { rects[$0].midY < rects[$1].midY }
        var crossing = Set(across)
        // The last line of a paragraph across both columns, as a caption's, right below it at its
        // left edge, goes with it when it is short or set at its size: in the band below, it left
        // the caption, and a search for the caption's words missed it. A column's first line
        // under a caption is full, at the body's size.
        for line in lines.sorted(by: { rects[$0].minY < rects[$1].minY }) where !crossing.contains(line) {
            let rect = rects[line]
            let short = rect.width < 0.8 * (rect.midX < gutter ? leftWidth : rightWidth)
            if crossing.contains(where: { above in
                let over = rects[above]
                return rect.minY >= over.maxY - 1 && rect.minY - over.maxY <= 0.7 * usual && abs(rect.minX - over.minX) <= 3
                    && (short || abs(rect.height - over.height) <= 0.05 * over.height)
            }) {
                crossing.insert(line)
            }
        }
        var bands = Array(repeating: [Int](), count: across.count + 1)
        for line in lines where !crossing.contains(line) {
            let middle = rects[line].midY
            bands[across.prefix { rects[$0].midY < middle }.count].append(line)
        }

        // Two columns of running text: on each side, two lines or more that fill 80% of its
        // width, as a column's lines do. At half, the text of a figure's three panels side by
        // side passed, and its paragraphs were cut in two at the page's gutter.
        func columns(_ left: [Int], _ right: [Int]) -> Bool {
            left.filter { rects[$0].width >= 0.8 * leftWidth }.count >= 2 && right.filter { rects[$0].width >= 0.8 * rightWidth }.count >= 2
        }
        // A side that is itself two columns of running text, as two of three columns beside a
        // figure's title, is no column: the band keeps PDFKit's order. Taken for one, on a census
        // report's page of three, a column's last line went after the whole figure.
        func split(_ side: [Int]) -> Bool {
            let lines = side.filter { rects[$0].height <= 3 * usual }
            guard lines.count >= 4, let inner = ReadingOrder.gutter(lines, rects: rects) else { return false }
            let area = lines.reduce(CGRect.null) { $0.union(rects[$1]) }
            let left = lines.filter { rects[$0].maxX <= inner }
            let right = lines.filter { rects[$0].minX >= inner }
            return left.filter { rects[$0].width >= 0.8 * (inner - area.minX) }.count >= 2
                && right.filter { rects[$0].width >= 0.8 * (area.maxX - inner) }.count >= 2
        }
        // The bands of two columns, from the top down, each in its order, and the full lines of
        // each, where it goes out.
        var arranged: [[Int]] = []
        var fullLines: [[Int]] = []
        var bandOf: [Int: Int] = [:]
        for band in bands {
            var left = band.filter { rects[$0].midX < gutter }
            var right = band.filter { rects[$0].midX >= gutter }
            guard columns(left, right), !split(left), !split(right) else { continue }
            // A short line between the columns' edges, as a page number set at the page's
            // middle, is neither column's, and keeps its place.
            let leftEdge = left.filter { rects[$0].width >= 0.8 * leftWidth }.map { rects[$0].maxX }.max() ?? gutter
            let rightEdge = right.filter { rects[$0].width >= 0.8 * rightWidth }.map { rects[$0].minX }.min() ?? gutter
            func between(_ line: Int) -> Bool {
                rects[line].width < 0.5 * min(leftWidth, rightWidth) && rects[line].midX > leftEdge && rects[line].midX < rightEdge
            }
            // Above the columns' first full line, what a blank a line high across the band parts
            // from them, as a grid of authors, is neither column's, and keeps its place: split at
            // the gutter, an author on the right came after the left column's introduction. A
            // table's header right above its rows stays with them, and a column's footnotes,
            // below it, are its own.
            func full(_ line: Int) -> Bool { rects[line].width >= 0.8 * (rects[line].midX < gutter ? leftWidth : rightWidth) }
            var top = -CGFloat.infinity
            var reach = -CGFloat.infinity
            for line in (left + right).sorted(by: { rects[$0].minY < rects[$1].minY }) {
                if reach > -.infinity, rects[line].minY - reach >= usual { top = rects[line].minY }
                if full(line) { break }
                reach = max(reach, rects[line].maxY)
            }
            func outside(_ line: Int) -> Bool { rects[line].minY < top }
            left.removeAll { between($0) || outside($0) }
            right.removeAll { between($0) || outside($0) }
            for line in left + right { bandOf[line] = arranged.count }
            fullLines.append((left + right).filter(full))
            var sides: [Int] = []
            for side in rightToLeft(band.map { texts[$0] }) ? [right, left] : [left, right] {
                let ordered = arrange(side, rects: rects, texts: texts, depth: depth + 1, breaks: &breaks)
                if let first = ordered.first { breaks.insert(first) }
                sides += ordered
            }
            arranged.append(sides)
        }
        guard !arranged.isEmpty else { return lines }
        // Each band goes out where PDFKit first reaches a full line of one not yet out, the bands
        // from the top down; every other line keeps its place. A full line, not any: a band went
        // out at arXiv's stamp, ahead of the page's title, and at a stray glyph, ahead of a
        // table's header set sideways.
        let position = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1, $0) })
        let starts = fullLines.compactMap { $0.compactMap { position[$0] }.min() }.sorted()
        let goesOut = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1, $0) })
        var ordered: [Int] = []
        var after = false
        for (at, line) in lines.enumerated() {
            if let band = goesOut[at] {
                ordered += arranged[band]
                after = true
            }
            if bandOf[line] == nil {
                if after { breaks.insert(line) }
                after = false
                ordered.append(line)
            }
        }
        return ordered
    }

    /// The x of the gap between columns: of the places in the middle half of the lines' width,
    /// the one fewest lines cross, at the middle of the widest stretch of such places. Nil when
    /// a quarter of the lines or more cross it, as on a page of one column.
    static func gutter(_ lines: [Int], rects: [CGRect]) -> CGFloat? {
        let area = lines.reduce(CGRect.null) { $0.union(rects[$1]) }
        guard !area.isNull, area.width >= 20 else { return nil }
        let spans = lines.map { (rects[$0].minX, rects[$0].maxX) }
        let from = area.minX + 0.25 * area.width
        let to = area.maxX - 0.25 * area.width
        // One place a point, at most 2,000.
        let step = max(1, (to - from) / 2_000)
        var fewest = Int.max
        var best: (start: CGFloat, end: CGFloat) = (0, -1)
        var run: CGFloat?
        var x = from
        while x <= to {
            let crossing = spans.reduce(0) { $0 + ($1.0 < x && $1.1 > x ? 1 : 0) }
            if crossing < fewest {
                fewest = crossing
                run = x
                best = (x, x)
            } else if crossing == fewest {
                let start = run ?? x
                run = start
                if x - start > best.end - best.start { best = (start, x) }
            } else {
                run = nil
            }
            x += step
        }
        guard fewest * 4 < lines.count, best.end >= best.start else { return nil }
        return (best.start + best.end) / 2
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Most of the letters belong to a script written right to left: Hebrew or Arabic.
    static func rightToLeft(_ texts: [String]) -> Bool {
        var backward = 0
        var forward = 0
        for text in texts {
            for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
                switch scalar.value {
                case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: backward += 1
                default: forward += 1
                }
            }
        }
        return backward > forward
    }
}
