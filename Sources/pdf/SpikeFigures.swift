import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// M0.3b: finds figures and their captions with PDFKit and Core Graphics only
/// (no ML model). Captions come from the page text; figure areas come from the
/// drawing operators in the page's content stream.
struct SpikeFigures: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "figures",
        abstract: "Find figures, tables and captions from text and drawing operators, one JSON object per page."
    )

    @Argument(help: "Path to a PDF file.")
    var path: String

    @Option(help: "Pages to read, such as 2 or 1-3. Default: every page.")
    var pages: String?

    @Option(help: "Write a 150 dpi PNG per page with the boxes drawn on it into this folder.")
    var overlay: String?

    func run() throws {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else {
            throw ValidationError("PDFKit could not open \(path)")
        }
        let range = try parsePageRange(pages, pageCount: document.pageCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        if let overlay {
            try FileManager.default.createDirectory(atPath: overlay, withIntermediateDirectories: true)
        }
        let stem = url.deletingPathExtension().lastPathComponent

        for number in range {
            guard let page = document.page(at: number - 1) else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            let result = FigureFinder(page: page).run()
            let ms = milliseconds(since: start)
            let record = result.record(page: number, ms: ms)
            var line = try encoder.encode(record)
            line.append(0x0A)
            FileHandle.standardOutput.write(line)

            if let overlay {
                let file = URL(fileURLWithPath: overlay).appendingPathComponent("\(stem)-p\(number).png")
                try drawOverlay(page: page, result: result, to: file)
            }
        }
    }
}

/// Parses "2" or "1-3" into a page range within 1...pageCount.
func parsePageRange(_ text: String?, pageCount: Int) throws -> ClosedRange<Int> {
    guard let text else { return 1...max(pageCount, 1) }
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard let first = parts.first, first >= 1, parts.count <= 2 else {
        throw ValidationError("Pages must look like 2 or 1-3, within 1-\(pageCount).")
    }
    return first...min(parts.last ?? first, pageCount)
}

// MARK: - Drawing operators

/// One painted thing on the page, in PDF user space (y up).
struct Mark {
    enum Kind { case path, image, shading }
    var rect: CGRect
    var kind: Kind
}

/// Collects painted marks from a content stream. Tracks the CTM and a
/// rectangular clip through q / Q / cm / W.
final class MarkCollector {
    struct GState {
        var ctm: CGAffineTransform = .identity
        var clip: CGRect = .infinite
    }

    var state = GState()
    var stack: [GState] = []
    var pathBox: CGRect = .null
    var pendingClip = false
    var current: CGPoint = .zero
    var marks: [Mark] = []
    var depth = 0
    var table: CGPDFOperatorTableRef?

    func addPoint(_ x: CGFloat, _ y: CGFloat) {
        let p = CGPoint(x: x, y: y).applying(state.ctm)
        pathBox = pathBox.union(CGRect(origin: p, size: .zero))
    }

    func paint(_ painted: Bool) {
        if pendingClip, !pathBox.isNull {
            state.clip = state.clip.intersection(pathBox)
        }
        pendingClip = false
        if painted, !pathBox.isNull {
            record(pathBox, .path)
        }
        pathBox = .null
    }

    func record(_ rect: CGRect, _ kind: Mark.Kind) {
        var box = rect
        if !state.clip.isInfinite { box = box.intersection(state.clip) }
        if box.isNull { return }
        marks.append(Mark(rect: box, kind: kind))
    }

    func unitSquare() -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm)
    }

    static func from(_ info: UnsafeMutableRawPointer?) -> MarkCollector {
        Unmanaged<MarkCollector>.fromOpaque(info!).takeUnretainedValue()
    }

    func scan(page: CGPDFPage) -> [Mark] {
        let table = makeTable()
        self.table = table
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return marks
    }

    /// Runs a form XObject's content stream under the current state.
    func scanForm(_ formStream: CGPDFStreamRef, parent: CGPDFContentStreamRef) {
        guard depth < 8, let table, let dict = CGPDFStreamGetDictionary(formStream) else { return }
        var saved = state
        if let matrix = readMatrix(dict, "Matrix") { state.ctm = matrix.concatenating(state.ctm) }
        if let bbox = readRect(dict, "BBox") {
            state.clip = state.clip.intersection(bbox.applying(state.ctm))
        }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
        // A form without /Resources gets its own dictionary as a stand-in, so lookups fail cleanly.
        let stream = CGPDFContentStreamCreateWithStream(formStream, resources ?? dict, parent)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        depth += 1
        let savedStack = stack
        stack = []
        CGPDFScannerScan(scanner)
        stack = savedStack
        depth -= 1
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        swap(&saved, &state)
        pathBox = .null
    }

    private func makeTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let c = MarkCollector.from(info); c.stack.append(c.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let c = MarkCollector.from(info); if let s = c.stack.popLast() { c.state = s }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let c = MarkCollector.from(info)
            guard let v = popNumbers(scanner, 6) else { return }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            c.state.ctm = m.concatenating(c.state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let c = MarkCollector.from(info)
            guard let v = popNumbers(scanner, 2) else { return }
            c.addPoint(v[0], v[1]); c.current = CGPoint(x: v[0], y: v[1])
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let c = MarkCollector.from(info)
            guard let v = popNumbers(scanner, 2) else { return }
            c.addPoint(c.current.x, c.current.y); c.addPoint(v[0], v[1]); c.current = CGPoint(x: v[0], y: v[1])
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            let c = MarkCollector.from(info)
            guard let v = popNumbers(scanner, 6) else { return }
            c.addPoint(c.current.x, c.current.y)
            c.addPoint(v[0], v[1]); c.addPoint(v[2], v[3]); c.addPoint(v[4], v[5])
            c.current = CGPoint(x: v[4], y: v[5])
        }
        let fourPoint: CGPDFOperatorCallback = { scanner, info in
            let c = MarkCollector.from(info)
            guard let v = popNumbers(scanner, 4) else { return }
            c.addPoint(c.current.x, c.current.y); c.addPoint(v[0], v[1]); c.addPoint(v[2], v[3])
            c.current = CGPoint(x: v[2], y: v[3])
        }
        CGPDFOperatorTableSetCallback(table, "v", fourPoint)
        CGPDFOperatorTableSetCallback(table, "y", fourPoint)
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let c = MarkCollector.from(info)
            guard let v = popNumbers(scanner, 4) else { return }
            c.addPoint(v[0], v[1]); c.addPoint(v[0] + v[2], v[1] + v[3])
            c.current = CGPoint(x: v[0], y: v[1])
        }
        let painted: CGPDFOperatorCallback = { _, info in MarkCollector.from(info).paint(true) }
        for op in ["f", "F", "f*", "S", "s", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op, painted)
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in MarkCollector.from(info).paint(false) }
        let clip: CGPDFOperatorCallback = { _, info in MarkCollector.from(info).pendingClip = true }
        CGPDFOperatorTableSetCallback(table, "W", clip)
        CGPDFOperatorTableSetCallback(table, "W*", clip)
        CGPDFOperatorTableSetCallback(table, "sh") { _, info in
            let c = MarkCollector.from(info)
            if !c.state.clip.isInfinite { c.record(c.state.clip, .shading) }
        }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            let c = MarkCollector.from(info); c.record(c.unitSquare(), .image)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let c = MarkCollector.from(info)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dict, "Subtype", &subtype)
            let kind = subtype.map { String(cString: $0) } ?? ""
            if kind == "Image" {
                c.record(c.unitSquare(), .image)
            } else if kind == "Form" {
                c.scanForm(stream, parent: content)
            }
        }
        return table
    }
}

private func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGFloat](repeating: 0, count: count)
    for index in stride(from: count - 1, through: 0, by: -1) {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
        values[index] = value
    }
    return values
}

private func readNumbers(_ dict: CGPDFDictionaryRef, _ key: String) -> [CGFloat]? {
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dict, key, &array), let array else { return nil }
    var values: [CGFloat] = []
    for index in 0..<CGPDFArrayGetCount(array) {
        var value: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
        values.append(value)
    }
    return values
}

private func readMatrix(_ dict: CGPDFDictionaryRef, _ key: String) -> CGAffineTransform? {
    guard let v = readNumbers(dict, key), v.count == 6 else { return nil }
    return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
}

private func readRect(_ dict: CGPDFDictionaryRef, _ key: String) -> CGRect? {
    guard let v = readNumbers(dict, key), v.count == 4 else { return nil }
    return CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1])).standardized
}

// MARK: - Finding figures

struct TextLine {
    var range: NSRange
    var text: String
    var box: CGRect
}

struct Caption {
    var kind: String  // "figure" or "table"
    var number: String
    var text: String
    var box: CGRect
    var lineIndices: [Int]
}

struct Cluster {
    var box: CGRect
    var paths = 0
    var images = 0
    var used = false
}

struct FoundItem {
    var caption: Caption
    var box: CGRect
    var paths: Int
    var images: Int
}

struct FinderResult {
    var crop: CGRect
    var figures: [FoundItem]
    var tables: [FoundItem]
    var unpairedClusters: [Cluster]
    var unpairedCaptions: [Caption]
    var allCaptions: [Caption]
    var markCount: Int
    var ruleCount: Int
    var droppedCount: Int

    func fraction(_ r: CGRect) -> [Double] {
        let round3 = { (v: CGFloat) in (Double(v) * 1000).rounded() / 1000 }
        return [
            round3((r.minX - crop.minX) / crop.width),
            round3((crop.maxY - r.maxY) / crop.height),
            round3(r.width / crop.width),
            round3(r.height / crop.height),
        ]
    }

    func record(page: Int, ms: Double) -> FiguresPage {
        func item(_ f: FoundItem) -> FigureRecord {
            FigureRecord(
                number: f.caption.number, caption: String(f.caption.text.prefix(120)),
                captionBox: fraction(f.caption.box), box: fraction(f.box), paths: f.paths, images: f.images
            )
        }
        return FiguresPage(
            page: page, ms: (ms * 10).rounded() / 10,
            figures: figures.map(item), tables: tables.map(item),
            unpairedClusters: unpairedClusters.map { ClusterRecord(box: fraction($0.box), paths: $0.paths, images: $0.images) },
            unpairedCaptions: unpairedCaptions.map {
                CaptionRecord(kind: $0.kind, number: $0.number, caption: String($0.text.prefix(120)), captionBox: fraction($0.box))
            },
            marks: markCount, rules: ruleCount, dropped: droppedCount
        )
    }
}

struct FiguresPage: Encodable {
    let page: Int
    let ms: Double
    let figures: [FigureRecord]
    let tables: [FigureRecord]
    let unpairedClusters: [ClusterRecord]
    let unpairedCaptions: [CaptionRecord]
    let marks: Int
    let rules: Int
    let dropped: Int
}

struct FigureRecord: Encodable {
    let number: String
    let caption: String
    let captionBox: [Double]
    let box: [Double]
    let paths: Int
    let images: Int
}

struct ClusterRecord: Encodable {
    let box: [Double]
    let paths: Int
    let images: Int
}

struct CaptionRecord: Encodable {
    let kind: String
    let number: String
    let caption: String
    let captionBox: [Double]
}

struct FigureFinder {
    let page: PDFPage
    let crop: CGRect

    /// Marks closer than this (points) join the same cluster.
    let clusterGap: CGFloat = 8
    /// Clusters closer than this (points, vertically) join the same figure.
    let figureGap: CGFloat = 24
    /// A mark this thin (points) and at least `ruleLength` long is a rule, not a seed.
    let ruleThickness: CGFloat = 2
    let ruleLength: CGFloat = 10

    init(page: PDFPage) {
        self.page = page
        self.crop = page.bounds(for: .cropBox)
    }

    func run() -> FinderResult {
        let lines = textLines()
        var marks: [Mark] = []
        if let ref = page.pageRef { marks = MarkCollector().scan(page: ref) }
        let pageArea = crop.width * crop.height
        let captions = findCaptions(lines, marks: marks.map(\.rect).filter { $0.width * $0.height < 0.5 * pageArea })
        let captionLineSet = Set(captions.flatMap(\.lineIndices))

        // Filters: off-page, page-sized backgrounds, rules, empty.
        var seeds: [Mark] = []
        var rules: [CGRect] = []
        var dropped = 0
        for var mark in marks {
            mark.rect = mark.rect.intersection(crop)
            if mark.rect.isNull { dropped += 1; continue }
            let r = mark.rect
            if r.width * r.height > 0.5 * pageArea { dropped += 1; continue }
            if mark.kind == .path, min(r.width, r.height) <= ruleThickness {
                if max(r.width, r.height) >= ruleLength { rules.append(r) } else if max(r.width, r.height) < 0.5 { dropped += 1 } else { seeds.append(mark) }
                continue
            }
            seeds.append(mark)
        }

        var clusters = cluster(seeds)
        // Rules touching a cluster join it (axes, grid lines).
        for rule in rules {
            if let i = clusters.firstIndex(where: { $0.box.insetBy(dx: -2, dy: -2).intersects(rule) }) {
                clusters[i].box = clusters[i].box.union(rule)
                clusters[i].paths += 1
            }
        }
        clusters = mergeOverlapping(clusters, gap: clusterGap)
        // Tiny clusters (glyph-like paths, bullets, icons) are ignored.
        let isSmall = { (c: Cluster) in max(c.box.width, c.box.height) < 15 || c.box.width * c.box.height < 300 }
        let smallCount = clusters.filter(isSmall).count
        clusters.removeAll(where: isSmall)
        if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] != nil {
            for c in clusters { FileHandle.standardError.write("cluster \(c.box) paths=\(c.paths) images=\(c.images)\n".data(using: .utf8)!) }
            for r in rules { FileHandle.standardError.write("rule \(r)\n".data(using: .utf8)!) }
            for l in lines { FileHandle.standardError.write("line \(l.box.integral) \(l.text.prefix(40))\n".data(using: .utf8)!) }
            for c in captions { FileHandle.standardError.write("caption \(c.kind) \(c.number) \(c.box)\n".data(using: .utf8)!) }
        }

        var figures: [FoundItem] = []
        var tables: [FoundItem] = []
        var unpairedCaptions: [Caption] = []

        // Tables first, so their cell shading and rules are claimed.
        for caption in captions where caption.kind == "table" {
            if let box = tableBox(for: caption, rules: rules, clusters: clusters, captions: captions) {
                var paths = 0, images = 0
                // A cluster mostly inside the table (cell shading) belongs to it.
                let insideShare = { (r: CGRect) -> CGFloat in
                    let i = r.intersection(box.insetBy(dx: -4, dy: -4))
                    return i.isNull ? 0 : (i.width * i.height) / max(r.width * r.height, 1)
                }
                for i in clusters.indices where !clusters[i].used && insideShare(clusters[i].box) > 0.6 {
                    clusters[i].used = true; paths += clusters[i].paths; images += clusters[i].images
                }
                tables.append(FoundItem(caption: caption, box: box, paths: paths + rules.filter { box.insetBy(dx: -1, dy: -1).contains($0) }.count, images: images))
            } else {
                unpairedCaptions.append(caption)
            }
        }
        for caption in captions where caption.kind == "figure" {
            if let found = figureFor(caption, clusters: &clusters, captions: captions, lines: lines, skipLines: captionLineSet) {
                figures.append(found)
            } else {
                unpairedCaptions.append(caption)
            }
        }

        return FinderResult(
            crop: crop, figures: figures, tables: tables,
            unpairedClusters: clusters.filter { !$0.used }, unpairedCaptions: unpairedCaptions,
            allCaptions: captions, markCount: marks.count, ruleCount: rules.count, droppedCount: dropped + smallCount
        )
    }

    // MARK: Text

    func textLines() -> [TextLine] {
        guard let string = page.string else { return [] }
        let ns = string as NSString
        var lines: [TextLine] = []
        var start = 0
        func flush(_ end: Int) {
            defer { start = end + 1 }
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            let text = ns.substring(with: range)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  let selection = page.selection(for: range) else { return }
            let box = selection.bounds(for: page)
            guard !box.isEmpty else { return }
            lines.append(TextLine(range: range, text: text, box: box))
        }
        for i in 0..<ns.length {
            let u = ns.character(at: i)
            if u == 0x0A || u == 0x0D { flush(i) }
        }
        flush(ns.length)
        return lines
    }

    static let captionPattern = try! NSRegularExpression(
        pattern: #"^\s*(Figure|FIGURE|Fig\.|FIG\.|Table|TABLE)\s*([A-Z]?\d+)(\s?\(?[a-z]\)?)?\s*([:.|]|$)?"#
    )

    func findCaptions(_ lines: [TextLine], marks: [CGRect]) -> [Caption] {
        var captions: [Caption] = []
        var claimed = Set<Int>()
        for (index, line) in lines.enumerated() where !claimed.contains(index) {
            let ns = line.text as NSString
            guard let match = Self.captionPattern.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let word = ns.substring(with: match.range(at: 1))
            var number = ns.substring(with: match.range(at: 2))
            if match.range(at: 3).location != NSNotFound {
                number += ns.substring(with: match.range(at: 3)).filter(\.isLetter)
            }
            let hasPunct = match.range(at: 4).location != NSNotFound && match.range(at: 4).length > 0
            // An in-text reference that wrapped to a line start ("... as shown in\nFigure 1. We ...")
            // sits right under a wide body line that does not end a sentence.
            // The line above is found by position, not text order: PDFKit sometimes interleaves columns.
            let above = lines.filter {
                $0.box.minX < line.box.maxX && line.box.minX < $0.box.maxX && $0.box.midY > line.box.maxY
            }.min { $0.box.minY < $1.box.minY }
            if let prev = above {
                let gap = prev.box.minY - line.box.maxY
                let prevText = prev.text.trimmingCharacters(in: .whitespaces)
                let endsSentence = prevText.last.map { ".:!?".contains($0) } ?? true
                // A drawn rule between the two lines (a table's bottom rule) means the line above is not running text.
                let between = CGRect(x: line.box.minX, y: line.box.maxY - 0.5, width: line.box.width, height: max(prev.box.minY - line.box.maxY, 0) + 1)
                let ruled = marks.contains { $0.intersects(between) && $0.width >= 25 }
                if gap > -2, gap < line.box.height * 0.5, prev.box.width > crop.width * 0.3, !endsSentence, !ruled { continue }
            }
            if !hasPunct {
                // No ":" or "." after the number: accept only when the line starts a
                // block (clear gap above it) and the next word is capitalized, so
                // in-text references such as "Figure 3 shows" that wrap to a line start are skipped.
                let rest = ns.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
                guard let first = rest.first, first.isUppercase else { continue }
                if index > 0 {
                    let prev = lines[index - 1].box
                    let gap = prev.minY - line.box.maxY
                    let sameColumn = prev.minX < line.box.maxX && line.box.minX < prev.maxX
                    if sameColumn && gap < line.box.height * 0.6 { continue }
                }
            }
            // Extend to the caption paragraph: following lines that sit just below and overlap horizontally.
            var box = line.box
            var indices = [index]
            var text = line.text.trimmingCharacters(in: .whitespaces)
            // Lines are found by position, not text order, because PDFKit may interleave columns.
            let lineHeight = max(line.box.height, 6)
            let mid = crop.midX, margin = crop.width * 0.05
            let crossesMiddle = { (r: CGRect) in r.minX < mid - margin && r.maxX > mid + margin }
            let spanning = crossesMiddle(line.box)
            let sameRow = { (a: CGRect, b: CGRect) in min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5 * min(a.height, b.height) }
            let isCaptionStart = { (i: Int) in
                Self.captionPattern.firstMatch(in: lines[i].text, range: NSRange(location: 0, length: (lines[i].text as NSString).length)) != nil
            }
            while indices.count < 20 {
                let last = lines[indices.last!].box
                let free = lines.indices.filter { !indices.contains($0) && !claimed.contains($0) && !isCaptionStart($0) }
                // A fragment on the same row right next to the last line (PDFKit splits lines at inline math).
                let fragment = free.first { i in
                    let c = lines[i].box
                    let xGap = max(last.minX, c.minX) - min(last.maxX, c.maxX)
                    return sameRow(last, c) && xGap < 12 && (spanning || (c.midX < mid) == (line.box.midX < mid))
                }
                // Otherwise the nearest line just below that overlaps the caption horizontally.
                let below = free.filter { i in
                    let c = lines[i].box
                    let gap = last.minY - c.maxY
                    let overlap = min(box.maxX, c.maxX) - max(box.minX, c.minX)
                    return gap > -lineHeight * 0.5 && gap < lineHeight * 0.7 && overlap > 0.5 * min(box.width, c.width)
                }.max { lines[$0].box.maxY < lines[$1].box.maxY }
                guard let pick = fragment ?? below else { break }
                let c = lines[pick].box
                // A drawn mark (table rule, figure) between the last line and the next ends the caption.
                if fragment == nil {
                    let top = max(last.minY, c.maxY + 0.2), bottom = min(last.minY, c.maxY)
                    let band = CGRect(x: max(box.minX, c.minX), y: bottom, width: max(min(box.maxX, c.maxX) - max(box.minX, c.minX), 0), height: max(top - bottom, 0.2))
                    // Small inline marks (a coloured legend square inside the caption text) do not count.
                    if marks.contains(where: { $0.intersects(band) && !$0.contains(band) && $0.width >= min(25, band.width * 0.5) }) { break }
                }
                // Under a full-width caption, a one-column line with a partner in the other
                // column on the same row is body text, not the caption's last line.
                if fragment == nil, spanning, !crossesMiddle(c),
                   lines.indices.contains(where: { $0 != pick && !indices.contains($0) && sameRow(lines[$0].box, c) && (lines[$0].box.midX < mid) != (c.midX < mid) }) {
                    break
                }
                box = box.union(c)
                indices.append(pick)
                text += " " + lines[pick].text.trimmingCharacters(in: .whitespaces)
            }
            indices.forEach { claimed.insert($0) }
            let kind = word.lowercased().hasPrefix("tab") ? "table" : "figure"
            captions.append(Caption(kind: kind, number: number, text: text, box: box, lineIndices: indices))
        }
        return captions
    }

    // MARK: Clusters

    func cluster(_ marks: [Mark]) -> [Cluster] {
        var clusters = marks.map { m -> Cluster in
            var c = Cluster(box: m.rect)
            if m.kind == .image { c.images = 1 } else { c.paths = 1 }
            return c
        }
        clusters = mergeOverlapping(clusters, gap: clusterGap)
        return clusters
    }

    /// Repeatedly merges clusters whose boxes come within `gap` points of each other.
    func mergeOverlapping(_ input: [Cluster], gap: CGFloat) -> [Cluster] {
        var clusters = input.sorted { $0.box.minY < $1.box.minY }
        var changed = true
        while changed {
            changed = false
            var result: [Cluster] = []
            for c in clusters {
                var merged = c
                var i = 0
                while i < result.count {
                    if result[i].box.insetBy(dx: -gap, dy: -gap).intersects(merged.box) {
                        merged.box = merged.box.union(result[i].box)
                        merged.paths += result[i].paths
                        merged.images += result[i].images
                        result.remove(at: i)
                        changed = true
                    } else {
                        i += 1
                    }
                }
                result.append(merged)
            }
            clusters = result
        }
        return clusters
    }

    // MARK: Pairing

    /// The horizontal band a caption's figure must sit in: its column, or the whole page
    /// when the caption crosses the middle.
    func band(for caption: Caption) -> ClosedRange<CGFloat> {
        let mid = crop.midX
        let margin = crop.width * 0.05
        if caption.box.minX < mid - margin && caption.box.maxX > mid + margin { return crop.minX...crop.maxX }
        return caption.box.midX < mid ? crop.minX...mid : mid...crop.maxX
    }

    func inBand(_ r: CGRect, _ band: ClosedRange<CGFloat>, spanning: Bool) -> Bool {
        if spanning { return r.maxX > band.lowerBound && r.minX < band.upperBound }
        return band.contains(r.midX)
    }

    func figureFor(_ caption: Caption, clusters clusterList: inout [Cluster], captions: [Caption],
                   lines: [TextLine], skipLines: Set<Int>) -> FoundItem? {
        var clusters = clusterList
        defer { clusterList = clusters }
        let band = band(for: caption)
        let spanning = band.lowerBound == crop.minX && band.upperBound == crop.maxX
        let others = captions.filter { $0.box != caption.box }

        func pick(above: Bool) -> FoundItem? {
            // Nearest unused cluster on that side, with no other caption in between.
            let candidates = clusters.indices.filter { i in
                let c = clusters[i]
                guard !c.used, inBand(c.box, band, spanning: spanning) else { return false }
                if above { guard c.box.minY > caption.box.maxY - 4 else { return false } }
                else { guard c.box.maxY < caption.box.minY + 4 else { return false } }
                let lo = above ? caption.box.maxY : c.box.maxY
                let hi = above ? c.box.minY : caption.box.minY
                if others.contains(where: { $0.box.midY > lo && $0.box.midY < hi && inBand($0.box, band, spanning: true) && $0.box.midX >= band.lowerBound && $0.box.midX <= band.upperBound }) { return false }
                return true
            }
            let distance = { (i: Int) -> CGFloat in
                above ? clusters[i].box.minY - caption.box.maxY : caption.box.minY - clusters[i].box.maxY
            }
            guard let nearest = candidates.min(by: { distance($0) < distance($1) }),
                  distance(nearest) < crop.height * 0.15 else { return nil }
            var chosen = [nearest]
            var box = clusters[nearest].box
            // Grow with clusters stacked further away in the same band (sub-figures).
            // Alternates with growing over nearby short text lines (axis labels, legends,
            // sub-figure labels), so a panel label between two panels bridges them.
            var grew = true
            var rounds = 0
            while grew && rounds < 10 {
                grew = false
                rounds += 1
                for i in candidates where !chosen.contains(i) {
                    let c = clusters[i].box
                    let vertical = above ? (c.minY - box.maxY) : (box.minY - c.maxY)
                    let overlapsRows = c.minY < box.maxY && c.maxY > box.minY
                    if vertical < figureGap || overlapsRows {
                        chosen.append(i); box = box.union(c); grew = true
                    }
                }
                for (index, line) in lines.enumerated() where !skipLines.contains(index) {
                    if line.box.width > crop.width * 0.33 { continue }
                    if box.contains(line.box) { continue }
                    let near = box.insetBy(dx: -8, dy: -8).intersects(line.box)
                    let beyondCaption = above ? line.box.midY < caption.box.maxY : line.box.midY > caption.box.minY
                    if near && !beyondCaption { box = box.union(line.box); grew = true }
                }
            }
            // Text between the drawing and its caption (sub-figure labels) belongs to the figure.
            for (index, line) in lines.enumerated() where !skipLines.contains(index) {
                let between = above
                    ? (line.box.maxY <= box.minY + 2 && line.box.minY >= caption.box.maxY - 2)
                    : (line.box.minY >= box.maxY - 2 && line.box.maxY <= caption.box.minY + 2)
                let within = line.box.minX >= box.minX - 8 && line.box.maxX <= box.maxX + 8
                if between && within { box = box.union(line.box) }
            }
            var paths = 0, images = 0
            for i in chosen { clusters[i].used = true; paths += clusters[i].paths; images += clusters[i].images }
            return FoundItem(caption: caption, box: box, paths: paths, images: images)
        }
        return pick(above: true) ?? pick(above: false)
    }

    func tableBox(for caption: Caption, rules: [CGRect], clusters: [Cluster], captions: [Caption]) -> CGRect? {
        let band = band(for: caption)
        let spanning = band.lowerBound == crop.minX && band.upperBound == crop.maxX
        // Only horizontal rules chain a table; clusters (cell shading) are claimed afterwards
        // when they fall inside, so a figure right under a table is not swallowed.
        let things = rules.filter { $0.width > 20 && $0.width > $0.height }
        let inside = things.filter { inBand($0, band, spanning: spanning) || (spanning ? false : $0.width > crop.width * 0.5 && $0.minX < band.upperBound && $0.maxX > band.lowerBound) }
        let otherCaptions = captions.filter { $0.box != caption.box }

        func chain(below: Bool) -> (box: CGRect, gap: CGFloat)? {
            let side = inside.filter { below ? $0.maxY <= caption.box.minY + 2 : $0.minY >= caption.box.maxY - 2 }
                .sorted { below ? $0.maxY > $1.maxY : $0.minY < $1.minY }
            guard let first = side.first else { return nil }
            let firstGap = below ? caption.box.minY - first.maxY : first.minY - caption.box.maxY
            guard firstGap < 30 else { return nil }
            var box = first
            for r in side.dropFirst() {
                let gap = below ? box.minY - r.maxY : r.minY - box.maxY
                if gap > crop.height * 0.3 { break }
                let lo = below ? r.maxY : box.maxY
                let hi = below ? box.minY : r.minY
                if otherCaptions.contains(where: { $0.box.midY > lo && $0.box.midY < hi && $0.box.maxX > box.minX && $0.box.minX < box.maxX }) { break }
                box = box.union(r)
            }
            return (box, firstGap)
        }
        // Captions sit above tables in most styles and below in some (ACL): take the closer rule.
        let options = [chain(below: true), chain(below: false)].compactMap { $0 }
        return options.min { $0.gap < $1.gap }?.box
    }
}

// MARK: - Overlay

func drawOverlay(page: PDFPage, result: FinderResult, to file: URL) throws {
    let dpi = 150.0
    guard let image = render(page, dpi: dpi) else { throw ValidationError("Could not render page") }
    let width = image.width, height = image.height
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let crop = result.crop
    let scale = dpi / 72
    func toPixels(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - crop.minX) * scale, y: (r.minY - crop.minY) * scale, width: r.width * scale, height: r.height * scale)
    }
    func stroke(_ r: CGRect, _ color: (CGFloat, CGFloat, CGFloat), width lineWidth: CGFloat = 3, dashed: Bool = false) {
        context.setStrokeColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.9))
        context.setLineWidth(lineWidth)
        context.setLineDash(phase: 0, lengths: dashed ? [10, 6] : [])
        context.stroke(toPixels(r))
    }
    let figureColor: (CGFloat, CGFloat, CGFloat) = (0.85, 0.1, 0.1)   // red
    let tableColor: (CGFloat, CGFloat, CGFloat) = (0.1, 0.35, 0.9)    // blue
    let captionColor: (CGFloat, CGFloat, CGFloat) = (0.1, 0.65, 0.2)  // green
    let looseColor: (CGFloat, CGFloat, CGFloat) = (0.95, 0.55, 0.0)   // orange
    for f in result.figures { stroke(f.box, figureColor) }
    for t in result.tables { stroke(t.box, tableColor) }
    for c in result.allCaptions { stroke(c.box, captionColor, width: 2) }
    for c in result.unpairedClusters { stroke(c.box, looseColor, width: 2, dashed: true) }
    for c in result.unpairedCaptions { stroke(c.box, looseColor, width: 2) }

    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, output, nil)
    CGImageDestinationFinalize(destination)
}
