import Foundation

/// Running headers and footers, page numbers and publisher stamps: text at a page's edge that
/// belongs to the book or the journal, not to the page (FEATURES.md → F14, ROADMAP.md → M2.5).
/// `pdf read` sets them aside, counts them in its summary line and keeps them in place with
/// `--show headers`; `pdf info` lists each once. They are judged when a page is read, against the
/// pages around it parsed so far, so a page's parse never depends on another page's.
public enum Furniture {
    public enum Kind: String, Codable, Sendable {
        case header, footer
        case stamp = "publisher-stamp"

        /// The label `--show headers` shows in front of the block's text.
        public var label: String { self == .stamp ? "publisher stamp" : rawValue }
    }

    /// How many pages on each side a page's edges are compared with: running headers alternate
    /// between left and right pages, so each repeats two pages on, and pages of figures go
    /// without: at 2, a header of the NACA scan whose pages two away hold figures read as a
    /// heading. Only pages parsed so far count, and a read waits for none: a page that times
    /// out next door would hold it up. While the document parses, the read says it is
    /// provisional, as its headings can change too.
    public static let reach = 4

    /// A block at a page's edge that may be furniture.
    struct Edge: Codable, Equatable {
        var index: Int
        var zone: Kind
        /// Its letters and digits, lowercased, without a page number at either end.
        var key: String
        /// For a page number alone, its value.
        var number: Int?
        /// Whether it is arXiv's stamp, which is judged from its own text alone.
        var arXiv: Bool = false
    }

    /// What the judgement reads of a page: its label and its edge blocks, the few candidates.
    /// A search keeps it beside the index (`Store.edgeSummaries`), so it judges a hit's page, and
    /// the pages around it, without reading their layers (M2.26). It is a function of the page's
    /// layer alone, so it goes with the page's result.
    /// Raise it when the summary's contents change: a change to `edges`, `key`, `pageNumber` or
    /// the arXiv pattern. A stored summary of another version is made again (M2.26's review).
    public static let summaryVersion = 1

    public struct Summary: Codable, Equatable, Sendable {
        var v = Furniture.summaryVersion
        var label: String?
        var edges: [Edge]

        /// The stored form: JSON.
        public var stored: String {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        public init?(stored: String) {
            guard let data = stored.data(using: .utf8), let value = try? JSONDecoder().decode(Summary.self, from: data),
                value.v == Furniture.summaryVersion
            else { return nil }
            self = value
        }

        init(label: String?, edges: [Edge]) {
            self.label = label
            self.edges = edges
        }
    }

    /// The summary of a page's layer.
    public static func summary(of page: PageText) -> Summary {
        var list = edges(page)
        for (position, edge) in list.enumerated() where edge.zone == .stamp {
            let text = page.blocks[edge.index].visibleText.trimmingCharacters(in: .whitespaces)
            if text.range(of: arXivStamp, options: .regularExpression) != nil { list[position].arXiv = true }
        }
        return Summary(label: page.label, edges: list)
    }

    /// The blocks of a page that are furniture, by their index on the page. `index` is the
    /// page's, counted from 0, and `near` the pages around it with theirs.
    ///
    /// The candidates are the page's outermost text at its edges (`edges`). One is furniture when
    /// it repeats at the same edge of a page nearby, its letters and digits the same, or nine in
    /// ten alike for twenty or more, as OCR reads a running header a new way on each page, and
    /// on two pages for a short one, as "ENDNOTES" can head two pages of a report; or is a page
    /// number that agrees with the page's own, printed or by position, or with a page number
    /// nearby, at the top or the bottom; or is arXiv's stamp, set sideways in the margin.
    static func find(_ page: PageText, index: Int, near: [(index: Int, layer: PageText)]) -> [Int: Kind] {
        find(summary(of: page), index: index, near: near.map { (index: $0.index, summary: summary(of: $0.layer)) })
    }

    static func find(_ page: Summary, index: Int, near: [(index: Int, summary: Summary)]) -> [Int: Kind] {
        let others = near.map { (index: $0.index, edges: $0.summary.edges) }
        var found: [Int: Kind] = [:]
        for edge in page.edges {
            if edge.zone == .stamp, edge.arXiv {
                found[edge.index] = .stamp
            } else if let number = edge.number, edge.zone != .stamp {
                let own = page.label.flatMap(value) ?? index + 1
                let agrees =
                    number == own
                    || others.contains { other in
                        other.edges.contains { $0.zone == edge.zone && $0.number.map { number - $0 == index - other.index } == true }
                    }
                if agrees { found[edge.index] = edge.zone }
            } else if edge.key.count >= 3 {
                let matches = others.filter { $0.edges.contains { $0.zone == edge.zone && $0.number == nil && alike($0.key, edge.key) } }
                if matches.count >= (edge.key.count < 15 ? 2 : 1) { found[edge.index] = edge.zone }
            }
        }
        return found
    }

    /// The furniture of each page asked for, counted from 0, by page and block, judged against
    /// the pages within `reach` of it in `layers`, the pages parsed so far.
    public static func find(pages: [Int], in layers: [Int: PageText]) -> [Int: [Int: Kind]] {
        // Only the pages asked for and the ones around them are summarised.
        var summaries: [Int: Summary] = [:]
        for page in pages {
            for other in page - reach...page + reach where summaries[other] == nil {
                if let layer = layers[other] { summaries[other] = summary(of: layer) }
            }
        }
        return find(pages: pages, summaries: summaries)
    }

    /// The same from summaries: no layer is read.
    public static func find(pages: [Int], summaries: [Int: Summary]) -> [Int: [Int: Kind]] {
        var found: [Int: [Int: Kind]] = [:]
        for page in pages {
            guard let own = summaries[page] else { continue }
            let near = (page - reach...page + reach).filter { $0 != page }.compactMap { other in summaries[other].map { (index: other, summary: $0) }
            }
            let blocks = find(own, index: page, near: near)
            if !blocks.isEmpty { found[page] = blocks }
        }
        return found
    }

    /// The same, with the pages around them read from the cache: `keys` are the document's
    /// page keys, in page order.
    public static func find(pages: [Int], keys: [String], store: Store) throws -> [Int: [Int: Kind]] {
        let around = Set(pages.flatMap { max(0, $0 - reach)...max(0, min(keys.count - 1, $0 + reach)) }).filter(keys.indices.contains)
        let results = try store.results(keys: around.map { keys[$0] })
        var layers: [Int: PageText] = [:]
        for page in around { if let layer = results[keys[page]]?.pageText { layers[page] = layer } }
        return find(pages: pages, in: layers)
    }

    /// The page's candidates: blocks of three lines at most and 200 characters, in its top or
    /// bottom 12% or its outer 10% at a side, with no text a reader cannot see in them, at most
    /// the 4 nearest each edge.
    ///
    /// - At the top and the bottom, only the page's outermost text, within 2.5% of its highest
    ///   or lowest block: a textbook's box headed "EXPLORING FURTHER", below the running header
    ///   on two pages a page apart, is none, nor a chart's tick labels or a footnote's number.
    /// - A page number may stand a little further in, within 15% of the edge, as the page's
    ///   highest or lowest block: an old TeX paper sets it 87.6% down.
    /// - The side margin counts text set sideways only (a block taller than twice its width), and
    ///   a block that starts with a raised note marker, `^{2}`, is a footnote, never furniture.
    /// - A block that holds hidden text stays in the text, with its marker: set aside, a page
    ///   number with words planted after it hid them from the count of hidden text.
    /// - At most 4 an edge, so a page of a thousand blocks in its margins costs no more than a
    ///   page of four.
    /// - No block of a figure, a table or an equation: a table's header row repeats at the top of
    ///   each page of a long table.
    static func edges(_ page: PageText) -> [Edge] {
        let blocks = page.blocks
        guard let highest = blocks.map(\.box.y).min(), let lowest = blocks.map({ $0.box.y + $0.box.height }).max() else { return [] }
        var found: [Kind: [(edge: Edge, distance: Double)]] = [:]
        var left: [(edge: Edge, distance: Double)] = []
        var right: [(edge: Edge, distance: Double)] = []
        // A table's header row, repeated at the top of each page of a long table, is the table's.
        let inside = Set((page.regions ?? []).flatMap { $0.caption + $0.blocks })
        for (index, block) in blocks.enumerated() where !inside.contains(index) {
            let text = block.visibleText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 200, block.lines.count <= 3, block.hidden?.isEmpty ?? true else { continue }
            // A footnote starts with its raised marker, `^{2}`: the same note on each page, as
            // "Second note of page 1", is no footer (M2.22's review).
            if text.range(of: #"^\^\{[^}]{1,4}\}"#, options: .regularExpression) != nil { continue }
            let box = block.box
            let number = pageNumber(text)
            let top = box.y <= highest + 0.025 && box.y + box.height <= (number == nil ? 0.12 : 0.15)
            let bottom = box.y + box.height >= lowest - 0.025 && box.y >= (number == nil ? 0.88 : 0.85)
            let edge = Edge(index: index, zone: top ? .header : bottom ? .footer : .stamp, key: key(text), number: number)
            if top {
                found[.header, default: []].append((edge, box.y))
            } else if bottom {
                found[.footer, default: []].append((edge, 1 - box.y - box.height))
            } else if box.height < 2 * box.width {
                // The side margin holds text set sideways only, as arXiv's stamp: a margin
                // note, set upright, repeats a word on many pages and is the text's (M2.22's review).
                continue
            } else if box.x + box.width <= 0.1 {
                left.append((edge, box.x))
            } else if box.x >= 0.9 {
                right.append((edge, 1 - box.x - box.width))
            }
        }
        // A page number is one an edge: the outermost.
        func nearest(_ list: [(edge: Edge, distance: Double)]) -> [Edge] {
            var numbered = false
            return list.sorted { $0.distance < $1.distance }.prefix(4).compactMap { item in
                guard item.edge.number != nil else { return item.edge }
                defer { numbered = true }
                return numbered ? nil : item.edge
            }
        }
        return nearest(found[.header] ?? []) + nearest(found[.footer] ?? []) + nearest(left) + nearest(right)
    }

    /// A block's letters and digits, lowercased, without a page number at either end: a running
    /// header's page number and punctuation change from page to page, its words and other
    /// numbers do not. Digits stay: "Table B-1." and "Table B-2." head different tables.
    static func key(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: #"^\s*\d{1,5}\s+|\s+\d{1,5}\s*$"#, with: "", options: .regularExpression)
        return String(trimmed.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The same, or, for twenty or more, nine in ten the same, by the edits that turn one into
    /// the other.
    static func alike(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a.unicodeScalars)
        let y = Array(b.unicodeScalars)
        guard x.count >= 20, y.count >= 20 else { return false }
        let limit = max(x.count, y.count) / 10
        return abs(x.count - y.count) <= limit && within(x, y, limit: limit)
    }

    /// Whether at most `limit` edits, a character added, dropped or changed, turn one string
    /// into the other. Only the cells within `limit` of the diagonal count, and a row that
    /// exceeds it ends the search: on 200 characters, 40 steps a row, not 200.
    static func within(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) <= limit }
        let over = limit + 1
        var previous = (0...b.count).map { min($0, over) }
        var current = Array(repeating: over, count: b.count + 1)
        for i in 1...a.count {
            let low = max(1, i - limit)
            let high = min(b.count, i + limit)
            guard low <= high else { return false }
            current[0] = min(i, over)
            if low > 1 { current[low - 1] = over }
            var best = current[0]
            for j in low...high {
                let changed = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, changed, over)
                best = min(best, current[j])
            }
            if high < b.count { current[high + 1] = over }
            if best > limit { return false }
            swap(&previous, &current)
        }
        return previous[b.count] <= limit
    }

    /// A page number alone, as "12", "- 12 -", "Page 12", "Page 12 of 30", "12 / 30", "11841" or "xii",
    /// and its value. A roman numeral counts only in lowercase and well formed: "MIX", "Civil"
    /// and a drop cap "I" are words.
    static func pageNumber(_ text: String) -> Int? {
        let pattern = #"^[\s\-–—|·•]*(?:(?:page|p\.)\s*)?(\d{1,5}|[ivxlcdm]{1,7})(?:\s*(?:of|/)\s*\d{1,5})?[\s\-–—|·•]*$"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let token =
            String(text[match]).components(separatedBy: CharacterSet(charactersIn: "-–—|·•/ ")).first {
                !$0.isEmpty && $0.lowercased() != "page" && $0.lowercased() != "p." && $0.lowercased() != "of"
            } ?? ""
        return value(token)
    }

    /// A page label's value: its digits, or a lowercase roman numeral, well formed.
    static func value(_ label: String) -> Int? {
        if let number = Int(label), number >= 0 { return number }
        guard label == label.lowercased(),
            label.range(
                of: #"^m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$"#,
                options: .regularExpression) != nil, !label.isEmpty
        else { return nil }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var total = 0
        var last = 0
        for digit in label.reversed() {
            let value = values[digit] ?? 0
            total += value < last ? -value : value
            last = max(last, value)
        }
        return total
    }

    /// arXiv's stamp: "arXiv:2609.23257v2 [cs.LG] 8 Oct 2026".
    static let arXivStamp = #"^arXiv:\d{4}\.\d{4,5}(v\d+)?\s*\["#
}
