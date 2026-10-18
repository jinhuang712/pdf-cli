import CoreGraphics
import Foundation

/// A figure, a table or a numbered equation on a page (FEATURES.md → F3 and F5, ROADMAP.md →
/// M2.6). `pdf read` shows it as one block in place of the text inside it, which `--raw` shows,
/// `pdf info` lists the figures and tables, and `pdf crop --figure 4` crops it.
public struct Region: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case figure, table, equation
    }

    public var kind: Kind
    /// The number its caption gives, as "4", "4a", "B-1", "2.3" or "IV", or the equation's, as
    /// "5" or "A.2".
    public var number: String
    /// The region with its caption, as `pdf crop` crops it, in fractions of the page.
    public var box: Box
    /// The blocks of its caption, counted from 0, whose text the region's block shows.
    public var caption: [Int]
    /// The blocks inside it, counted from 0, which normal output sets aside: a table's cells
    /// without their rows and columns, a figure's labels, an equation's symbols out of place.
    public var blocks: [Int]
    /// The file's alternate text for the pictures inside it: text a reader cannot see, so it
    /// goes out only with `--include-hidden`.
    public var alt: String? = nil

    /// "figure 4", "table B-1" or "equation 5".
    public var name: String { "\(kind.rawValue) \(number)" }
}

/// Finds figures, tables and numbered equations by rules on a page's lines and drawing
/// commands, with no model (DESIGNS.md → Decision: Rules on PDFKit's fonts and positions over a
/// default layout model). The M0 spike's figure finder, whose captions and pairing these follow,
/// found 54 of 54 figures with their captions on 116 pages of papers.
///
/// - A caption is a line that starts "Figure 4", "Fig. 4", "Fig 4", "Table 2", "TABLE IV", "图 3"
///   or "表 1", with the lines below it that go on with it. A line that only goes on from a line
///   of running text above it, as "… as shown in" over "Figure 1. We …", is no caption.
/// - A figure is the pictures nearest its caption in its column, above it or else below,
///   within 15% of the page, with the pictures stacked within 24 pt and the short lines around
///   them, its panels' labels.
/// - A table is the horizontal rules that chain from its caption, the first within 30 pt, two
///   at least, with text between: a table drawn without rules is not found, and its text reads
///   as text.
/// - An equation is a line that ends in its number, as "(5)", set 1.5 em or more apart from the
///   rest, with the lines of maths above and below it that read as no running text.
enum Regions {
    /// A region found, by the page's lines in reading order, in points from the crop box's top
    /// left.
    struct Found: Equatable {
        var kind: Region.Kind
        var number: String
        var box: CGRect
        var caption: [Int]
        var content: [Int]
    }

    struct Caption {
        var kind: Region.Kind
        var number: String
        var box: CGRect
        var lines: [Int]
    }

    /// The page's regions, and the lines of every caption, found a region or not: each caption
    /// is a block of its own. `pictures`, `rules` and `shapes` are in points from the crop box's
    /// top left, as the lines are.
    static func find(_ lines: [TextLayer.RawLine], pictures: [CGRect], rules: [CGRect], shapes: [CGRect] = [], size: CGSize)
        -> (regions: [Found], captions: [[Int]])
    {
        guard size.width > 0, size.height > 0, !lines.isEmpty else { return ([], []) }
        let visible = lines.map { Self.visible($0.text) }
        let captions = Self.captions(lines, visible: visible, marks: rules + pictures, size: size)
        let captionLines = Set(captions.flatMap(\.lines))
        var used = Set<Int>()
        var found: [Found] = []
        var tables: [CGRect] = []
        // Tables first, so the shading of their cells is theirs.
        for caption in captions where caption.kind == .table {
            guard let box = table(caption, rules: rules, lines: lines, captions: captions, size: size) else { continue }
            for (index, picture) in pictures.enumerated() where share(of: picture, inside: box.insetBy(dx: -4, dy: -4)) > 0.6 {
                used.insert(index)
            }
            let content = lines.indices.filter { !captionLines.contains($0) && share(of: lines[$0].rect, inside: box.insetBy(dx: -2, dy: -2)) >= 0.6 }
            let whole = content.reduce(box.union(caption.box)) { $0.union(lines[$1].rect) }
            tables.append(whole)
            found.append(Found(kind: .table, number: caption.number, box: whole, caption: caption.lines, content: content))
        }
        for caption in captions where caption.kind == .figure {
            let drawn = shapes.filter { shape in !tables.contains { $0.insetBy(dx: -2, dy: -2).contains(shape) } }
            guard let box = figure(caption, pictures: pictures, used: &used, captions: captions, lines: lines,
                                   captionLines: captionLines, size: size)
                ?? figure(caption, shapes: drawn, captions: captions, lines: lines, captionLines: captionLines, size: size)
            else { continue }
            let content = lines.indices.filter { !captionLines.contains($0) && share(of: lines[$0].rect, inside: box) >= 0.6 }
            found.append(Found(kind: .figure, number: caption.number, box: box.union(caption.box), caption: caption.lines, content: content))
        }
        // A line belongs to one region: the first that takes it.
        var taken = captionLines
        for index in found.indices {
            found[index].content.removeAll { taken.contains($0) }
            taken.formUnion(found[index].content)
        }
        found += equations(lines, visible: visible, taken: taken, size: size)
        return (found, captions.map(\.lines))
    }

    /// A line's text without what a reader cannot see.
    static func visible(_ marked: String) -> String {
        let (text, hidden) = TextLayer.hiddenRuns(marked)
        guard !hidden.isEmpty else { return TextLayer.withoutMarks(text) }
        var units = Array(text.utf16)
        for run in hidden.sorted(by: { $0.offset > $1.offset }) where run.offset + run.length <= units.count {
            units.replaceSubrange(run.offset..<run.offset + run.length, with: Array(" ".utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// How much of a rectangle lies inside another, from 0 to 1.
    static func share(of rect: CGRect, inside box: CGRect) -> CGFloat {
        let shared = rect.intersection(box)
        guard !shared.isNull else { return 0 }
        let area = rect.width * rect.height
        // A line or a rule with no height counts by its width.
        return area > 0 ? shared.width * shared.height / area : (rect.width > 0 ? shared.width / rect.width : 1)
    }

    // MARK: Captions

    static let captionPattern = try! NSRegularExpression(
        pattern: #"^\s*(Figure|FIGURE|Fig\.?|FIG\.?|Table|TABLE|Tab\.|图|表)\s*((?:[A-Z]{1,2}[.\-]?)?\d{1,3}(?:[.\-–]\d{1,3})*|[IVXL]{1,6}(?![A-Za-z]))(\s?\(?[a-z]\)?(?![A-Za-z]))?\s*([:.|—–]|$)?"#)

    /// The page's captions, each with the lines that go on with it.
    static func captions(_ lines: [TextLayer.RawLine], visible: [String], marks: [CGRect], size: CGSize) -> [Caption] {
        let mid = size.width / 2, margin = size.width * 0.05
        func crossesMiddle(_ rect: CGRect) -> Bool { rect.minX < mid - margin && rect.maxX > mid + margin }
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5 * min(a.height, b.height) }
        func label(_ index: Int) -> NSTextCheckingResult? {
            captionPattern.firstMatch(in: visible[index], range: NSRange(location: 0, length: (visible[index] as NSString).length))
        }
        var found: [Caption] = []
        var claimed = Set<Int>()
        for index in lines.indices where !claimed.contains(index) {
            guard let match = label(index) else { continue }
            let text = visible[index] as NSString
            let word = text.substring(with: match.range(at: 1))
            var number = text.substring(with: match.range(at: 2))
            let isTable = word.lowercased().hasPrefix("tab") || word == "表"
            // Roman numerals number tables, as IEEE's "TABLE IV"; "Figure I" is a word.
            if number.allSatisfy({ "IVXL".contains($0) }) && !isTable { continue }
            if match.range(at: 3).location != NSNotFound { number += text.substring(with: match.range(at: 3)).filter(\.isLetter) }
            let punctuated = match.range(at: 4).location != NSNotFound && match.range(at: 4).length > 0
            let line = lines[index].rect
            // An in-text reference that wrapped to a line's start ("… as shown in" over "Figure 1.
            // We …") sits right under a wide line of running text that does not end a sentence. The
            // line above is found by position, as PDFKit can interleave columns. A rule between
            // the two, as a table's last, means the line above is no running text.
            let above = lines.indices.filter { other in
                let rect = lines[other].rect
                return other != index && rect.minX < line.maxX && line.minX < rect.maxX && rect.midY < line.minY
            }.max { lines[$0].rect.maxY < lines[$1].rect.maxY }
            if let above {
                let rect = lines[above].rect
                let gap = line.minY - rect.maxY
                // A word broken at the line's end goes on in lowercase, so a line that ends in a
                // hyphen goes on with no caption.
                let ends = visible[above].trimmingCharacters(in: .whitespaces).last.map { ".:!?-".contains($0) } ?? true
                let between = CGRect(x: line.minX, y: rect.maxY - 0.5, width: line.width, height: max(gap, 0) + 1)
                let ruled = marks.contains { $0.intersects(between) && $0.width >= 25 }
                if gap > -2, gap < line.height * 0.5, rect.width > size.width * 0.3, !ends, !ruled, prose(visible[above]) { continue }
            }
            if !punctuated {
                // No ":" or "." after the number: a caption only where its line starts a block and
                // its next word is a capital, so "Figure 3 shows …" at a line's start is none. A
                // label alone on its line, as IEEE's "TABLE I", goes on below.
                let rest = text.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
                if let first = rest.first, !first.isUppercase { continue }
                if let above, line.minY - lines[above].rect.maxY < line.height * 0.6 { continue }
            }
            // The lines that go on with it: just below and across the same width, or beside it on
            // its row, as PDFKit splits a line at inline maths.
            var box = line
            var members = [index]
            let height = max(line.height, 6)
            let spanning = crossesMiddle(line)
            while members.count < 20 {
                let last = lines[members[members.count - 1]].rect
                let free = lines.indices.filter { !members.contains($0) && !claimed.contains($0) && label($0) == nil }
                let fragment = free.first { other in
                    let rect = lines[other].rect
                    let gap = max(last.minX, rect.minX) - min(last.maxX, rect.maxX)
                    return sameRow(last, rect) && gap < 12 && (spanning || (rect.midX < mid) == (line.midX < mid))
                }
                let below = free.filter { other in
                    let rect = lines[other].rect
                    let gap = rect.minY - last.maxY
                    let overlap = min(box.maxX, rect.maxX) - max(box.minX, rect.minX)
                    return gap > -height * 0.5 && gap < height * 0.7 && overlap > 0.5 * min(box.width, rect.width)
                }.min { lines[$0].rect.minY < lines[$1].rect.minY }
                guard let pick = fragment ?? below else { break }
                let rect = lines[pick].rect
                if fragment == nil {
                    // A rule or a picture between the two ends the caption, unless it is small, as a
                    // legend's colored square inside the caption's text; so does a change of size.
                    let top = last.maxY, bottom = rect.minY
                    let band = CGRect(x: max(box.minX, rect.minX), y: min(top, bottom), width: max(min(box.maxX, rect.maxX) - max(box.minX, rect.minX), 0),
                                      height: max(abs(bottom - top), 0.2))
                    if marks.contains(where: { $0.intersects(band) && !$0.contains(band) && $0.width >= min(25, band.width * 0.5) }) { break }
                    if abs(rect.height - line.height) > 0.3 * line.height { break }
                    // Under a caption across the page, a line of one column with a partner in the
                    // other on its row is running text.
                    if spanning, !crossesMiddle(rect),
                       lines.indices.contains(where: { $0 != pick && !members.contains($0) && sameRow(lines[$0].rect, rect)
                           && (lines[$0].rect.midX < mid) != (rect.midX < mid) }) {
                        break
                    }
                }
                box = box.union(rect)
                members.append(pick)
            }
            claimed.formUnion(members)
            found.append(Caption(kind: isTable ? .table : .figure, number: number, box: box, lines: members))
        }
        return found
    }

    /// The width a caption's figure or table must stand in: its column, or the whole page when
    /// the caption crosses the middle.
    static func band(_ caption: Caption, size: CGSize) -> (range: ClosedRange<CGFloat>, spanning: Bool) {
        let mid = size.width / 2, margin = size.width * 0.05
        if caption.box.minX < mid - margin && caption.box.maxX > mid + margin { return (0...size.width, true) }
        return (caption.box.midX < mid ? 0...mid : mid...size.width, false)
    }

    static func inBand(_ rect: CGRect, _ band: (range: ClosedRange<CGFloat>, spanning: Bool)) -> Bool {
        band.spanning ? rect.maxX > band.range.lowerBound && rect.minX < band.range.upperBound : band.range.contains(rect.midX)
    }

    // MARK: Figures

    /// A figure's region, without its caption: the pictures nearest the caption, above it or
    /// else below, grown by the pictures stacked close and the short lines around them.
    static func figure(_ caption: Caption, pictures: [CGRect], used: inout Set<Int>, captions: [Caption], lines: [TextLayer.RawLine],
                       captionLines: Set<Int>, size: CGSize) -> CGRect? {
        let band = band(caption, size: size)
        let others = captions.filter { $0.lines != caption.lines }
        func pick(above: Bool) -> (box: CGRect, chosen: [Int])? {
            let candidates = pictures.indices.filter { index in
                let picture = pictures[index]
                guard !used.contains(index), inBand(picture, band) else { return false }
                if above { guard picture.maxY <= caption.box.minY + 4 else { return false } } else {
                    guard picture.minY >= caption.box.maxY - 4 else { return false }
                }
                let low = above ? picture.maxY : caption.box.maxY
                let high = above ? caption.box.minY : picture.minY
                return !others.contains { $0.box.midY > low && $0.box.midY < high && inBand($0.box, band) }
            }
            func distance(_ index: Int) -> CGFloat { above ? caption.box.minY - pictures[index].maxY : pictures[index].minY - caption.box.maxY }
            guard let nearest = candidates.min(by: { distance($0) < distance($1) }), distance(nearest) < size.height * 0.15 else { return nil }
            var chosen = [nearest]
            var box = pictures[nearest]
            // Panels stacked further away, and the short lines around them, as a panel's label
            // between two panels, which bridges them.
            var grew = true
            var rounds = 0
            while grew && rounds < 10 {
                grew = false
                rounds += 1
                for index in candidates where !chosen.contains(index) {
                    let picture = pictures[index]
                    let gap = above ? box.minY - picture.maxY : picture.minY - box.maxY
                    if gap < 24 || (picture.minY < box.maxY && picture.maxY > box.minY) {
                        chosen.append(index)
                        box = box.union(picture)
                        grew = true
                    }
                }
                for (index, line) in lines.enumerated() where !captionLines.contains(index) {
                    let rect = line.rect
                    if rect.width > size.width / 3 || box.contains(rect) || !inBand(rect, band) { continue }
                    let beyond = above ? rect.midY > caption.box.minY : rect.midY < caption.box.maxY
                    if box.insetBy(dx: -8, dy: -8).intersects(rect) && !beyond {
                        box = box.union(rect)
                        grew = true
                    }
                }
            }
            // Text between the pictures and the caption, as panels' labels, is the figure's.
            for (index, line) in lines.enumerated() where !captionLines.contains(index) {
                let rect = line.rect
                let between = above ? rect.minY >= box.maxY - 2 && rect.maxY <= caption.box.minY + 2
                    : rect.minY >= caption.box.maxY - 2 && rect.maxY <= box.minY + 2
                if between && rect.minX >= box.minX - 8 && rect.maxX <= box.maxX + 8 { box = box.union(rect) }
            }
            return (box, chosen)
        }
        guard let found = pick(above: true) ?? pick(above: false) else { return nil }
        used.formUnion(found.chosen)
        return found.box
    }

    /// A figure with no picture near its caption, as a chart whose bars carry their values or a
    /// heatmap's cells, which are no picture: the shapes the page draws nearest its caption, in
    /// its column, above it or else below, within 15% of the page, joined within 6 pt, 1% of the
    /// page or more, with no running text inside.
    static func figure(_ caption: Caption, shapes: [CGRect], captions: [Caption], lines: [TextLayer.RawLine], captionLines: Set<Int>,
                       size: CGSize) -> CGRect? {
        let band = band(caption, size: size)
        let others = captions.filter { $0.lines != caption.lines }
        for above in [true, false] {
            // As far as the next caption on that side, and half the page.
            let stop = others.filter { inBand($0.box, band) && (above ? $0.box.maxY <= caption.box.minY : $0.box.minY >= caption.box.maxY) }
                .map { above ? $0.box.maxY : $0.box.minY }
            let edge = above ? max(stop.max() ?? 0, caption.box.minY - size.height / 2) : min(stop.min() ?? size.height, caption.box.maxY + size.height / 2)
            let near = Array(shapes.lazy.filter { shape in
                inBand(shape, band) && (above ? shape.maxY <= caption.box.minY + 4 && shape.minY >= edge : shape.minY >= caption.box.maxY - 4 && shape.maxY <= edge)
            }.prefix(2_000))
            func distance(_ shape: CGRect) -> CGFloat { above ? caption.box.minY - shape.maxY : shape.minY - caption.box.maxY }
            guard let seed = near.min(by: { distance($0) < distance($1) }), distance(seed) < size.height * 0.15 else { continue }
            var box = seed
            var joined = 1
            var grew = true
            var rounds = 0
            while grew && rounds < 50 {
                grew = false
                rounds += 1
                for shape in near where !box.contains(shape) && box.insetBy(dx: -6, dy: -6).intersects(shape) {
                    box = box.union(shape)
                    joined += 1
                    grew = true
                }
            }
            // Running text: lines of words half as wide as the shapes or more; a legend's entries are short.
            let prose = lines.indices.filter { index in
                !captionLines.contains(index) && share(of: lines[index].rect, inside: box) >= 0.6 && lines[index].rect.width >= 0.5 * box.width
                    && Self.prose(lines[index].text)
            }
            guard joined >= 2, box.width * box.height >= 0.01 * size.width * size.height, prose.count < 2 else { continue }
            // The labels around it, as a chart's ticks and title.
            for (index, line) in lines.enumerated() where !captionLines.contains(index) {
                let rect = line.rect
                let beyond = above ? rect.midY > caption.box.minY : rect.midY < caption.box.maxY
                if rect.width <= size.width / 3, inBand(rect, band), !beyond, box.insetBy(dx: -8, dy: -8).intersects(rect) { box = box.union(rect) }
            }
            return box
        }
        return nil
    }

    // MARK: Tables

    /// A table's rules, from the first within 30 pt of its caption, on the side where that one
    /// is nearer, as captions stand above tables in most styles and below in some, until a gap
    /// of 30% of the page, another caption or two lines of running text: two at least, with text
    /// between the first and the last.
    static func table(_ caption: Caption, rules: [CGRect], lines: [TextLayer.RawLine], captions: [Caption], size: CGSize) -> CGRect? {
        let band = band(caption, size: size)
        // A line of running text: five words or more of letters alone, most of the line's. A row as
        // "Global batch size 512" or "CRAFT Abstract 2D objects, collisions ✓ 1,983 16.0 0.053" in
        // the body's size is none.
        func sentence(_ line: TextLayer.RawLine) -> Bool {
            let tokens = line.text.split(whereSeparator: \.isWhitespace)
            let words = tokens.filter { token in
                let word = token.trimmingCharacters(in: .punctuationCharacters)
                return word.count >= 2 && word.allSatisfy(\.isLetter)
            }.count
            return words >= 5 && Double(words) >= 0.6 * Double(tokens.count)
        }
        let flat = rules.filter { $0.width > 20 && $0.width > $0.height }
        // In a caption's column, a rule across both columns counts too.
        let inside = flat.filter {
            inBand($0, band) || (!band.spanning && $0.width > size.width * 0.5 && $0.minX < band.range.upperBound && $0.maxX > band.range.lowerBound)
        }
        let others = captions.filter { $0.lines != caption.lines }
        let captionLines = Set(captions.flatMap(\.lines))
        func chain(below: Bool) -> (box: CGRect, gap: CGFloat, count: Int)? {
            let side = inside.filter { below ? $0.minY >= caption.box.maxY - 2 : $0.maxY <= caption.box.minY + 2 }
                .sorted { below ? $0.minY < $1.minY : $0.maxY > $1.maxY }
            guard let first = side.first else { return nil }
            let firstGap = below ? first.minY - caption.box.maxY : caption.box.minY - first.maxY
            guard firstGap < 30 else { return nil }
            // The page's running text, outside the rules on this side and every caption, which is
            // often in a table's size: on a page that holds little but tables and figures, there is
            // none, and their rows are not taken for it.
            let span = side.reduce(CGRect.null) { $0.union($1) }
            let body = lines.indices.filter { index in
                let rect = lines[index].rect
                let under = rect.midY > span.minY && rect.midY < span.maxY && rect.minX < span.maxX && span.minX < rect.maxX
                return !under && !captionLines.contains(index) && rect.height > 0 && sentence(lines[index])
            }
            let usual = body.isEmpty ? nil : TextLayer.median(body.map { lines[$0].rect.height })
            var box = first
            var count = 1
            for rule in side.dropFirst() {
                let gap = below ? rule.minY - box.maxY : box.minY - rule.maxY
                if gap > size.height * 0.3 { break }
                let low = below ? box.maxY : rule.maxY
                let high = below ? rule.minY : box.minY
                if others.contains(where: { $0.box.midY > low && $0.box.midY < high && $0.box.maxX > box.minX && $0.box.minX < box.maxX }) { break }
                // Running text between, as a paragraph above a rule under the page's footnotes,
                // ends the table: two lines of it across most of the table's width, in another size
                // than the table's rows so far, or, with none yet, in the size of the page's running
                // text. A table of sentences, as prompts, sets them as its rows.
                let rows = lines.filter { $0.rect.midY > box.minY - 2 && $0.rect.midY < box.maxY + 2 && $0.rect.minX < box.maxX && box.minX < $0.rect.maxX }
                let row = rows.isEmpty ? nil : TextLayer.median(rows.map(\.rect.height))
                let between = lines.filter { line in
                    let height = line.rect.height
                    let foreign = row.map { abs(height - $0) > 0.08 * $0 } ?? usual.map { abs(height - $0) <= 0.1 * $0 } ?? false
                    return line.rect.midY > low && line.rect.midY < high && line.rect.width >= 0.6 * box.width && foreign
                        && line.rect.minX < box.maxX && box.minX < line.rect.maxX && sentence(line)
                }
                if between.count >= 2 { break }
                box = box.union(rule)
                count += 1
            }
            return (box, firstGap, count)
        }
        let options = [chain(below: true), chain(below: false)].compactMap { $0 }.filter { option in
            option.count >= 2 && lines.contains { share(of: $0.rect, inside: option.box.insetBy(dx: -2, dy: 0)) >= 0.6 }
        }
        return options.min { $0.gap < $1.gap }?.box
    }

    // MARK: Equations

    /// Numbered equations: a line whose number stands apart at its end, or alone, with the rest
    /// of its row and the lines of maths stacked above and below it, in its column on a page of
    /// two. A display stands about as far below its number's row as above it, so the lines below
    /// reach no further than those above, and a line of text after it, as "where …", stays out.
    static func equations(_ lines: [TextLayer.RawLine], visible: [String], taken: Set<Int>, size: CGSize) -> [Found] {
        let usual = max(TextLayer.median(lines.map(\.rect.height).filter { $0 > 0 }), 6)
        let mid = size.width / 2, margin = size.width * 0.02
        // Two columns: lines that end left of the middle and lines that start right of it.
        let columns = lines.filter { $0.rect.maxX < mid - margin }.count >= 5 && lines.filter { $0.rect.minX > mid + margin }.count >= 5
        let tagged = lines.indices.filter { lines[$0].tag != nil }
        var taken = taken
        var found: [Found] = []
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5 * min(a.height, b.height) }
        for index in lines.indices where !taken.contains(index) {
            guard let number = lines[index].tag, visible[index].trimmingCharacters(in: .whitespaces).hasSuffix(")") else { continue }
            let row = lines[index].rect
            // The text before the number is maths, not a sentence that ends in a reference.
            let before = visible[index].replacingOccurrences(of: #"\(\s*[^()]*\)\s*$"#, with: "", options: .regularExpression)
            if prose(before) { continue }
            func near(_ other: Int) -> Bool {
                let rect = lines[other].rect
                guard other != index, !taken.contains(other), lines[other].tag == nil, !prose(visible[other]) else { return false }
                // In its column, on a page of two, unless the number's line crosses the middle.
                if columns, row.minX > mid - margin || row.maxX < mid + margin, (rect.midX < mid) != (row.midX < mid) || (rect.minX < mid - margin && rect.maxX > mid + margin) {
                    return false
                }
                // Not on the row of another number.
                return !tagged.contains { $0 != index && sameRow(lines[$0].rect, rect) }
            }
            var members = [index]
            var box = row
            // The rest of its row, to the number's left, which PDFKit can give as lines of their own.
            for other in lines.indices where near(other) {
                let rect = lines[other].rect
                if sameRow(rect, row), rect.maxX <= row.maxX + 1, row.minX - rect.maxX <= size.width * 0.45 {
                    members.append(other)
                    box = box.union(rect)
                }
            }
            // The lines of maths above and below, as a fraction's numerator and denominator or a
            // sum's limits: close, and no running text.
            for up in [true, false] {
                let limit = up ? -CGFloat.infinity : box.maxY + max(row.minY - box.minY, 0) + 0.6 * usual
                var count = 0
                while count < 6 {
                    let candidates = lines.indices.filter { other in
                        let rect = lines[other].rect
                        guard !members.contains(other), rect.minX < box.maxX, box.minX < rect.maxX else { return false }
                        return up ? rect.midY < box.minY : rect.midY > box.maxY
                    }
                    guard let next = up ? candidates.max(by: { lines[$0].rect.maxY < lines[$1].rect.maxY })
                        : candidates.min(by: { lines[$0].rect.minY < lines[$1].rect.minY })
                    else { break }
                    let rect = lines[next].rect
                    let gap = up ? box.minY - rect.maxY : rect.minY - box.maxY
                    guard gap < 1.2 * usual, up || rect.minY < limit, near(next),
                          captionPattern.firstMatch(in: visible[next], range: NSRange(location: 0, length: (visible[next] as NSString).length)) == nil
                    else { break }
                    members.append(next)
                    box = box.union(rect)
                    count += 1
                }
            }
            // A number alone, with no maths beside, above or below it, numbers nothing found.
            if members.count == 1, visible[index].trimmingCharacters(in: .whitespaces).hasPrefix("(") { continue }
            taken.formUnion(members)
            found.append(Found(kind: .equation, number: number, box: box, caption: [], content: members.sorted()))
        }
        return found
    }

    /// Running text, not maths: two words or more of letters alone, most of the line's, or four,
    /// or a line that starts as the text after a display does, as "where ε is …".
    static func prose(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        if let first = tokens.first?.lowercased().trimmingCharacters(in: .punctuationCharacters),
           ["where", "with", "which", "here", "since", "thus", "hence", "then", "and", "for"].contains(first), tokens.count >= 2 {
            return true
        }
        let words = tokens.filter { token in
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            return word.count >= 2 && word.allSatisfy(\.isLetter)
        }.count
        return words >= 4 || (words >= 2 && Double(words) >= 0.6 * Double(tokens.count))
    }
}

extension Region {
    /// The text of its caption a reader sees, without its label, as "Table 3:".
    public func captionText(in layer: PageText) -> String {
        Output.caption(caption.filter(layer.blocks.indices.contains).map { layer.blocks[$0].visibleText }.joined(separator: " "))
    }

    /// The regions of a kind with a number, as `pdf crop --figure 4` names them, in the pages
    /// given, each with its page, counted from 0. Numbers match without regard to case.
    public static func find(_ kind: Kind, _ number: String, in pages: [(index: Int, layer: PageText)]) -> [(page: Int, region: Region)] {
        let wanted = number.trimmingCharacters(in: .whitespaces).lowercased()
        return pages.flatMap { page in
            (page.layer.regions ?? []).filter { $0.kind == kind && $0.number.lowercased() == wanted }.map { (page.index, $0) }
        }
    }

    /// The region a block of a page belongs to, as its caption or inside it.
    public static func holding(_ block: Int, in layer: PageText) -> Region? {
        layer.regions?.first { $0.caption.contains(block) || $0.blocks.contains(block) }
    }
}
