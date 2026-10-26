import Foundation

/// What links the parts of one table that runs over page breaks (FEATURES.md → F3, ROADMAP.md →
/// M3.2). Read from the table regions the parse stored, at read time, against the pages parsed
/// so far: nothing is stored, so a cache from before this task needs no new parse.
public struct TableLink: Codable, Equatable, Sendable {
    /// One id for all the parts, from the number and the first part's page: "table-3-p6".
    public var id: String
    /// This part's place among the parts found, counted from 1.
    public var part: Int
    /// How many parts are found in the pages parsed so far.
    public var parts: Int
    /// The page of each part, counted from 1.
    public var pages: [Int]
    /// The page, counted from 1, where this part goes on, and the page it goes on from.
    public var continuesOn: Int?
    public var continuedFrom: Int?
    /// The last part ends its page, yet nothing is linked to go on from it: the table may go on, in
    /// a part the parse did not find. The first part's caption says it goes on, yet nothing is
    /// linked before it.
    public var openAfter: Bool = false
    public var openBefore: Bool = false
}

/// Links a table to the one that goes on from it on the next page, only on strong evidence
/// (DESIGNS.md → "Decision: a table's parts are linked only on a continued caption and the same
/// place on both pages"). When any of it is missing, the tables stay apart and the output says
/// nothing about them.
///
/// Two table regions, A on page p and B on page p+1, are linked when all of this holds:
/// - both are tables with the same number;
/// - B's caption, as a reader sees it (never the text hidden from one), says it goes on, as
///   "Table 1 (continued)", or repeats A's caption in full;
/// - A ends in the bottom quarter of its page with no other figure or table below it, and B
///   starts in the top quarter of its page with none above it;
/// - A and B stand over the same columns of the page: the same left edge and width, within 4%
///   of the page;
/// - A has no other candidate for B, and B none for A (two tables of one number on a page).
public enum TableLinks {
    /// How near the page's bottom a table must end, and its top a continuation start, in fractions.
    static let bottomFrom = 0.75
    static let topUntil = 0.25
    /// How far the parts' left edges and widths may differ, in fractions of the page.
    static let tolerance = 0.04
    /// The longest chain followed, in pages.
    static let longest = 60

    /// The words by which a caption says it goes on. In brackets, the keyword alone or followed by
    /// "from", "on", "of" and the like and what they name: "(continued)", "(Continued from previous
    /// page)", never "(control vs. treatment)" or "[suite A]"; the keyword ends at a non-letter. Or
    /// after a dash, colon or period, or straight after the label, at the caption's end: "Table 1. Cont.",
    /// "TABLE 2 — Continued", "Table 3 continued". Chinese and Japanese: "（续）", "(続き)".
    static let continued: NSRegularExpression = {
        let word =
            #"(?:continued|continue|cont\.?|cont'd|continuation|fortgesetzt|fortsetzung|suite|continuación|continuazione|продолжение)(?!\p{L})"#
        let more = #"(?:\s+(?:from|on|of|von|de|di|du|desde|da|с)(?!\p{L})[^)\]）]*)?"#
        let pattern =
            #"[(（\[]\s*"# + word + more + #"\s*[)）\]]"# + #"|[(（\[]\s*(?:续|續|つづき|続き)表?\s*[)）\]]"#
            + #"|(?:[—–:.-]\s*|^\s*\p{L}+\.?\s*[\p{L}0-9.\-]+\s+)(?:continued|cont'd|cont\.)\s*\.?\s*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// The caption of a region as a reader sees it, label included.
    static func caption(_ region: Region, in layer: PageText) -> String {
        region.caption.filter(layer.blocks.indices.contains).map { layer.blocks[$0].visibleText }.joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func saysContinued(_ caption: String) -> Bool {
        continued.firstMatch(in: caption, range: NSRange(location: 0, length: (caption as NSString).length)) != nil
    }

    /// A caption's letters and digits, lowercased.
    static func squeezed(_ caption: String) -> String {
        String(caption.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether a table region is the page's lowest figure or table in its columns, and ends in the
    /// page's bottom quarter.
    static func endsPage(_ index: Int, in layer: PageText) -> Bool {
        guard let regions = layer.regions else { return false }
        let region = regions[index]
        guard region.kind == .table, region.box.y + region.box.height >= bottomFrom else { return false }
        return !regions.enumerated().contains { other, r in
            other != index && r.kind != .equation && overlap(r.box, region.box)
                && r.box.y + r.box.height > region.box.y + region.box.height + 0.01
        }
    }

    /// Whether a table region is the page's highest figure or table in its columns, and starts in
    /// the page's top quarter.
    static func startsPage(_ index: Int, in layer: PageText) -> Bool {
        guard let regions = layer.regions else { return false }
        let region = regions[index]
        guard region.kind == .table, region.box.y <= topUntil else { return false }
        return !regions.enumerated().contains { other, r in
            other != index && r.kind != .equation && overlap(r.box, region.box) && r.box.y < region.box.y - 0.01
        }
    }

    static func overlap(_ a: Box, _ b: Box) -> Bool {
        min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > 0.02
    }

    /// Whether B, on the page after A's, is a continuation of A.
    static func continues(_ a: Int, in first: PageText, _ b: Int, in second: PageText) -> Bool {
        guard let left = first.regions?[a], let right = second.regions?[b],
            Region.normalized(left.number).lowercased() == Region.normalized(right.number).lowercased(),
            endsPage(a, in: first), startsPage(b, in: second),
            abs(left.box.x - right.box.x) <= tolerance, abs(left.box.width - right.box.width) <= tolerance
        else { return false }
        let next = caption(right, in: second)
        if saysContinued(next) { return true }
        // A caption repeated whole on the next page: long enough to be no label alone.
        let again = squeezed(next)
        return again.count >= 16 && again == squeezed(caption(left, in: first))
    }

    /// The region on page `page + 1` that goes on from a table region, if exactly one does and
    /// nothing else claims it.
    static func successor(of region: Int, on page: Int, layer: (Int) -> PageText?) -> Int? {
        guard let first = layer(page), let second = layer(page + 1), let regions = second.regions else { return nil }
        let found = regions.indices.filter { continues(region, in: first, $0, in: second) }
        guard found.count == 1, let next = found.first else { return nil }
        let claimants = (first.regions ?? []).indices.filter { continues($0, in: first, next, in: second) }
        return claimants == [region] ? next : nil
    }

    /// The region on page `page - 1` that this one goes on from, if there is one.
    static func predecessor(of region: Int, on page: Int, layer: (Int) -> PageText?) -> Int? {
        guard page > 0, let before = layer(page - 1), let regions = before.regions else { return nil }
        return regions.indices.first { successor(of: $0, on: page - 1, layer: layer) == region }
    }

    /// All the parts of the table a region belongs to, in page order, as far as the pages `layer`
    /// gives are parsed (counted from 0).
    public static func chain(of region: Int, on page: Int, layer: (Int) -> PageText?) -> [(page: Int, region: Int)] {
        var parts = [(page: page, region: region)]
        while parts.count < longest, let last = parts.first, let before = predecessor(of: last.region, on: last.page, layer: layer) {
            parts.insert((last.page - 1, before), at: 0)
        }
        while parts.count < 2 * longest, let last = parts.last, let next = successor(of: last.region, on: last.page, layer: layer) {
            parts.append((last.page + 1, next))
        }
        return parts
    }

    /// The link of a table region, or nil when it has no other part and no caption saying it goes on
    /// from one.
    public static func link(of region: Int, on page: Int, layer: (Int) -> PageText?) -> TableLink? {
        guard layer(page)?.regions?[safe: region]?.kind == .table else { return nil }
        let parts = chain(of: region, on: page, layer: layer)
        guard let position = parts.firstIndex(where: { $0.page == page && $0.region == region }),
            let head = parts.first, let tail = parts.last, let headLayer = layer(head.page), let tailLayer = layer(tail.page)
        else { return nil }
        let openBefore = saysContinued(caption(headLayer.regions![head.region], in: headLayer))
        let openAfter = parts.count > 1 && endsPage(tail.region, in: tailLayer)
        guard parts.count > 1 || openBefore else { return nil }
        let name = Region.normalized(headLayer.regions![head.region].number).lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
        return TableLink(
            id: "table-\(name)-p\(head.page + 1)", part: position + 1, parts: parts.count, pages: parts.map { $0.page + 1 },
            continuesOn: position + 1 < parts.count ? parts[position + 1].page + 1 : nil,
            continuedFrom: position > 0 ? parts[position - 1].page + 1 : nil,
            openAfter: openAfter && position + 1 == parts.count, openBefore: openBefore && position == 0)
    }
}

/// The parsed pages of a file, read from the cache as a table's chain asks for them, and parsed
/// by `parse` when a chain's end shows that the page beyond it must be known.
public final class TablePages {
    private var layers: [Int: PageText?]
    private let keys: [String]
    private let store: Store?
    private let parse: (Int) -> Void

    /// - Parameters:
    ///   - known: layers already in hand, by page counted from 0.
    ///   - store: where the other parsed pages are read from; nil for none.
    ///   - parse: asked to parse one page, counted from 0, that is not parsed yet.
    public init(known: [Int: PageText], keys: [String] = [], store: Store? = nil, parse: @escaping (Int) -> Void = { _ in }) {
        self.layers = known.mapValues { $0 }
        self.keys = keys
        self.store = store
        self.parse = parse
    }

    public func layer(_ page: Int) -> PageText? {
        if let have = layers[page] { return have }
        guard let store, keys.indices.contains(page) else { return nil }
        let read = (try? store.results(keys: [keys[page]]))?[keys[page]]?.pageText
        layers[page] = .some(read)
        return read
    }

    /// Parses a page that is not parsed, once.
    func ask(_ page: Int) {
        guard store != nil, keys.indices.contains(page), layer(page) == nil else { return }
        parse(page)
        layers[page] = nil
        _ = layer(page)
        if layers[page] == nil { layers[page] = .some(nil) }
    }
}

extension TableLinks {
    /// The link of a table region on a page, counted from 0, with the pages beyond the ends of its
    /// chain parsed when a part ends the page or starts it with a caption that says it goes on.
    public static func link(of region: Int, on page: Int, in pages: TablePages) -> TableLink? {
        guard pages.layer(page)?.regions?[safe: region]?.kind == .table else { return nil }
        for _ in 0..<(3 * longest) {
            let parts = chain(of: region, on: page, layer: pages.layer)
            var grew = false
            if let last = parts.last, let layer = pages.layer(last.page), endsPage(last.region, in: layer), pages.layer(last.page + 1) == nil {
                pages.ask(last.page + 1)
                grew = pages.layer(last.page + 1) != nil
            }
            if let first = parts.first, let layer = pages.layer(first.page), startsPage(first.region, in: layer),
                saysContinued(caption(layer.regions![first.region], in: layer)), first.page > 0, pages.layer(first.page - 1) == nil
            {
                pages.ask(first.page - 1)
                grew = grew || pages.layer(first.page - 1) != nil
            }
            if !grew { break }
        }
        return link(of: region, on: page, layer: pages.layer)
    }

    /// The links of the table regions on the pages asked for, counted from 0, by page and region's
    /// position.
    public static func resolve(pages: [Int], in tablePages: TablePages) -> [Int: [Int: TableLink]] {
        var found: [Int: [Int: TableLink]] = [:]
        for page in pages {
            guard let own = tablePages.layer(page) else { continue }
            for index in (own.regions ?? []).indices where own.regions![index].kind == .table {
                if let link = link(of: index, on: page, in: tablePages) { found[page, default: [:]][index] = link }
            }
        }
        return found
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
