import Foundation

/// Running headers and footers, page numbers and publisher stamps: text at a page's edge that
/// belongs to the book or the journal, not to the page (FEATURES.md → F14, ROADMAP.md → M2.5).
/// `pdf read` sets them aside, counts them in its summary line and keeps them in place with
/// `--headers`; `pdf info` lists each once. They are judged when a page is read, against the
/// pages around it parsed so far, so a page's parse never depends on another page's.
public enum Furniture {
    public enum Kind: String, Codable, Sendable {
        case header, footer
        case stamp = "publisher-stamp"

        /// The label `--headers` shows in front of the block's text.
        public var label: String { self == .stamp ? "publisher stamp" : rawValue }
    }

    /// How many pages on each side a page's edges are compared with: running headers alternate
    /// between left and right pages, so each repeats two pages on, and pages of figures go
    /// without: at 2, a header of the NACA scan whose pages two away hold figures read as a
    /// heading. Only pages parsed so far count, and a read waits for none: a page that times
    /// out next door would hold it up. While the document parses, the read says it is
    /// provisional, as its headings can change too.
    public static let reach = 4

    /// The blocks of a page that are furniture, by their index on the page.
    ///
    /// A block is furniture when it sits at the page's edge, in its top 12%, its bottom 12% or
    /// its outer 10% at either side, holds three lines at most, and either repeats at the same
    /// edge of a page nearby, its letters the same (a page number changes, the words stay),
    /// or nearly the same when they are many, as OCR reads a running header a new way on each
    /// page; or is a page number, as "12", "- 12 -", "Page 12 of 30" or "xii"; or is arXiv's
    /// stamp, set sideways in the margin of a paper's first page. A page number may also stand
    /// a little further in, within 15% of the edge, as the page's highest or lowest block: an
    /// old TeX paper sets it 87.6% down. What repeats at the top or the bottom is the page's
    /// outermost text there, within 2.5% of the page's highest or lowest block: a textbook's box
    /// headed "EXPLORING FURTHER", below the running header on two pages a page apart, is not.
    public static func find(_ page: PageText, near: [PageText]) -> [Int: Kind] {
        var found: [Int: Kind] = [:]
        let others = near.map { edges($0) }
        let highest = page.blocks.indices.min { page.blocks[$0].box.y < page.blocks[$1].box.y }
        let lowest = page.blocks.indices.max {
            page.blocks[$0].box.y + page.blocks[$0].box.height < page.blocks[$1].box.y + page.blocks[$1].box.height
        }
        for (index, block) in page.blocks.enumerated() {
            let text = block.visibleText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 200, block.lines.count <= 3 else { continue }
            if text.range(of: pageNumber, options: [.regularExpression, .caseInsensitive]) != nil {
                if index == highest && block.box.y + block.box.height <= 0.15 {
                    found[index] = .header
                    continue
                }
                if index == lowest && block.box.y >= 0.85 {
                    found[index] = .footer
                    continue
                }
            }
            guard let zone = zone(block) else { continue }
            if text.range(of: arXivStamp, options: .regularExpression) != nil {
                found[index] = .stamp
                continue
            }
            if zone != .stamp, text.range(of: pageNumber, options: [.regularExpression, .caseInsensitive]) != nil {
                found[index] = zone
                continue
            }
            let key = letters(text)
            guard key.count >= 3 else { continue }
            if zone == .header, let highest, block.box.y > page.blocks[highest].box.y + 0.025 { continue }
            if zone == .footer, let lowest,
                block.box.y + block.box.height < page.blocks[lowest].box.y + page.blocks[lowest].box.height - 0.025
            {
                continue
            }
            if others.contains(where: { $0.contains { $0.zone == zone && alike($0.key, key) } }) { found[index] = zone }
        }
        return found
    }

    /// The furniture of each page asked for, counted from 0, by page and block, judged against
    /// the pages within `reach` of it in `layers`, the pages parsed so far.
    public static func find(pages: [Int], in layers: [Int: PageText]) -> [Int: [Int: Kind]] {
        var found: [Int: [Int: Kind]] = [:]
        for page in pages {
            guard let layer = layers[page] else { continue }
            let near = (page - reach...page + reach).filter { $0 != page }.compactMap { layers[$0] }
            let blocks = find(layer, near: near)
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

    /// The page's blocks at its edges, each with its zone and its letters.
    static func edges(_ page: PageText) -> [(zone: Kind, key: String)] {
        page.blocks.compactMap { block in
            guard let zone = zone(block), block.lines.count <= 3 else { return nil }
            let key = letters(block.visibleText)
            return key.count >= 3 && key.count <= 400 ? (zone, key) : nil
        }
    }

    /// Where on the page's edge a block sits: in its top 12%, its bottom 12%, or its outer 10%
    /// at either side, as a stamp set sideways in the margin. Nil inside. On the smoke set's
    /// papers the body starts 7–10% down and the page numbers sit 93–95% down.
    static func zone(_ block: TextBlock) -> Kind? {
        let box = block.box
        if box.y + box.height <= 0.12 { return .header }
        if box.y >= 0.88 { return .footer }
        if box.x + box.width <= 0.1 || box.x >= 0.9 { return .stamp }
        return nil
    }

    /// A block's letters, lowercased: the page numbers and the punctuation of a running header
    /// change from page to page, its words do not.
    static func letters(_ text: String) -> String {
        String(text.lowercased().filter(\.isLetter))
    }

    /// The same letters, or, for ten or more, nine in ten the same, by the edits that turn one
    /// into the other.
    static func alike(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 10, b.count >= 10, abs(a.count - b.count) * 10 <= max(a.count, b.count) else { return false }
        return distance(Array(a), Array(b)) * 10 <= max(a.count, b.count)
    }

    /// The edits, a letter added, dropped or changed, that turn one string into the other.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// A page number alone: "12", "- 12 -", "Page 12", "Page 12 of 30", "12 / 30" or "xii".
    static let pageNumber = #"^[\s\-–—|·•]*((page|p\.|pp\.)\s*)?(\d{1,4}|[ivxlcdm]{1,7})(\s*(of|/)\s*\d{1,4})?[\s\-–—|·•]*$"#

    /// arXiv's stamp: "arXiv:2609.23257v2 [cs.LG] 8 Oct 2026".
    static let arXivStamp = #"^arXiv:\d{4}\.\d{4,5}(v\d+)?\s*\["#
}
