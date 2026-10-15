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
    /// The last page the section reaches, counted from 1.
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
    public var tokens: Int
    /// "bookmarks" or "headings".
    public var sectionsFrom: String?
    public var sections: [Section]
    public var comments: Int
    public var highlights: Int
    public var formFields: Int
    public var filledFields: Int
    public var attachments: [FileFacts.Attachment]
    public var scripts: [FileFacts.Script]
    public var flagged: [String]
    public var savedByPDFKit: Bool

    /// - Parameters:
    ///   - pages: the pages parsed so far, in order.
    ///   - metadataTitle: the title the file's metadata names, or empty.
    public init(file: String, pageCount: Int, pages: [Output.Page], facts: FileFacts?, metadataTitle: String,
                picks: [String: [Pick]] = [:], savedByPDFKit: Bool = false) {
        let facts = facts ?? FileFacts()
        let layers = pages.map { ($0.index, $0.result.pageText) }
        let first = layers.first { $0.0 == 0 }?.1
        self.file = file
        self.title = Info.usable(metadataTitle) ? metadataTitle : (first.flatMap(Info.title) ?? URL(fileURLWithPath: file)
            .deletingPathExtension().lastPathComponent)
        // A metadata author of a few letters, as "pdf2" on the NACA scan, names a tool, not a person.
        self.authors = facts.author.flatMap { $0.filter(\.isLetter).count >= 4 ? $0 : nil }
        self.year = facts.year
        let opening = layers.filter { $0.0 < 2 }.compactMap { $0.1?.text }.joined(separator: "\n")
        self.doi = Info.match(#"\b10\.\d{4,9}/[^\s"<>]+"#, in: opening).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]")) }
        self.arXiv = Info.match(#"arXiv:\d{4}\.\d{4,5}(v\d+)?"#, in: opening).map { String($0.dropFirst(6)) }
        self.notes = Info.notes(first)
        self.pageCount = pageCount
        self.pagesParsed = pages.count
        self.columns = Info.columns(layers.compactMap { $0.1 })
        self.pagesReadByOCR = pages.filter { $0.result.method == "ocr" }.count
        self.tokens = pages.reduce(0) { $0 + Output.tokens($1.result.text) }
        let complete = pages.count == pageCount
        if !facts.outline.isEmpty {
            sectionsFrom = "bookmarks"
            sections = Info.sections(outline: facts.outline, pages: pages, pageCount: pageCount, complete: complete)
        } else {
            let found = Info.headings(pages)
            sectionsFrom = found.isEmpty ? nil : "headings"
            sections = Info.measure(found, pages: pages, pageCount: pageCount, complete: complete)
        }
        self.comments = facts.comments
        self.highlights = facts.highlights
        self.formFields = facts.formFields
        self.filledFields = facts.filledFields
        self.attachments = facts.attachments
        self.scripts = facts.scripts
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
            .filter { $0.box.y < 0.45 && $0.box.width > 0.1 && $0.text.count >= 4 && $0.text.count <= 300 }
            .max { height($0) < height($1) }?.text
    }

    static func match(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    /// Author notes on the first page, such as the corresponding author or equal contribution.
    static func notes(_ page: PageText?) -> [String] {
        let pattern = #"(?i)(corresponding author|equal contribution|contributed equally|these authors)"#
        return (page?.blocks ?? []).flatMap(\.lines).map(\.text)
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

    // MARK: Sections

    /// The sections that headings in the text mark, with their sizes, for a file with no
    /// bookmarks, or bookmarks that lack the numbers an agent asks for.
    public static func textSections(_ pages: [Output.Page], pageCount: Int) -> [Section] {
        measure(headings(pages), pages: pages, pageCount: pageCount, complete: pages.count == pageCount)
    }

    /// Headings in the text: one-line blocks such as "2.1 Method" or "References". A line that
    /// repeats on three pages or more is a running header, a title of mostly digits or symbols
    /// is a chart's or a table's, and numbered headings must rise, so a table row such as
    /// "5 Italian 4–5" after "3.5" stays out.
    static func headings(_ pages: [Output.Page]) -> [Section] {
        let numbered = #"^(\d{1,2}(\.\d{1,2}){0,3})\.?\s+\p{Lu}"#
        let named = #"(?i)^(abstract|introduction|related work|background|methods?|methodology|experiments?|results|discussion|conclusions?|limitations|acknowledge?ments?|references|bibliography|appendix(\s+[A-Z])?)$"#
        func plain(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
        var seen: [String: Set<Int>] = [:]
        for page in pages {
            for block in page.result.pageText?.blocks ?? [] where block.lines.count == 1 { seen[plain(block.text), default: []].insert(page.index) }
        }
        var found: [(section: Section, number: Int?)] = []
        for page in pages {
            // Running headers and footers sit in the page's top 7.5% and bottom 5%: on the NACA
            // scan a header starts 6.5% down, and OCR misreads it a new way on each page, so its
            // repeats go unseen. The highest heading on the arXiv samples starts 9.4% down.
            for (index, block) in (page.result.pageText?.blocks ?? []).enumerated()
            where block.lines.count == 1 && block.text.split(separator: " ").count <= 12
                && block.box.y >= 0.075 && block.box.y + block.box.height <= 0.95 {
                let text = block.text.trimmingCharacters(in: .whitespaces)
                guard (seen[plain(text)]?.count ?? 0) < 3 else { continue }
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

    /// The bookmarks as sections, each placed at its block when its page is parsed.
    static func sections(outline: [FileFacts.Section], pages: [Output.Page], pageCount: Int, complete: Bool) -> [Section] {
        let byIndex = Dictionary(pages.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = outline.filter { $0.page >= 0 && $0.page < pageCount }.map { item -> Section in
            let block = byIndex[item.page]?.result.pageText.map { place(item, in: $0) }
            return Section(title: item.title, level: item.level, page: item.page + 1, block: block)
        }
        return measure(placed, pages: pages, pageCount: pageCount, complete: complete)
    }

    /// The block a bookmark points at, counted from 1: a short block that spells the bookmark's
    /// title, as "5.2. Image Classification" for "Image Classification"; else the block that
    /// starts nearest below the bookmark's point in its column. On a page of two columns, the
    /// height alone points into the wrong column.
    static func place(_ item: FileFacts.Section, in layer: PageText) -> Int {
        func plain(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
        let wanted = plain(item.title)
        if !wanted.isEmpty, let index = layer.blocks.firstIndex(where: { block in
            block.lines.count <= 2 && plain(block.text).hasSuffix(wanted) && plain(block.text).count <= wanted.count + 12
        }) {
            return index + 1
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
    /// section reaches to the next one at its level or above.
    static func measure(_ sections: [Section], pages: [Output.Page], pageCount: Int, complete: Bool) -> [Section] {
        let byIndex = Dictionary(pages.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var measured = sections
        for (position, section) in sections.enumerated() {
            let next = sections[(position + 1)...].first { $0.level <= section.level }
            let endPage = next.map { ($0.block ?? 1) <= 1 ? max($0.page - 1, section.page) : $0.page } ?? pageCount
            measured[position].lastPage = endPage
            var tokens = 0
            var known = true
            for page in section.page...max(endPage, section.page) {
                guard let layer = byIndex[page - 1]?.result.pageText else {
                    known = false
                    break
                }
                for (index, block) in layer.blocks.enumerated() {
                    let number = index + 1
                    if page == section.page, let start = section.block, number < start { continue }
                    if let next, page == next.page, number >= (next.block ?? 1) { continue }
                    tokens += Output.tokens(block.text)
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

    /// The section after which `section` ends: the next one at its level or above.
    public static func next(after section: Section, in sections: [Section]) -> Section? {
        guard let position = sections.firstIndex(of: section) else { return nil }
        return sections[(position + 1)...].first { $0.level <= section.level }
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
        layout.append(pagesReadByOCR == 0 ? "text layer on every page parsed" : "\(pagesReadByOCR) pages read by OCR")
        layout.append("~\(Info.thousands(tokens)) tokens" + (pagesParsed < pageCount ? " in the pages parsed so far" : ""))
        lines.append(layout.joined(separator: " · "))
        if !notes.isEmpty { lines.append("notes: " + notes.joined(separator: " · ")) }

        var counts = ["comments: \(comments)", "highlights: \(highlights)",
                      "form fields: \(formFields)" + (formFields > 0 ? " (\(filledFields) filled)" : "")]
        counts.append("flagged pages: " + (flagged.isEmpty ? "none" : flagged.prefix(12).joined(separator: ", ")
            + (flagged.count > 12 ? ", and \(flagged.count - 12) more" : "")))
        lines.append(counts.joined(separator: " · "))
        let files = attachments.map { file in
            file.name + " (" + [file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                                file.page.map { "p.\($0 + 1)" }].compactMap { $0 }.joined(separator: ", ") + ")"
        }
        lines.append("attachments: " + (files.isEmpty ? "none" : files.joined(separator: ", ") + " · never opened"))
        let actions = scripts.map { script in
            "\(script.kind) on \(script.trigger)" + (script.page.map { " (p.\($0 + 1))" } ?? "") + ", \(script.detail)"
        }
        lines.append("scripts: " + (actions.isEmpty ? "none" : actions.joined(separator: "; ") + " · never run"))
        if savedByPDFKit {
            lines.append("⚠ made or last saved by macOS PDFKit, as Preview saves: such a save can damage the text, and an earlier copy may read better")
        }
        if pagesParsed < pageCount {
            lines.append("provisional: \(pagesParsed) of \(pageCount) pages parsed so far; pdf info again shows the rest")
        }

        let shown = sections.filter { $0.level <= 2 }
        if !shown.isEmpty {
            let titles = shown.map { String(repeating: "  ", count: $0.level - 1) + $0.title }
            let width = min(max(titles.map(\.count).max() ?? 0, 7), 60)
            var table = ["Section".padding(toLength: width + 2, withPad: " ", startingAt: 0) + "pages      tokens"
                         + (sectionsFrom == "headings" ? "   (from headings in the text)" : "   (from the file's bookmarks)")]
            for (section, title) in zip(shown, titles) {
                let pages = section.lastPage.map { $0 > section.page ? "p.\(section.page)–\($0)" : "p.\(section.page)" }
                    ?? "p.\(section.page)"
                let name = title.count > width ? String(title.prefix(width - 1)) + "…" : title
                table.append("  " + name.padding(toLength: width, withPad: " ", startingAt: 0)
                             + pages.padding(toLength: 11, withPad: " ", startingAt: 0)
                             + (section.tokens.map { Info.thousands($0) } ?? "…"))
            }
            if sections.count > shown.count { table.append("  and \(sections.count - shown.count) deeper sections; pdf info --json lists them") }
            lines.append("")
            lines.append(table.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "1.8k" for 1,800, "950" below a thousand.
    static func thousands(_ value: Int) -> String {
        value < 1_000 ? "\(value)" : String(format: "%.1fk", Double(value) / 1_000)
    }
}
