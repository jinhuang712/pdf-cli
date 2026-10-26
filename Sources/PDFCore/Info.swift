import Foundation

/// A section of a document: from the file's bookmarks, or from a heading in its text.
public struct Section: Codable, Equatable, Sendable {
    public var title: String
    /// 1 for a top-level section.
    public var level: Int
    /// Counted from 1.
    public var page: Int
    /// The block the section starts at, counted from 1, when its page is parsed.
    public var block: Int?
    /// The last page the section reaches, counted from 1, once the page where the next section
    /// starts is parsed.
    public var lastPage: Int?
    /// About how many tokens the section's text takes, when all its pages are parsed.
    public var tokens: Int?
}

/// A cheap first look at a PDF (FEATURES.md → F2), from its facts and the pages parsed so far.
public struct Info: Encodable, Sendable {
    public var file: String
    public var title: String
    public var authors: String?
    public var year: String?
    public var doi: String?
    public var arXiv: String?
    public var notes: [String]
    public var pageCount: Int
    public var pagesParsed: Int
    public var columns: Int?
    public var pagesReadByOCR: Int
    /// Pages read from the file's own text layer.
    public var pagesFromTextLayer: Int
    public var tokens: Int
    /// "bookmarks" or "headings".
    public var sectionsFrom: String?
    public var sections: [Section]
    /// The counts, attachments and scripts below are nil or empty when the file's facts are
    /// unknown, and `factsUnknown` then says why.
    public var comments: Int?
    public var highlights: Int?
    public var formFields: Int?
    public var filledFields: Int?
    /// Annotations past the first `FactReader.maxAnnotations` of a page, or `maxAnnotationsInFile`, or past the time their read may
    /// take, which `pdf read` does not show.
    public var annotationsLeftOut: Int?
    public var attachments: [FileFacts.Attachment]
    public var moreAttachments: Int
    public var scripts: [FileFacts.Script]
    public var moreScripts: Int
    public var factsUnknown: String?
    /// True when the file holds more objects than one read visits, so the counts cover part of it.
    public var factsPartial: Bool
    public var flagged: [String]
    public var savedByPDFKit: Bool
    /// The running headers, footers, page numbers and publisher stamps that `pdf read` sets
    /// aside, each once, with the pages it stands on, in the pages parsed so far.
    public var runningHeaders: [RunningHeader]
    /// Every figure and table found in the pages parsed so far, in page order.
    public var figures: [Figure]
    /// How many footnotes, endnotes, author notes, margin notes and headnotes `pdf read` finds in
    /// the pages parsed so far, by kind; none that is zero.
    public var noteCounts: [String: Int]
    /// The lists of references found in the pages parsed so far, each with how many entries it holds.
    public var referenceLists: [ReferenceList]

    public struct ReferenceList: Encodable, Equatable, Sendable {
        public var entries: Int
        /// The page its heading stands on, counted from 1.
        public var page: Int
    }

    public struct Figure: Encodable, Equatable, Sendable {
        /// "figure" or "table".
        public var kind: String
        public var number: String
        /// Counted from 1.
        public var page: Int
        /// Its caption, without its label.
        public var caption: String
        /// For a table that runs over a page break: the page, counted from 1, where it goes on,
        /// and the page it goes on from (`TableLinks`).
        public var continuesOn: Int? = nil
        public var continuedFrom: Int? = nil
        /// One id for all the parts of such a table.
        public var table: String? = nil
    }

    public struct RunningHeader: Encodable, Equatable, Sendable {
        /// "header", "footer" or "publisher-stamp".
        public var kind: String
        /// Its text on the first page it stands on, without a page number at either end; empty
        /// for page numbers alone.
        public var text: String
        public var pages: Int
    }

    /// - Parameters:
    ///   - pages: the pages parsed so far, in order.
    ///   - metadataTitle: the title the file's metadata names, or empty.
    public init(file: String, pageCount: Int, pages: [Output.Page], facts: FileFacts?, metadataTitle: String,
                picks: [String: [Pick]] = [:], savedByPDFKit: Bool = false) {
        self.factsUnknown = facts == nil ? "the cache holds no facts for this version of the file" : facts?.failure
        let known = facts?.failure == nil ? facts : nil
        let facts = known ?? FileFacts()
        let layers = pages.map { ($0.index, $0.result.pageText) }
        let first = layers.first { $0.0 == 0 }?.1
        self.file = file
        self.title = Info.usable(metadataTitle) ? metadataTitle : (first.flatMap(Info.title) ?? URL(fileURLWithPath: file)
            .deletingPathExtension().lastPathComponent)
        // A metadata author of a few letters, as "pdf2" on the NACA scan, names a tool, not a person.
        self.authors = facts.author.flatMap { $0.filter(\.isLetter).count >= 4 ? $0 : nil }
        self.year = facts.year
        // What a reader can see: a DOI or a title planted out of sight is no fact of the file.
        let opening = layers.filter { $0.0 < 2 }.compactMap { $0.1?.blocks.map(\.visibleText).joined(separator: "\n") }
            .joined(separator: "\n")
        self.doi = Info.match(#"\b10\.\d{4,9}/[^\s"<>]+"#, in: opening).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]")) }
        self.arXiv = Info.match(#"arXiv:\d{4}\.\d{4,5}(v\d+)?"#, in: opening).map { String($0.dropFirst(6)) }
        // Footnotes, endnotes and the rest, judged against the pages parsed so far.
        let digests = Dictionary(layers.compactMap { index, layer in layer.map { (index, Notes.digest($0, index: index)) } }) { first, _ in first }
        let judged = Notes.resolve(pages: layers.map(\.0), digests: digests)
        var counts: [String: Int] = [:]
        var authors: [String] = []
        for index in judged.keys.sorted() {
            for entry in judged[index]!.entries {
                let key = entry.author ? "authorNotes" : entry.kind == .margin ? "marginNotes" : "\(entry.kind.rawValue)s"
                counts[key, default: 0] += 1
                if entry.author, authors.count < 3, let layer = layers.first(where: { $0.0 == index })?.1 {
                    let text = Notes.text(of: .footnote, blocks: entry.blocks, in: layer)
                    authors.append("[^\(entry.id ?? "")] " + (text.count > 160 ? String(text.prefix(160)) + "…" : text))
                }
            }
        }
        self.noteCounts = counts
        self.notes = authors.isEmpty ? Info.notes(first) : authors
        var references = ReferenceIndex(outline: facts.outline)
        for (index, layer) in layers { if let layer { references.add(index, layer) } }
        self.referenceLists = references.lists(notes: judged).map { ReferenceList(entries: $0.entries, page: $0.page) }
        self.pageCount = pageCount
        self.pagesParsed = pages.count
        self.columns = Info.columns(layers.compactMap { $0.1 })
        self.pagesReadByOCR = pages.filter { $0.result.method == "ocr" }.count
        self.pagesFromTextLayer = pages.filter { $0.result.status == .ok && $0.result.method != "ocr" }.count
        self.tokens = pages.reduce(0) { $0 + Output.tokens($1.result.text) }
        let complete = pages.count == pageCount
        let furniture = Furniture.find(
            pages: pages.map(\.index),
            in: Dictionary(layers.compactMap { index, layer in layer.map { (index, $0) } }) { first, _ in first })
        self.runningHeaders = Info.runningHeaders(pages, furniture: furniture)
        let byPage = Dictionary(layers.compactMap { index, layer in layer.map { (index, $0) } }) { first, _ in first }
        self.figures = layers.flatMap { index, layer -> [Figure] in
            guard let layer else { return [] }
            return (layer.regions ?? []).enumerated().filter { $0.element.kind != .equation }.map { position, region in
                var figure = Figure(kind: region.kind.rawValue, number: region.number, page: index + 1, caption: region.captionText(in: layer))
                if region.kind == .table, let link = TableLinks.link(of: position, on: index, layer: { byPage[$0] }) {
                    figure.continuesOn = link.continuesOn
                    figure.continuedFrom = link.continuedFrom
                    if link.parts > 1 { figure.table = link.id }
                }
                return figure
            }
        }
        if !facts.outline.isEmpty {
            sectionsFrom = "bookmarks"
            sections = Info.sections(outline: facts.outline, pages: pages, pageCount: pageCount, complete: complete)
        } else {
            let found = Info.headings(pages, furniture: furniture)
            sectionsFrom = found.isEmpty ? nil : "headings"
            sections = Info.measure(found, pages: pages, pageCount: pageCount, complete: complete)
        }
        self.comments = known?.comments
        self.highlights = known?.highlights
        self.formFields = known?.formFields
        self.filledFields = known?.filledFields
        self.annotationsLeftOut = known.map(\.moreAnnotations).flatMap { $0 > 0 ? $0 : nil }
        self.attachments = facts.attachments
        self.moreAttachments = facts.moreAttachments
        self.scripts = facts.scripts
        self.moreScripts = facts.moreScripts
        self.factsPartial = facts.partial
        self.flagged = pages.compactMap { page in
            let status = Output.judge(page, picks: picks).quality.status
            return status == .ok ? nil : "p.\(page.index + 1) (\(status.rawValue))"
        }
        self.savedByPDFKit = savedByPDFKit
    }

    // MARK: Title, notes and layout

    /// A metadata title worth showing: not empty, and not a file name or a placeholder.
    static func usable(_ title: String) -> Bool {
        let lower = title.lowercased()
        guard title.count >= 4, !["untitled", "title", "document"].contains(lower) else { return false }
        if lower.hasPrefix("microsoft word - ") { return false }
        return ![".pdf", ".doc", ".docx", ".tex", ".dvi", ".indd", ".ps"].contains { lower.hasSuffix($0) }
    }

    /// The first page's title: the block in its upper part set in the tallest lines.
    static func title(_ page: PageText) -> String? {
        func height(_ block: TextBlock) -> Double {
            let heights = block.lines.map(\.box.height).sorted()
            return heights.isEmpty ? 0 : heights[heights.count / 2]
        }
        return page.blocks
            .filter { $0.box.y < 0.45 && $0.box.width > 0.1 && $0.visibleText.count >= 4 && $0.visibleText.count <= 300 }
            .max { height($0) < height($1) }?.visibleText
    }

    static func match(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    /// Author notes on the first page, such as the corresponding author or equal contribution.
    static func notes(_ page: PageText?) -> [String] {
        let pattern = #"(?i)(corresponding author|equal contribution|contributed equally|these authors)"#
        return (page?.blocks ?? []).filter { $0.hidden == nil }.flatMap(\.lines).map(\.text)
            .filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .prefix(3).map { $0.count > 160 ? String($0.prefix(160)) + "…" : $0 }
    }

    /// Two columns when most of the sampled pages hold paragraphs side by side.
    static func columns(_ pages: [PageText]) -> Int? {
        let sample = pages.count > 1 ? Array(pages.dropFirst().prefix(6)) : pages
        guard !sample.isEmpty else { return nil }
        let split = sample.filter { page in
            let body = page.blocks.filter { $0.lines.count >= 2 && $0.box.width < 0.48 }
            return body.filter { $0.box.x + $0.box.width <= 0.55 }.count >= 2 && body.filter { $0.box.x >= 0.45 }.count >= 2
        }
        return split.count * 2 >= sample.count ? 2 : 1
    }

    /// Each running header, footer and publisher stamp once, by its letters, or nearly the same
    /// letters as OCR misreads them, in the order they first stand; page numbers alone as one
    /// entry of each kind.
    static func runningHeaders(_ pages: [Output.Page], furniture: [Int: [Int: Furniture.Kind]]) -> [RunningHeader] {
        var found: [(header: RunningHeader, key: String)] = []
        for page in pages {
            guard let blocks = page.result.pageText?.blocks, let kinds = furniture[page.index] else { continue }
            for (index, kind) in kinds.sorted(by: { $0.key < $1.key }) where blocks.indices.contains(index) {
                let text = blocks[index].visibleText
                let alone = Furniture.pageNumber(text.trimmingCharacters(in: .whitespaces)) != nil
                let key = alone ? "" : Furniture.key(text)
                if let at = found.firstIndex(where: { $0.header.kind == kind.rawValue && ($0.key == key || Furniture.alike($0.key, key)) }) {
                    found[at].header.pages += 1
                } else {
                    let shown = alone ? "" : text.replacingOccurrences(of: #"^\s*\d+\s+|\s+\d+\s*$"#, with: "", options: .regularExpression)
                    found.append((RunningHeader(kind: kind.rawValue, text: shown, pages: 1), key))
                }
            }
        }
        return found.map(\.header)
    }

    // MARK: Sections

    /// The sections that headings in the text mark, with their sizes, for a file with no
    /// bookmarks, or bookmarks that lack the numbers an agent asks for.
    public static func textSections(_ pages: [Output.Page], pageCount: Int) -> [Section] {
        measure(headings(pages), pages: pages, pageCount: pageCount, complete: pages.count == pageCount)
    }

    /// Headings in the text: one-line blocks such as "2.1 Method" or "References". A running
    /// header, footer or publisher stamp (`Furniture`) is none, nor a line that repeats on three
    /// pages or more; a title of mostly digits or symbols is a chart's or a table's, and numbered
    /// headings must rise, so a table row such as "5 Italian 4–5" after "3.5" stays out.
    static func headings(_ pages: [Output.Page], furniture: [Int: [Int: Furniture.Kind]]? = nil) -> [Section] {
        let furniture =
            furniture
            ?? Furniture.find(
                pages: pages.map(\.index),
                in: Dictionary(
                    pages.compactMap { page in page.result.pageText.map { (page.index, $0) } }
                ) { first, _ in first })
        let numbered = #"^(\d{1,2}(\.\d{1,2}){0,3})\.?\s+\p{Lu}"#
        let named = #"(?i)^(abstract|introduction|related work|background|methods?|methodology|experiments?|results|discussion|conclusions?|limitations|acknowledge?ments?|references|bibliography|appendix(\s+[A-Z])?)$"#
        func plain(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
        func exact(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        // A footnote, an endnote or a margin note is no heading, though "1 Equal contribution" reads
        // as one; numbered headings that look like a list of endnotes but are none, as "1
        // Introduction" to "4 Discussion" on one page, stay headings.
        let digests = Dictionary(
            pages.compactMap { page in page.result.pageText.map { (page.index, Notes.digest($0, index: page.index)) } }
        ) { first, _ in first }
        let judged = digests.values.contains { !$0.notes.isEmpty } ? Notes.resolve(pages: pages.map(\.index), digests: digests) : [:]
        func noted(_ page: Output.Page, _ index: Int) -> Bool {
            judged[page.index]?.entries.contains { $0.blocks.contains(index) } == true
        }
        func nearEdge(_ block: TextBlock) -> Bool { block.box.y < 0.12 || block.box.y + block.box.height > 0.9 }
        // A running header repeats word for word, or, when it carries the page number, letter
        // for letter near the page's edge. A chapter's heading in the body, as "1 Introduction"
        // under the running header "Introduction 5", stays.
        var seen: [String: Set<Int>] = [:]
        var seenNearEdge: [String: Set<Int>] = [:]
        for page in pages {
            for block in page.result.pageText?.blocks ?? [] where block.lines.count == 1 {
                seen[exact(block.visibleText), default: []].insert(page.index)
                if nearEdge(block) { seenNearEdge[plain(block.visibleText), default: []].insert(page.index) }
            }
        }
        var found: [(section: Section, number: Int?)] = []
        for page in pages {
            // Until M2.5 a band at the page's top 7.5% and bottom 5% stood in for running headers,
            // as OCR misreads the NACA scan's a new way on each page, and it left out a real
            // heading set higher on a page with a small margin. `Furniture` matches misread
            // headers nearly letter for letter.
            for (index, block) in (page.result.pageText?.blocks ?? []).enumerated()
            where block.lines.count == 1 && block.visibleText.split(separator: " ").count <= 12
                && furniture[page.index]?[index] == nil && !noted(page, index)
            {
                let text = block.visibleText.trimmingCharacters(in: .whitespaces)
                guard (seen[exact(text)]?.count ?? 0) < 3,
                      !nearEdge(block) || (seenNearEdge[plain(text)]?.count ?? 0) < 3 else { continue }
                if let number = text.range(of: numbered, options: .regularExpression).map({ String(text[$0]) }) {
                    let label = String(number.split(separator: " ")[0])
                    let title = text.dropFirst(label.count)
                    let visible = title.filter { !$0.isWhitespace }
                    let letters = visible.filter(\.isLetter).count
                    guard letters * 10 >= visible.count * 6,
                          title.split(separator: " ").contains(where: { $0.filter(\.isLetter).count >= 3 }),
                          title.last?.isNumber != true else { continue }
                    let parts = label.split(separator: ".").compactMap { Int($0) }
                    found.append((Section(title: text, level: parts.count, page: page.index + 1, block: index + 1), parts.first))
                } else if text.range(of: named, options: .regularExpression) != nil {
                    found.append((Section(title: text, level: 1, page: page.index + 1, block: index + 1), nil))
                }
            }
        }
        // The longest run of numbered headings whose first numbers never fall.
        let numbers = found.enumerated().compactMap { position, item in item.number.map { (position, $0) } }
        var best: [Int] = Array(repeating: 1, count: numbers.count), back: [Int] = Array(repeating: -1, count: numbers.count)
        for i in numbers.indices {
            for j in 0..<i where numbers[j].1 <= numbers[i].1 && best[j] + 1 > best[i] {
                best[i] = best[j] + 1
                back[i] = j
            }
        }
        var keep = Set<Int>()
        var cursor = best.indices.max { best[$0] < best[$1] } ?? -1
        while cursor >= 0 {
            keep.insert(numbers[cursor].0)
            cursor = back[cursor]
        }
        return found.enumerated().filter { $0.element.number == nil || keep.contains($0.offset) }.map(\.element.section)
    }

    /// The bookmarks as sections, each placed at its block when its page is parsed, in page
    /// order: an outline can list a later page first. On one page the outline's own order
    /// stands, since the text's reading order can put a right column's heading before the left
    /// column's.
    static func sections(outline: [FileFacts.Section], pages: [Output.Page], pageCount: Int, complete: Bool) -> [Section] {
        measure(starts(outline: outline, pages: pages, pageCount: pageCount), pages: pages, pageCount: pageCount, complete: complete)
    }

    /// Where each bookmark's section starts, without its size: it needs only the pages the
    /// bookmarks point at, so a search can name a hit's section without decoding every page.
    public static func starts(outline: [FileFacts.Section], pages: [Output.Page], pageCount: Int) -> [Section] {
        let byIndex = Dictionary(pages.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = outline.filter { $0.page >= 0 && $0.page < pageCount }.enumerated().map { position, item in
            let block = byIndex[item.page]?.result.pageText.map { place(item, in: $0) }
            return (section: Section(title: item.title, level: item.level, page: item.page + 1, block: block), position: position)
        }
        return placed.sorted { ($0.section.page, $0.position) < ($1.section.page, $1.position) }.map(\.section)
    }

    /// The block a bookmark points at, counted from 1: a short block that spells the bookmark's
    /// title, with or without a number before it, as "5.2. Image Classification" for "Image
    /// Classification", the one nearest the bookmark's point when several do; else the block
    /// that starts nearest below the bookmark's point in its column. On a page of two columns,
    /// the height alone points into the wrong column.
    static func place(_ item: FileFacts.Section, in layer: PageText) -> Int {
        func plain(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
        func spellings(_ text: String) -> Set<String> {
            let label = #"^\s*(?:(?:[Cc]hapter|CHAPTER|[Ss]ection|SECTION|[Pp]art|PART|[Aa]ppendix|APPENDIX)\s+)?(?:\d+|[IVXLC]+|[A-Z])(?:\.\d+)*[.:)]?\s+"#
            return Set([plain(text), plain(text.replacingOccurrences(of: label, with: "", options: .regularExpression))])
                .subtracting([""])
        }
        let wanted = spellings(item.title)
        // A table row that names the section, as "1 DomainWiseInfer 65.72 64.49", is mostly digits.
        let matches = layer.blocks.enumerated().filter { _, block in
            let visible = block.visibleText.filter { !$0.isWhitespace }
            return block.lines.count <= 2 && visible.filter(\.isLetter).count * 2 >= visible.count
                && !spellings(block.visibleText).isDisjoint(with: wanted)
        }
        if let best = matches.min(by: { a, b in
            guard let top = item.top else { return a.offset < b.offset }
            return abs(a.element.box.y - top) < abs(b.element.box.y - top)
        }) {
            return best.offset + 1
        }
        let top = item.top ?? 0
        let candidates = layer.blocks.enumerated().filter { $0.element.box.y >= top - 0.03 }
        let inColumn = candidates.filter { candidate in
            guard let left = item.left else { return true }
            return left >= candidate.element.box.x - 0.03 && left <= candidate.element.box.x + candidate.element.box.width
        }
        let best = (inColumn.isEmpty ? candidates : inColumn).min { $0.element.box.y < $1.element.box.y }
        return (best?.offset ?? max(layer.blocks.count - 1, 0)) + 1
    }

    /// Gives each section its last page and, when every page it covers is parsed, its size. A
    /// section reaches to the next one at its level or above. Until the page where that one
    /// starts is parsed, neither is known.
    static func measure(_ sections: [Section], pages: [Output.Page], pageCount: Int, complete: Bool) -> [Section] {
        let byIndex = Dictionary(pages.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var measured = sections
        for (position, section) in sections.enumerated() {
            var next = stop(position, in: sections).map { (page: $0.page, block: $0.block) }
            if let found = next, found.block == nil {
                // A next section on a page that failed has no block: the section takes that
                // page whole, as a read by section does. On a page not parsed yet, it waits.
                guard byIndex[found.page - 1] != nil else { continue }
                next = (found.page + 1, 1)
            }
            let endPage = next.map { $0.block! <= 1 ? max($0.page - 1, section.page) : $0.page } ?? pageCount
            measured[position].lastPage = endPage
            var tokens = 0
            var known = true
            for page in section.page...max(endPage, section.page) {
                guard let parsed = byIndex[page - 1] else {
                    known = false
                    break
                }
                // A page that failed shows only its failure block, so it adds no text.
                guard let layer = parsed.result.pageText else { continue }
                for (index, block) in layer.blocks.enumerated() {
                    let number = index + 1
                    if page == section.page, let start = section.block, number < start { continue }
                    if let next, page == next.page, number >= (next.block ?? 1) { continue }
                    tokens += Output.tokens(block.visibleText)
                }
            }
            measured[position].tokens = known ? tokens : nil
        }
        return measured
    }

    /// The section a `--section` value names: its number, as in "2.1", or its title, matched
    /// whole, then at its start, then anywhere, ignoring case.
    public static func find(_ query: String, in sections: [Section]) -> Section? {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil {
            return sections.first { $0.title.lowercased().hasPrefix(wanted + " ") || $0.title.lowercased().hasPrefix(wanted + ". ") }
        }
        let titles = sections.map { section -> String in
            section.title.lowercased().replacingOccurrences(of: #"^\d+(\.\d+)*\.?\s+"#, with: "", options: .regularExpression)
        }
        if let index = titles.firstIndex(of: wanted) { return sections[index] }
        if let index = titles.firstIndex(where: { $0.hasPrefix(wanted) }) { return sections[index] }
        if let index = titles.firstIndex(where: { $0.contains(wanted) }) { return sections[index] }
        return nil
    }

    /// The section a block falls in: the one that starts last at or before it, the deeper one
    /// when two start at the same block. `page` counts from 1.
    public static func section(at page: Int, block: Int, in sections: [Section]) -> Section? {
        var best: Section?
        for section in sections where (section.page, section.block ?? 1) <= (page, block) {
            guard let current = best else {
                best = section
                continue
            }
            if (section.page, section.block ?? 1) >= (current.page, current.block ?? 1) { best = section }
        }
        return best
    }

    /// The section at which `section` ends: the next one at its level or above.
    public static func next(after section: Section, in sections: [Section]) -> Section? {
        guard let position = sections.firstIndex(of: section) else { return nil }
        return sections[(position + 1)...].first { $0.level <= section.level }
    }

    /// Where the section at `position` stops: where the next one at its level or above starts,
    /// or nil at the end of the file. When the text's reading order puts that one above it on
    /// their page, it stops at the end of its page, so it never ends before it starts. The
    /// block is nil while the next section's page is not parsed.
    public static func stop(_ position: Int, in sections: [Section]) -> (page: Int, block: Int?)? {
        let section = sections[position]
        guard let next = sections[(position + 1)...].first(where: { $0.level <= section.level }) else { return nil }
        if next.page == section.page, let start = section.block, let block = next.block, block <= start {
            return (section.page + 1, 1)
        }
        return (next.page, next.block)
    }

    // MARK: Text

    public func render() -> String {
        var head = [title]
        if let authors { head.append(authors) }
        if let year { head.append(year) }
        if let doi { head.append("doi:\(doi)") }
        if let arXiv { head.append("arXiv:\(arXiv)") }
        var lines = [head.joined(separator: " · ")]

        var layout = ["\(pageCount) page\(pageCount == 1 ? "" : "s")"]
        if let columns { layout.append(columns == 2 ? "2 columns" : "1 column") }
        layout.append("text layer on \(pagesFromTextLayer) page\(pagesFromTextLayer == 1 ? "" : "s")"
                      + (pagesReadByOCR > 0 ? ", OCR on \(pagesReadByOCR)" : ""))
        layout.append("~\(Info.thousands(tokens)) tokens" + (pagesParsed < pageCount ? " in the pages parsed so far" : ""))
        lines.append(layout.joined(separator: " · "))
        if !notes.isEmpty { lines.append("author notes: " + notes.joined(separator: " · ")) }
        let kinds = [("footnotes", "footnote"), ("endnotes", "endnote"), ("marginNotes", "margin note"), ("headnotes", "headnote")]
        let found = kinds.compactMap { key, name in noteCounts[key].map { "\($0) \(name)\($0 == 1 ? "" : "s")" } }
        if !found.isEmpty {
            lines.append(
                "notes read apart from the text: " + found.joined(separator: ", ")
                    + " (pdf read --notes end|inline|off; pdf note <pdf> ID)")
        }
        if !referenceLists.isEmpty {
            let entries = referenceLists.reduce(0) { $0 + $1.entries }
            let lists =
                referenceLists.count == 1
                ? "the list on p.\(referenceLists[0].page)"
                : "\(referenceLists.count) lists, on " + referenceLists.prefix(6).map { "p.\($0.page)" }.joined(separator: ", ")
                    + (referenceLists.count > 6 ? ", and \(referenceLists.count - 6) more" : "")
            lines.append("references: \(entries) entr\(entries == 1 ? "y" : "ies"), \(lists) (pdf ref <pdf> ID; pdf read --refs end)")
        }
        if !runningHeaders.isEmpty {
            let shown = runningHeaders.prefix(6).map { header -> String in
                let kind = header.kind == Furniture.Kind.stamp.rawValue ? "publisher stamp" : header.kind
                let text =
                    header.text.isEmpty
                    ? "page numbers"
                    : "\"" + (header.text.count > 60 ? String(header.text.prefix(59)) + "…" : header.text) + "\""
                return "\(text) (\(kind), \(header.pages) page\(header.pages == 1 ? "" : "s"))"
            }
            lines.append(
                "running headers and footers, set aside by pdf read: " + shown.joined(separator: ", ")
                    + (runningHeaders.count > 6 ? ", and \(runningHeaders.count - 6) more" : "") + " (pdf read --show headers)")
        }

        var counts: [String] = []
        if let comments, let highlights, let formFields, let filledFields {
            counts = ["comments: \(comments)", "highlights: \(highlights)",
                      "form fields: \(formFields)" + (formFields > 0 ? " (\(filledFields) filled)" : "")]
            if let annotationsLeftOut {
                counts.append(
                    "annotations pdf read leaves out, past its caps (\(Info.thousands(FactReader.maxAnnotations)) links and as many others a page, \(Info.thousands(FactReader.maxAnnotationsInFile)) a file, or the size kept) or as repeats: \(Info.thousands(annotationsLeftOut))"
                )
            }
            if factsPartial { counts.append("counted in part of the file, which holds more objects than one read visits") }
        }
        counts.append("flagged pages: " + (flagged.isEmpty ? "none" : flagged.prefix(12).joined(separator: ", ")
            + (flagged.count > 12 ? ", and \(flagged.count - 12) more" : "")))
        lines.append(counts.joined(separator: " · "))
        if let factsUnknown {
            lines.append("comments, highlights, form fields, attachments and scripts: unknown, \(factsUnknown)")
        } else {
            let files = attachments.map { file in
                file.name + " (" + [file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                                    file.page.map { "p.\($0 + 1)" }].compactMap { $0 }.joined(separator: ", ") + ")"
            } + (moreAttachments > 0 ? ["and \(moreAttachments) more"] : [])
            lines.append("attachments: " + (files.isEmpty ? "none" : files.joined(separator: ", ") + " · never opened"))
            let actions = scripts.map { script in
                "\(script.kind) on \(script.trigger)" + (script.page.map { " (p.\($0 + 1))" } ?? "") + ", \(script.detail)"
            } + (moreScripts > 0 ? ["and \(moreScripts) more"] : [])
            lines.append("scripts: " + (actions.isEmpty ? "none" : actions.joined(separator: "; ") + " · never run"))
        }
        if savedByPDFKit {
            lines.append("⚠ made or last saved by macOS PDFKit, as Preview saves: such a save can damage the text, and an earlier copy may read better")
        }
        if pagesParsed < pageCount {
            lines.append("provisional: \(pagesParsed) of \(pageCount) pages parsed so far; pdf info again shows the rest")
        }

        var shown = sections.filter { $0.level <= 2 }
        var cut = false
        if shown.count > Info.maxSectionRows {
            // A file with hundreds of bookmarks would fill the agent's context, 3,200 tokens for
            // 200 of them. A long table keeps to the top level where that holds 10 to 40 rows, as
            // a book's chapters; else to its first rows, as under a book's one root bookmark.
            let top = sections.map(\.level).min() ?? 1
            let level = sections.filter { $0.level == top }
            if level.count >= 10 && level.count <= Info.maxSectionRows {
                shown = level
            } else {
                cut = true
                shown = Array((level.count > Info.maxSectionRows ? level : shown).prefix(Info.maxSectionRows))
            }
        }
        if !shown.isEmpty {
            let titles = shown.map { String(repeating: "  ", count: $0.level - 1) + $0.title }
            let width = min(max(titles.map(\.count).max() ?? 0, 7), 60)
            var table = ["Section".padding(toLength: width + 3, withPad: " ", startingAt: 0) + "pages      tokens"
                         + (sectionsFrom == "headings" ? "   (from headings in the text)" : "   (from the file's bookmarks)")]
            for (section, title) in zip(shown, titles) {
                let pages = section.lastPage.map { $0 > section.page ? "p.\(section.page)–\($0)" : "p.\(section.page)" }
                    ?? "p.\(section.page)–…"
                let name = title.count > width ? String(title.prefix(width - 1)) + "…" : title
                table.append("  " + name.padding(toLength: width + 1, withPad: " ", startingAt: 0)
                             + pages.padding(toLength: 11, withPad: " ", startingAt: 0)
                             + (section.tokens.map { Info.thousands($0) } ?? "…"))
            }
            if sections.count > shown.count {
                let left = sections.count - shown.count
                table.append("  and \(left) \(cut ? "more" : "deeper") section\(left == 1 ? "" : "s"); pdf info --json lists them")
            }
            lines.append("")
            lines.append(table.joined(separator: "\n"))
        }
        if !figures.isEmpty {
            // As many rows as the sections may take, each caption cut to its first 70 characters.
            var table = ["Figures and tables" + (pagesParsed < pageCount ? " (in the pages parsed so far)" : "")]
            for figure in figures.prefix(Info.maxSectionRows) {
                let name = (figure.kind == "table" ? "tbl " : "fig ") + figure.number
                let caption = figure.caption.count > 70 ? String(figure.caption.prefix(69)) + "…" : figure.caption
                table.append(
                    "  " + name.padding(toLength: max(name.count + 1, 9), withPad: " ", startingAt: 0)
                        + "p.\(figure.page)".padding(toLength: 7, withPad: " ", startingAt: 0) + caption
                        + [figure.continuedFrom.map { " · continued from p.\($0)" }, figure.continuesOn.map { " · continues on p.\($0)" }]
                        .compactMap { $0 }.joined())
            }
            if figures.count > Info.maxSectionRows {
                table.append("  and \(figures.count - Info.maxSectionRows) more; pdf info --json lists them")
            }
            lines.append("")
            lines.append(table.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The most sections the table shows: a paper has 10 to 30 at its top two levels.
    static let maxSectionRows = 40

    /// "1.8k" for 1,800, "950" below a thousand.
    public static func thousands(_ value: Int) -> String {
        value < 1_000 ? "\(value)" : String(format: "%.1fk", Double(value) / 1_000)
    }
}
