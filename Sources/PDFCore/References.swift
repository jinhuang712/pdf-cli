import Foundation

/// An entry of a document's list of references (FEATURES.md → F15, ROADMAP.md → M2.8).
public struct ReferenceEntry: Equatable, Sendable {
    /// How the document cites it: its number, as "12", its printed key, as "BK06", or its first
    /// author's surname and its year, as "Smith2020a"; for a list after the first, the list's
    /// number before it, as "2.12".
    public var id: String
    /// Counted from 0.
    public var page: Int
    /// Its blocks on its first page, counted from 0.
    public var blocks: [Int]
    /// Its words, without its label.
    public var text: String
    public var doi: String?
}

/// What `pdf read` shows of one page's citations and cross-references, judged against the
/// document: the raised markers that cite the list of references, which show as `[12]`, the
/// entries each block cites, and the pages that "Fig. 4" or "Section 3.2" point to.
public struct PageCitations: Equatable, Sendable {
    /// A raised marker that cites entries: what stands between its braces, as "12" or "3–5", and
    /// which of the block's raised markers with that token it is.
    public struct Raised: Equatable, Sendable {
        public var token: String
        public var index: Int
    }

    /// A mention of a figure, a table, an equation or a section, and the page it points to.
    public struct Pointer: Equatable, Sendable {
        /// The words as the text has them: "Fig. 4", "Eq. (5)", "Section 3.2".
        public var words: String
        /// Where they start in the block's visible text, in UTF-16 units.
        public var offset: Int
        /// Counted from 1.
        public var page: Int
    }

    public var raised: [Int: [Raised]] = [:]
    public var pointers: [Int: [Pointer]] = [:]
    /// The ids of the entries each block cites, in the order it cites them.
    public var cites: [Int: [String]] = [:]
    /// The entries the page's blocks cite, by id.
    public var entries: [String: ReferenceEntry] = [:]

    public init() {}

    public var isEmpty: Bool { raised.isEmpty && pointers.isEmpty && cites.isEmpty }
}

/// Lists of references, the citations that lead to their entries, and cross-references, found by
/// rules from the pages parsed so far, as notes are (`Notes.resolve`): a heading "References"
/// starts a list, its entries are numbered, keyed or by author and year, and a citation leads to
/// the nearest list after it whose entries it names.
enum References {
    // MARK: Patterns

    /// A heading that opens a list of references.
    static let heading = try! NSRegularExpression(
        pattern:
            #"^(?:[0-9]{1,2}\.?\s+|[A-Z]\.\s+|[IVX]{1,4}\.\s+)?(?:references?|bibliography|works cited|literature cited|cited literature|reference list|references and notes|notes and references|literature|selected bibliography)\s*[:.]?$"#,
        options: [.caseInsensitive])
    /// A heading of another part, which ends a list: an appendix, supplementary material, the
    /// statements journals print after the references.
    static let stop = try! NSRegularExpression(
        pattern:
            #"^(?:[0-9]{1,2}\.?\s+|[A-Z](?:\.[0-9]{1,2})*\.?\s+)?(?:appendix|appendices|supplementary|supplemental|supporting information|acknowledge?ments?|author contributions|funding|conflicts? of interest|competing interests|declaration of|data availability|about the authors?|biograph(?:y|ies)|glossary|index|abbreviations|notes|(?:chapter|part)\s+[0-9IVXLC]+)\b"#,
        options: [.caseInsensitive])
    /// A numbered or lettered heading, which ends a list when it is set larger than its entries.
    static let sectionHeading = try! NSRegularExpression(pattern: #"^(?:[0-9]{1,2}(?:\.[0-9]{1,2}){0,3}|[A-Z](?:\.[0-9]{1,2}){0,3})\.?\s+\p{Lu}"#)

    /// An entry's label: `[12]`, `[BK06]`, `12.` or a bare number before a capital.
    static let bracketLabel = try! NSRegularExpression(pattern: #"^\[([0-9]{1,4})\]\s*"#)
    static let keyLabel = try! NSRegularExpression(pattern: #"^\[([A-Za-z][A-Za-z0-9+.\-]{0,15})\]\s*"#)
    static let dottedLabel = try! NSRegularExpression(pattern: #"^([0-9]{1,4})(?:\.\s*|\s+(?=[\p{Lu}\[“"‘(]))"#)
    /// Labels set apart from their entries, which PDFKit gives as one run: "1. 2. 3. 4.".
    static let labelColumn = try! NSRegularExpression(pattern: #"^(?:[0-9]{1,4}\.\s+){2,}"#)

    /// A raised marker of numbers, as `^{12}`, `^{3,5}` or `^{4–6}`.
    static let raisedCitation = try! NSRegularExpression(pattern: #"\^\{\s*([0-9]{1,4}(?:\s*[,–-]\s*[0-9]{1,4})*)\s*\}"#)
    static let bracketCitation = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{1,160})\]"#)

    /// A surname, with the particles before it: "van den Berg", "McCrary", "Fernández-Val".
    static let name = #"(?:(?:van|von|de|der|den|del|della|di|da|du|dos|le|la|ten|ter)\s+)*\p{Lu}[\p{L}'’\-]+"#
    static let year = #"(?:19|20)[0-9]{2}[a-z]?"#
    /// One citation inside parentheses: "Smith, 2020", "Smith and Jones 2019a", "Smith et al., 2020, 2021".
    static let citedPart = try! NSRegularExpression(
        pattern: #"^(?:(?:see|e\.g\.|cf\.|i\.e\.|also|and)[,]?\s+)*("# + name + #")(?:\s+et\s+al\.?|\s+(?:and|&)\s+("# + name + #")|,\s+"#
            + name + #",?\s+(?:and|&)\s+"# + name + #")?,?\s+("# + year + #"(?:\s*,\s*"# + year + #")*)"#)
    /// A narrative citation: "Smith et al. (2020)", "Smith and Jones (2019a, 2020)".
    static let narrative = try! NSRegularExpression(
        pattern: "(" + name + #")(?:\s+et\s+al\.?|\s+(?:and|&)\s+("# + name + #"))?\s+\(("# + year + #"(?:\s*[,;]\s*"# + year
            + #")*)(?:,\s*[^()]{1,20})?\)"#)
    static let parenthesis = try! NSRegularExpression(pattern: #"\(([^()]{4,400})\)"#)
    static let yearOnly = try! NSRegularExpression(pattern: year)

    /// Where an author's name starts an entry, after the one before ends: "… 2012.24) Beaulieu SE,
    /// Baker ET" or "… Working Paper. Abbring, J. H.". A full stop after an initial ends nothing:
    /// "Tom B. Brown, Benjamin Mann" is one name.
    static let authorStart = try! NSRegularExpression(
        pattern: #"(?:(?<=[\p{Ll}0-9]\.)|(?<=[)\]>]))\s+(?="# + name + #"(?:\s\p{Lu}{1,3}[,.]|,\s\p{Lu}[.\p{Ll}]))"#)

    /// A mention of a figure, a table, an equation, a section or an appendix.
    /// The word in any case, the number as printed: "Fig. 4", "table 2", "equation (5)", "§3.2".
    static let mentions: [(kind: String, pattern: NSRegularExpression)] = [
        ("figure", try! NSRegularExpression(pattern: #"\b(?i:figs?\.|figures?)\s?([0-9]{1,3}|[A-Z]\.?[0-9]{1,2})(?:[a-z]\b)?"#)),
        ("table", try! NSRegularExpression(pattern: #"\b(?i:tables?|tabs?\.)\s?([0-9]{1,3}|[A-Z]\.?[0-9]{1,2}|[IVX]{1,5}\b)"#)),
        (
            "equation",
            try! NSRegularExpression(
                pattern: #"\b(?i:eqs?\.|equations?|eqns?\.)\s?(?:\(([0-9]{1,3}(?:\.[0-9]{1,2})?[a-z]?)\)|([0-9]{1,3}(?:\.[0-9]{1,2})?)\b)"#)
        ),
        (
            "section",
            try! NSRegularExpression(
                pattern: #"(?:\b(?i:sections?|secs?\.|sects?\.)\s?|§\s?)([0-9]{1,2}(?:\.[0-9]{1,2}){0,3}|[A-Z](?:\.[0-9]{1,2}){1,3})\b"#)
        ),
        ("section", try! NSRegularExpression(pattern: #"\b(?i:appendix|app\.)\s([A-Z](?:\.[0-9]{1,2}){0,3})\b"#)),
    ]
    /// A heading that numbers a section, as "3.2 Method" or "Appendix A Proofs".
    static let numberedHeading = try! NSRegularExpression(
        pattern: #"^(?:(?:Appendix|APPENDIX)\s+)?([0-9]{1,2}(?:\.[0-9]{1,2}){0,3}|[A-Z](?:\.[0-9]{1,2}){0,3})[.:]?\s+\p{Lu}"#)

    static func match(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func group(_ result: NSTextCheckingResult, _ index: Int, in text: NSString) -> String? {
        let range = result.range(at: index)
        return range.location == NSNotFound ? nil : text.substring(with: range)
    }

    /// Letters alone, lowercased and without their accents: "Fernández-Val" is "fernandezval".
    static func plain(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter(\.isLetter)
    }

    /// Whether a raised citation may follow the character before `at`: what a note's marker may
    /// follow, or a per cent sign or a closing bracket, as "50%^{2,3}" and "[(C)RT]^{4}".
    static func follows(_ text: NSString, _ at: Int) -> Bool {
        if Notes.follows(text, at) { return true }
        guard at > 0, let scalar = Unicode.Scalar(text.character(at: at - 1)) else { return false }
        return "%)]".unicodeScalars.contains(scalar)
    }

    /// The years a citation names: "2019a, 2020" gives 2019a and 2020.
    static func years(in text: String) -> [String] {
        let ns = text as NSString
        return yearOnly.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// The numbers a token or a bracket's part names: "3", "3–5" or "3-5", at most 60.
    static func numbers(_ part: String) -> [Int]? {
        let pieces = part.split(whereSeparator: { "–-".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(pieces.count), let low = Int(pieces[0]), let high = Int(pieces.last!), low <= high, high - low <= 60 else {
            return nil
        }
        return Array(low...high)
    }

    // MARK: A page's digest

    /// What the judging of citations needs of one parsed page.
    struct Digest {
        struct Item {
            var text: String
            var lines: Int
            var size: Double?
            var box: Box
            /// The first line's left edge, to tell an entry from the lines that go on from it.
            var left: Double
            /// Part of a note or a region, which no list takes and which cites nothing here.
            var aside: Bool
        }

        struct Raised {
            var block: Int
            var token: String
            var numbers: [Int]
            var index: Int
            var offset: Int
        }

        struct Bracket {
            var block: Int
            var labels: [String]
            var offset: Int
        }

        struct Cited {
            var block: Int
            var surname: String
            var second: String?
            var years: [String]
            var offset: Int
        }

        struct Mention {
            var block: Int
            var kind: String
            var number: String
            var words: String
            var offset: Int
        }

        var items: [Item]
        /// Blocks that head a list of references.
        var headings: [Int]
        var raised: [Raised]
        var brackets: [Bracket]
        var cited: [Cited]
        var mentions: [Mention]
        /// The page's figures, tables and equations, by kind and number, lowercased.
        var regions: Set<String>
        /// Headings that number a section, as "3.2", with their blocks.
        var sections: [(label: String, block: Int, appendix: Bool)]
    }

    static func digest(_ layer: PageText) -> Digest {
        // An endnote is only a candidate until the document's reading judges its page a list of
        // notes: a list of references numbered `[1]` is one too (`resolve`).
        let inNote = Set((layer.notes ?? []).filter { $0.kind != .endnote }.flatMap(\.blocks))
        let inRegion = Set((layer.regions ?? []).flatMap { $0.caption + $0.blocks })
        var items: [Digest.Item] = []
        var headings: [Int] = []
        var raised: [Digest.Raised] = []
        var brackets: [Digest.Bracket] = []
        var cited: [Digest.Cited] = []
        var named: [Digest.Mention] = []
        var sections: [(String, Int, Bool)] = []
        for (index, block) in layer.blocks.enumerated() {
            let text = block.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            let sizes = block.lines.compactMap(\.size).sorted()
            let aside = inNote.contains(index) || inRegion.contains(index)
            items.append(
                Digest.Item(
                    text: text, lines: block.lines.count, size: sizes.isEmpty ? nil : sizes[sizes.count / 2], box: block.box,
                    left: block.lines.first?.box.x ?? block.box.x, aside: aside))
            guard !aside else { continue }
            if block.lines.count <= 2, text.count <= 60, match(heading, text) != nil { headings.append(index) }
            if block.lines.count == 1, text.split(separator: " ").count <= 12, let found = match(numberedHeading, text) {
                let ns = text as NSString
                let label = ns.substring(with: found.range(at: 1))
                let title = ns.substring(from: found.range(at: 1).upperBound)
                let visible = title.filter { !$0.isWhitespace }
                if visible.filter(\.isLetter).count * 10 >= visible.count * 6, title.last?.isNumber != true {
                    sections.append((label, index, text.lowercased().hasPrefix("appendix")))
                }
            }
            let ns = text as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var seen: [String: Int] = [:]
            raisedCitation.enumerateMatches(in: text, range: whole) { found, _, _ in
                guard let found, follows(ns, found.range.location), !Notes.power(ns, found.range) else { return }
                let token = ns.substring(with: found.range).dropFirst(2).dropLast().description
                let parts = ns.substring(with: found.range(at: 1)).split(separator: ",").map(String.init)
                let expanded = parts.compactMap(numbers)
                guard expanded.count == parts.count else { return }
                raised.append(
                    Digest.Raised(
                        block: index, token: token, numbers: expanded.flatMap { $0 }, index: seen[token, default: 0],
                        offset: found.range.location))
                seen[token, default: 0] += 1
            }
            bracketCitation.enumerateMatches(in: text, range: whole) { found, _, _ in
                guard let found else { return }
                let inner = ns.substring(with: found.range(at: 1))
                var labels: [String] = []
                for part in inner.split(whereSeparator: { ",;".contains($0) }).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if let numbers = numbers(part) {
                        labels += numbers.map(String.init)
                    } else if part.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]{0,15}$"#, options: .regularExpression) != nil,
                        part.contains(where: \.isUppercase) || part.contains(where: \.isNumber)
                    {
                        labels.append(part)
                    } else if !labels.isEmpty,
                        part.range(
                            of: #"^(?:p|pp|ch|chap|sec|thm|lemma|eq|fig|prop|cor|def)\.?\s*[0-9]"#, options: [.regularExpression, .caseInsensitive])
                            != nil
                    {
                        continue
                    } else {
                        return
                    }
                }
                if !labels.isEmpty { brackets.append(Digest.Bracket(block: index, labels: labels, offset: found.range.location)) }
            }
            parenthesis.enumerateMatches(in: text, range: whole) { found, _, _ in
                guard let found else { return }
                let inner = ns.substring(with: found.range(at: 1))
                var at = found.range(at: 1).location
                for part in inner.components(separatedBy: ";") {
                    defer { at += (part as NSString).length + 1 }
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    let tns = trimmed as NSString
                    guard let hit = match(citedPart, trimmed) else { continue }
                    cited.append(
                        Digest.Cited(
                            block: index, surname: tns.substring(with: hit.range(at: 1)), second: group(hit, 2, in: tns),
                            years: years(in: tns.substring(with: hit.range(at: 3))), offset: at))
                }
            }
            narrative.enumerateMatches(in: text, range: whole) { found, _, _ in
                guard let found else { return }
                cited.append(
                    Digest.Cited(
                        block: index, surname: ns.substring(with: found.range(at: 1)), second: group(found, 2, in: ns),
                        years: years(in: ns.substring(with: found.range(at: 3))), offset: found.range.location))
            }
            for (kind, pattern) in mentions {
                pattern.enumerateMatches(in: text, range: whole) { found, _, _ in
                    guard let found else { return }
                    // A caption that no region holds starts its block, as "Figure 3: …".
                    let after = found.range.upperBound < ns.length ? ns.substring(with: NSRange(location: found.range.upperBound, length: 1)) : ""
                    if found.range.location == 0, [":", ".", "|"].contains(after) { return }
                    let number = group(found, 1, in: ns) ?? group(found, 2, in: ns) ?? ""
                    named.append(
                        Digest.Mention(
                            block: index, kind: kind, number: Region.normalized(number).lowercased(),
                            words: ns.substring(with: found.range), offset: found.range.location))
                }
            }
        }
        let regions = Set((layer.regions ?? []).map { "\($0.kind.rawValue) \(Region.normalized($0.number).lowercased())" })
        return Digest(
            items: items, headings: headings, raised: raised, brackets: brackets, cited: cited, mentions: named, regions: regions,
            sections: sections)
    }

    // MARK: Lists and their entries

    enum Style {
        case numbered, dotted, keyed, authorYear
    }

    /// A list of references: its entries in order, and where it starts and ends.
    struct List {
        var style: Style
        var entries: [Entry]
        /// The page and block of its heading, and the page and block it ends before, counted from 0.
        var start: (page: Int, block: Int)
        var end: (page: Int, block: Int)
    }

    /// An entry while its list is read: its label, where it is, its words, and for a list by author
    /// and year, its first author's surname and its year.
    struct Entry {
        var label: String
        var page: Int
        var blocks: [Int]
        var text: String
        var surname: String?
        var year: String?
    }

    /// The lists of references in the pages parsed so far, in page order. A list starts after its
    /// heading and goes on over the pages after it, while each is parsed, until a heading of
    /// another part, as "Appendix", or one set larger than its entries.
    static func lists(_ digests: [Int: Digest]) -> [List] {
        var found: [List] = []
        let pages = digests.keys.sorted()
        var after: (page: Int, block: Int) = (-1, -1)
        for page in pages {
            for heading in digests[page]!.headings where (page, heading) > after {
                guard let list = list(from: (page, heading), digests) else { continue }
                found.append(list)
                // The next list may start right after this one's last entry, its heading taken
                // for a running header at the top of a page.
                let last = list.entries.last!
                after = (last.page, last.blocks.max() ?? heading)
                break
            }
        }
        return found
    }

    static func list(from start: (page: Int, block: Int), _ digests: [Int: Digest]) -> List? {
        // The blocks after the heading, in order, over the pages that follow it, each parsed.
        var stream: [(page: Int, block: Int, item: Digest.Item)] = []
        var page = start.page
        var block = start.block + 1
        var end = (page: start.page, block: digests[start.page]!.items.count)
        var sizes: [Double] = []
        scanning: while let digest = digests[page], page - start.page < 80 {
            while block < digest.items.count {
                let item = digest.items[block]
                defer { block += 1 }
                if item.aside || item.text.isEmpty { continue }
                // A page number or a running header at the page's edge.
                if Furniture.pageNumber(item.text) != nil { continue }
                if item.lines <= 2, item.box.y + item.box.height < 0.07 || item.box.y > 0.93 { continue }
                let short = item.lines <= 2 && item.text.count <= 80 && match(yearOnly, item.text) == nil
                if short, match(stop, item.text) != nil || match(heading, item.text) != nil {
                    end = (page, block)
                    break scanning
                }
                // A numbered heading set larger than the entries so far, as "A Proofs".
                if short, stream.count >= 3, let size = item.size, !sizes.isEmpty, match(sectionHeading, item.text) != nil,
                    size >= sizes.sorted()[sizes.count / 2] * 1.1
                {
                    end = (page, block)
                    break scanning
                }
                if let size = item.size { sizes.append(size) }
                stream.append((page, block, item))
            }
            end = (page, digest.items.count)
            page += 1
            block = 0
        }
        guard !stream.isEmpty else { return nil }
        let first = stream.prefix(4).map(\.item.text)
        let style: Style
        if first.contains(where: { match(bracketLabel, $0) != nil }) {
            style = .numbered
        } else if first.contains(where: { match(dottedLabel, $0) != nil || match(labelColumn, $0) != nil }) {
            style = .dotted
        } else if first.contains(where: { match(keyLabel, $0) != nil }) {
            style = .keyed
        } else {
            style = .authorYear
            // Every entry by author and year holds a year: four blocks of words in a row with
            // none are the text after the list, as a chapter that goes on with no heading found.
            var run = 0
            for (position, part) in stream.enumerated() {
                run = part.item.text.count >= 40 && match(yearOnly, part.item.text) == nil ? run + 1 : 0
                if run == 4 {
                    let cut = position - 3
                    end = (stream[cut].page, stream[cut].block)
                    stream.removeSubrange(cut...)
                    break
                }
            }
        }
        var entries: [Entry]
        switch style {
        case .numbered: entries = numberedEntries(stream, bracketed: true)
        case .dotted: entries = numberedEntries(stream, bracketed: false)
        case .keyed: entries = keyedEntries(stream)
        case .authorYear: entries = authorEntries(stream)
        }
        // A list whose entries end early leaves the blocks after them out: what follows a
        // numbered list without a heading, as an appendix, is no entry of it.
        if style != .authorYear, let last = entries.last {
            let lastIndex = stream.lastIndex { $0.page == last.page && last.blocks.contains($0.block) } ?? stream.count - 1
            let trailing = stream.count - 1 - lastIndex
            if trailing > 0 { end = (stream[lastIndex + 1].page, stream[lastIndex + 1].block) }
        }
        guard entries.count >= 2 else { return nil }
        return List(style: style, entries: entries, start: start, end: end)
    }

    /// Entries labelled `[1]` or `1.` in order. Each starts where its label, the number after the
    /// last, stands: at a block's start, or inside a block that holds several. Blocks that start
    /// with no label go on from the entry before, at most six in a row; a block of labels alone,
    /// "1. 2. 3.", as a list whose numbers stand in a column of their own gives them, splits the
    /// text after it at each author's name, when the names count as many as the labels.
    static func numberedEntries(_ stream: [(page: Int, block: Int, item: Digest.Item)], bracketed: Bool) -> [Entry] {
        var entries: [Entry] = []
        var expected: Int?
        var loose = 0
        var position = 0
        while position < stream.count {
            let (page, block, item) = stream[position]
            var text = item.text
            // Labels in a column of their own.
            if !bracketed, let column = match(labelColumn, text) {
                let ns = text as NSString
                let labels = ns.substring(with: column.range).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                let consecutive = zip(labels, labels.dropFirst()).allSatisfy { $1 == $0 + 1 }
                var words = ns.substring(from: column.range.upperBound)
                var taken = [(page, block)]
                var next = position + 1
                while next < stream.count, match(labelColumn, stream[next].item.text) == nil, match(dottedLabel, stream[next].item.text) == nil {
                    words += " " + stream[next].item.text
                    taken.append((stream[next].page, stream[next].block))
                    next += 1
                }
                let parts = split(words, at: authorStart)
                if consecutive, parts.count == labels.count, expected == nil || labels[0] == expected! {
                    for (number, part) in zip(labels, parts) {
                        entries.append(Entry(label: String(number), page: page, blocks: taken.filter { $0.0 == page }.map(\.1), text: part))
                    }
                    expected = labels.last! + 1
                } else {
                    expected = labels.last.map { $0 + 1 }
                }
                loose = 0
                position = next
                continue
            }
            // The labels in this block: at its start, the number after the last or one a few
            // past it, where an entry was lost; inside it, the number after the last alone, as
            // a number inside an entry could be another.
            var starts: [(offset: Int, end: Int, number: Int)] = []
            let ns = text as NSString
            var cursor = 0
            while cursor < ns.length {
                let number = expected ?? 1
                let rest = ns.substring(from: cursor)
                var found: NSRange?
                var value = number
                if cursor == 0, let head = match(bracketed ? bracketLabel : dottedLabel, rest),
                    let label = Int((rest as NSString).substring(with: head.range(at: 1))),
                    expected == nil || (number...number + 3).contains(label)
                {
                    found = head.range
                    value = label
                } else if expected != nil {
                    let pattern = bracketed ? #"(?<=\s)\[\#(number)\]\s*"# : #"(?<=[.)\]”"’>]\s)\#(number)\.\s+(?=[\p{Lu}\[“"‘(])"#
                    found = rest.range(of: pattern, options: .regularExpression).map { NSRange($0, in: rest) }
                }
                guard let found else { break }
                let start = cursor + found.location
                starts.append((start, start + found.length, value))
                expected = value + 1
                cursor = start + found.length
            }
            if starts.isEmpty {
                // Words that go on from the entry before.
                loose += 1
                if let last = entries.indices.last, loose <= 6 {
                    entries[last].text += " " + text
                    if entries[last].page == page { entries[last].blocks.append(block) }
                }
                position += 1
                continue
            }
            loose = 0
            if starts[0].offset > 0, let last = entries.indices.last {
                entries[last].text += " " + ns.substring(to: starts[0].offset).trimmingCharacters(in: .whitespaces)
            }
            for (number, start) in starts.enumerated() {
                let stop = number + 1 < starts.count ? starts[number + 1].offset : ns.length
                text = ns.substring(with: NSRange(location: start.end, length: stop - start.end)).trimmingCharacters(in: .whitespaces)
                entries.append(Entry(label: String(start.number), page: page, blocks: [block], text: text))
            }
            position += 1
        }
        return entries
    }

    /// Entries labelled with a printed key, as `[BK06] M. Broadie and O. Kaya, …`.
    static func keyedEntries(_ stream: [(page: Int, block: Int, item: Digest.Item)]) -> [Entry] {
        var entries: [Entry] = []
        for (page, block, item) in stream {
            let ns = item.text as NSString
            var starts: [(range: NSRange, key: String)] = []
            keyAnywhere.enumerateMatches(in: item.text, range: NSRange(location: 0, length: ns.length)) { found, _, _ in
                guard let found else { return }
                starts.append((found.range, ns.substring(with: found.range(at: 1))))
            }
            if starts.isEmpty || starts[0].range.location > 0, let last = entries.indices.last {
                let stop = starts.first?.range.location ?? ns.length
                entries[last].text += " " + ns.substring(to: stop).trimmingCharacters(in: .whitespaces)
                if entries[last].page == page { entries[last].blocks.append(block) }
            }
            for (number, start) in starts.enumerated() {
                let stop = number + 1 < starts.count ? starts[number + 1].range.location : ns.length
                let text = ns.substring(with: NSRange(location: start.range.upperBound, length: stop - start.range.upperBound))
                entries.append(Entry(label: start.key, page: page, blocks: [block], text: text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return entries
    }

    static let keyAnywhere = try! NSRegularExpression(pattern: #"(?:^|(?<=[.)]\s))\[([A-Za-z][A-Za-z0-9+.\-]{0,15})\]\s*"#)

    /// Entries by author and year: each block that starts left in its column, with a capital,
    /// starts one, and one that starts further in, or with a small letter or a digit, goes on from
    /// it. A block that holds several, as PDFKit joins them, comes apart where a name follows the
    /// end of the one before.
    static func authorEntries(_ stream: [(page: Int, block: Int, item: Digest.Item)]) -> [Entry] {
        var entries: [Entry] = []
        // The left edge of each column of the list, by page: the leftmost of the blocks near it.
        var lefts: [Int: [Double]] = [:]
        for (page, _, item) in stream { lefts[page, default: []].append(item.left) }
        func starts(_ page: Int, _ item: Digest.Item) -> Bool {
            guard let first = item.text.first, first.isUppercase || first == "“" || first == "\"" else { return false }
            // In its column: the blocks whose left edges lie within a tenth of the page of it.
            let near = (lefts[page] ?? []).filter { abs($0 - item.left) < 0.1 }
            guard let edge = near.min() else { return true }
            return item.left - edge < 0.008
        }
        for (page, block, item) in stream {
            if !starts(page, item), let last = entries.indices.last {
                entries[last].text += " " + item.text
                if entries[last].page == page { entries[last].blocks.append(block) }
                continue
            }
            for part in split(item.text, at: authorStart) {
                entries.append(Entry(label: "", page: page, blocks: [block], text: part))
            }
        }
        for index in entries.indices {
            let (surname, year) = author(entries[index].text)
            entries[index].surname = surname
            entries[index].year = year
        }
        return entries.filter { $0.surname != nil && $0.year != nil }
    }

    /// A text split before each match of a pattern that marks where a part starts.
    static func split(_ text: String, at pattern: NSRegularExpression) -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var from = 0
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { found, _, _ in
            guard let found else { return }
            let stop = found.range.upperBound
            let part = ns.substring(with: NSRange(location: from, length: found.range.location - from)).trimmingCharacters(in: .whitespaces)
            if !part.isEmpty { parts.append(part) }
            from = stop
        }
        let last = ns.substring(from: from).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// An entry's first author's surname and its year: "Abadie, A. (2005)" gives Abadie and 2005,
    /// "Adams DK, Arellano SM … 2012" Adams and 2012, "Ahmed Abdelreheem, Filippo Aleotti … 2023"
    /// Abdelreheem and 2023, "OpenAI. 2023." OpenAI.
    static func author(_ text: String) -> (surname: String?, year: String?) {
        let ns = text as NSString
        let year = match(yearOnly, text).map { ns.substring(with: $0.range) }
        if let found = match(surnameFirst, text) {
            return (ns.substring(with: found.range(at: 1)), year)
        }
        // A first author's whole name, as "Tom B. Brown" or "A. Vaswani": its words up to a comma,
        // "and", a year, or a full stop after a word that is no initial.
        var words: [String] = []
        for word in text.split(separator: " ").prefix(8).map(String.init) {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if word == "and" || word == "&" || bare.hasPrefix("(") || match(yearOnly, bare) != nil { break }
            words.append(bare)
            if word.hasSuffix(",") || word.hasSuffix(";") || (word.hasSuffix(".") && bare.count >= 2) { break }
        }
        let surname = words.last { word in word.first?.isUppercase == true && word.filter(\.isLetter).count >= 2 }
        return (surname, year)
    }

    /// A surname first, as "Abadie, A.", "Adams DK, …", "Peng RD (2011)" or "Smith J 2020": with
    /// initials after it, not "Tom B. Brown".
    static let surnameFirst = try! NSRegularExpression(pattern: "^(" + name + #")(?:,\s|\s\p{Lu}{1,3}(?:,|\s\(|\s(?:19|20)[0-9]{2}))"#)

    // MARK: Judging citations against the document

    /// What the lists and citations of the pages parsed so far come to.
    struct Judged {
        var lists: [List]
        /// Each entry by its id, in list order.
        var entries: [(id: String, list: Int, entry: Entry)]
        var pages: [Int: PageCitations]
    }

    /// The citations, cross-references and entries of the pages parsed so far.
    /// - Parameters:
    ///   - notes: the notes the pages' raised markers lead to, which cite no reference.
    ///   - outline: the file's bookmarks, whose numbers name the sections that "Section 3.2" means.
    static func resolve(digests found: [Int: Digest], notes: [Int: PageNotes], outline: [FileFacts.Section] = []) -> Judged {
        // The endnotes a read keeps out of the text belong to no list of references and cite none.
        var digests = found
        for (page, judged) in notes {
            let kept = Set(judged.entries.filter { $0.kind == .endnote }.flatMap(\.blocks))
            guard !kept.isEmpty, var digest = digests[page] else { continue }
            for block in kept where digest.items.indices.contains(block) { digest.items[block].aside = true }
            digest.headings.removeAll(where: kept.contains)
            digest.raised.removeAll { kept.contains($0.block) }
            digest.brackets.removeAll { kept.contains($0.block) }
            digest.cited.removeAll { kept.contains($0.block) }
            digest.mentions.removeAll { kept.contains($0.block) }
            digests[page] = digest
        }
        let lists = lists(digests)
        // Ids: the first list's plain, a later one's with its number before.
        var entries: [(id: String, list: Int, entry: Entry)] = []
        var byLabel: [[String: [String]]] = Array(repeating: [:], count: lists.count)
        var byAuthor: [[String: [(id: String, entry: Entry)]]] = Array(repeating: [:], count: lists.count)
        for (number, list) in lists.enumerated() {
            var used: [String: Int] = [:]
            for entry in list.entries {
                var own: String
                if list.style == .authorYear {
                    let surname = entry.surname!.filter { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
                    own = surname + entry.year!
                } else {
                    own = entry.label
                }
                used[own, default: 0] += 1
                if used[own]! > 1 { own += "-\(used[own]!)" }
                let id = number == 0 ? own : "\(number + 1).\(own)"
                entries.append((id, number, entry))
                if list.style == .authorYear {
                    byAuthor[number][plain(entry.surname!) + "|" + String(entry.year!.prefix(4)), default: []].append((id, entry))
                } else {
                    byLabel[number][entry.label.lowercased(), default: []].append(id)
                }
            }
        }
        // The list a citation at a place leads to: the first after it of the right kind, or else
        // the last before it.
        func list(at place: (page: Int, block: Int), labelled: Bool) -> Int? {
            let fitting = lists.indices.filter { (lists[$0].style == .authorYear) != labelled }
            return fitting.first { (lists[$0].start.page, lists[$0].start.block) > (place.page, place.block) } ?? fitting.last
        }
        func inList(_ page: Int, _ block: Int) -> Bool {
            lists.contains { (page, block) > ($0.start.page, $0.start.block) && (page, block) < ($0.end.page, $0.end.block) }
        }
        // The sections that "Section 3.2" names: the bookmarks' numbers, or else headings in the text.
        var sectionPages: [String: Set<Int>] = [:]
        let numberedOutline = outline.compactMap { item -> (String, Int)? in
            guard let found = match(numberedHeading, item.title.trimmingCharacters(in: .whitespaces)) else { return nil }
            return ((item.title as NSString).substring(with: found.range(at: 1)).lowercased(), item.page + 1)
        }
        if !numberedOutline.isEmpty {
            for (label, page) in numberedOutline { sectionPages[label, default: []].insert(page) }
        } else {
            let firstList = lists.first.map(\.start.page) ?? Int.max
            for (page, digest) in digests {
                for section in digest.sections {
                    // A lettered heading, as "A Proofs", is an appendix's: after the references or
                    // named so. "A Survey of …" on a title page is none.
                    if section.label.first?.isLetter == true, !section.appendix, !section.label.contains("."), page <= firstList { continue }
                    sectionPages[section.label.lowercased(), default: []].insert(page + 1)
                }
            }
        }
        var regionPages: [String: [Int]] = [:]
        for page in digests.keys.sorted() {
            for key in digests[page]!.regions { regionPages[key, default: []].append(page + 1) }
        }

        // Raised numbers cite the list only in a document that cites so more often than in
        // brackets: in a paper that cites [12], a raised 2 is a square or a note's.
        var raisedFits = 0
        var bracketFits = 0
        for (page, digest) in digests {
            for item in digest.raised where !inList(page, item.block) {
                if let number = list(at: (page, item.block), labelled: true), item.numbers.allSatisfy({ byLabel[number][String($0)] != nil }) {
                    raisedFits += 1
                }
            }
            for item in digest.brackets where !inList(page, item.block) {
                if let number = list(at: (page, item.block), labelled: true), item.labels.allSatisfy({ byLabel[number][$0.lowercased()] != nil }) {
                    bracketFits += 1
                }
            }
        }
        let raisedCites = raisedFits > bracketFits

        var result: [Int: PageCitations] = [:]
        let entryByID = Dictionary(entries.map { ($0.id, $0) }) { first, _ in first }
        for (page, digest) in digests {
            var citations = PageCitations()
            func cite(_ block: Int, _ ids: [String]) {
                for id in ids where !(citations.cites[block] ?? []).contains(id) {
                    citations.cites[block, default: []].append(id)
                    if let found = entryByID[id] { citations.entries[id] = ReferenceEntry(found) }
                }
            }
            let notedTokens = Set(
                (notes[page]?.references ?? [:]).flatMap { block, references in references.map { "\(block)|\($0.token)|\($0.index)" } })
            var cited: [(offset: Int, block: Int, ids: [String])] = []
            for item in digest.raised
            where raisedCites && !inList(page, item.block) && !notedTokens.contains("\(item.block)|\(item.token)|\(item.index)") {
                guard let number = list(at: (page, item.block), labelled: true), lists[number].style != .keyed else { continue }
                let ids = item.numbers.compactMap { byLabel[number][String($0)]?.first }
                guard ids.count == item.numbers.count else { continue }
                citations.raised[item.block, default: []].append(PageCitations.Raised(token: item.token, index: item.index))
                cited.append((item.offset, item.block, ids))
            }
            for item in digest.brackets where !inList(page, item.block) {
                guard let number = list(at: (page, item.block), labelled: true) else { continue }
                let ids = item.labels.compactMap { byLabel[number][$0.lowercased()]?.first }
                guard ids.count == item.labels.count else { continue }
                cited.append((item.offset, item.block, ids))
            }
            for item in digest.cited where !inList(page, item.block) {
                guard let number = list(at: (page, item.block), labelled: false) else { continue }
                var ids: [String] = []
                for year in item.years {
                    let found = byAuthor[number][plain(item.surname) + "|" + String(year.prefix(4))] ?? []
                    // A year with its letter names that entry; one without, the entries of that year.
                    var fitting = found.filter { year.count == 4 || $0.entry.year == year }
                    if let second = item.second, fitting.count > 1 {
                        let both = fitting.filter { plain($0.entry.text).contains(plain(second)) }
                        if !both.isEmpty { fitting = both }
                    }
                    ids += fitting.map(\.id)
                }
                if !ids.isEmpty { cited.append((item.offset, item.block, ids)) }
            }
            for item in cited.sorted(by: { ($0.block, $0.offset) < ($1.block, $1.offset) }) { cite(item.block, item.ids) }
            // Cross-references, each to the one page that holds what it names.
            for mention in digest.mentions where !inList(page, mention.block) {
                var pages: [Int]
                if mention.kind == "section" {
                    pages = Array(sectionPages[mention.number] ?? []).sorted()
                } else {
                    pages = regionPages["\(mention.kind) \(mention.number)"] ?? []
                }
                // A table continued over pages that follow one another is one.
                if pages.count > 1, pages.last! - pages.first! < pages.count { pages = [pages.first!] }
                guard pages.count == 1 else { continue }
                citations.pointers[mention.block, default: []].append(
                    PageCitations.Pointer(words: mention.words, offset: mention.offset, page: pages[0]))
            }
            if !citations.isEmpty { result[page] = citations }
        }
        return Judged(lists: lists, entries: entries, pages: result)
    }

    /// An entry's DOI, as its words give it: "doi:10.5670/oceanog.2012.24", "https://doi.org/10.…".
    static func doi(_ text: String) -> String? {
        guard let range = text.range(of: #"\b10\.[0-9]{4,9}/[^\s"<>\]]+"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]"))
    }

    // MARK: Text

    /// A block's text with its references to notes written `[^7]` and its raised citations
    /// `[12]`, each found by its token and its place among the block's raised markers with that
    /// token, in one pass, so neither moves the other's places. Markers inside a hidden-text
    /// label, which `--include-hidden` shows, count for neither.
    static func linked(_ text: String, notes: [PageNotes.Reference], raised: [PageCitations.Raised]) -> String {
        guard !notes.isEmpty || !raised.isEmpty else { return text }
        let ns = text as NSString
        let hidden = hiddenSpans(ns)
        func outside(_ range: NSRange) -> Bool { !hidden.contains { NSIntersectionRange($0, range).length > 0 } }
        var replacements: [(range: NSRange, text: String)] = []
        if !notes.isEmpty {
            var seen: [String: Int] = [:]
            for found in Notes.references(in: text) where outside(found.range) {
                let index = seen[found.token, default: 0]
                seen[found.token] = index + 1
                if let reference = notes.first(where: { $0.token == found.token && $0.index == index }) {
                    replacements.append((found.range, reference.ids.map { "[^\($0)]" }.joined()))
                }
            }
        }
        if !raised.isEmpty {
            var seen: [String: Int] = [:]
            raisedCitation.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { found, _, _ in
                guard let found, outside(found.range), follows(ns, found.range.location), !Notes.power(ns, found.range) else { return }
                let token = String(ns.substring(with: found.range).dropFirst(2).dropLast())
                let index = seen[token, default: 0]
                seen[token] = index + 1
                guard raised.contains(where: { $0.token == token && $0.index == index }),
                    !replacements.contains(where: { NSIntersectionRange($0.range, found.range).length > 0 })
                else { return }
                replacements.append((found.range, "[\(ns.substring(with: found.range(at: 1)))]"))
            }
        }
        // From the end, so the places before stay where they are.
        var result = ns
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: replacement.range, with: replacement.text) as NSString
        }
        return result as String
    }

    /// Where a text holds a hidden-text label, `[hidden…]`, which `Output.marker` writes.
    static func hiddenSpans(_ text: NSString) -> [NSRange] {
        var spans: [NSRange] = []
        var from = 0
        while from < text.length {
            let open = text.range(of: "[hidden", range: NSRange(location: from, length: text.length - from))
            guard open.location != NSNotFound else { break }
            let close = text.range(of: "]", range: NSRange(location: open.upperBound, length: text.length - open.upperBound))
            let end = close.location == NSNotFound ? text.length : close.upperBound
            spans.append(NSRange(location: open.location, length: end - open.location))
            from = end
        }
        return spans
    }
}

extension ReferenceEntry {
    init(_ found: (id: String, list: Int, entry: References.Entry)) {
        self.init(id: found.id, page: found.entry.page, blocks: found.entry.blocks, text: found.entry.text, doi: References.doi(found.entry.text))
    }
}

/// A document's citations as a read sees them, kept across the chunks of pages it fetches, so
/// each page is digested once.
public struct ReferenceIndex {
    var digests: [Int: References.Digest] = [:]
    var judged: References.Judged?
    let outline: [FileFacts.Section]

    public init(outline: [FileFacts.Section] = []) {
        self.outline = outline
    }

    /// Digests a parsed page the index lacks.
    public mutating func add(_ page: Int, _ layer: PageText) {
        guard digests[page] == nil else { return }
        digests[page] = References.digest(layer)
        judged = nil
    }

    /// Adds the pages cached under `keys` that the index lacks.
    public mutating func refresh(keys: [String], store: Store) throws {
        let missing = keys.indices.filter { digests[$0] == nil }
        var from = 0
        while from < missing.count {
            let chunk = Array(missing[from..<min(from + 50, missing.count)])
            let results = try store.results(keys: chunk.map { keys[$0] })
            for page in chunk {
                if let layer = results[keys[page]]?.pageText { add(page, layer) }
            }
            from += 50
        }
    }

    /// The citations of the pages asked for, counted from 0, judged against the pages parsed so far.
    /// - Parameter notes: the notes of every page parsed so far, whose markers cite no reference.
    public mutating func resolve(pages: [Int], notes: [Int: PageNotes]) -> [Int: PageCitations] {
        if judged == nil { judged = References.resolve(digests: digests, notes: notes, outline: outline) }
        return judged!.pages.filter { pages.contains($0.key) }
    }

    /// The pages, counted from 1, whose text mentions a figure, a table or an equation, as "Fig. 4"
    /// or "Eq. (5)" does, for `pdf crop` to say where the text discusses it.
    public static func pagesMentioning(_ kind: Region.Kind, _ number: String, in pages: [(index: Int, layer: PageText)]) -> [Int] {
        let wanted = Region.normalized(number).lowercased()
        return pages.filter { page in
            References.digest(page.layer).mentions.contains { $0.kind == kind.rawValue && $0.number == wanted }
        }.map { $0.index + 1 }.sorted()
    }

    /// How many entries the lists hold, and on which pages they start, counted from 1.
    public mutating func lists(notes: [Int: PageNotes]) -> [(entries: Int, page: Int)] {
        if judged == nil { judged = References.resolve(digests: digests, notes: notes, outline: outline) }
        return judged!.lists.map { ($0.entries.count, $0.start.page + 1) }
    }

    /// One entry, found by its id, with the places that cite it.
    public struct Found: Encodable, Equatable, Sendable {
        public struct Place: Encodable, Equatable, Sendable {
            /// Counted from 1.
            public var page: Int
            public var block: Int
            /// The words around the citation.
            public var excerpt: String
        }

        public var id: String
        /// Counted from 1.
        public var page: Int
        public var text: String
        public var doi: String?
        public var citations: [Place]
        /// Pages of the file are not parsed yet, so the entry and its citations can change.
        public var provisional: Bool? = nil
    }

    public enum Outcome: Equatable, Sendable {
        case found(Found)
        /// No entry has this id; these are the ids the document has, in order.
        case missing([String])
        /// Several entries fit; these are their ids.
        case ambiguous([String])
    }

    /// The entry an id names: "12", "[12]", "BK06", "Smith2020", "Smith 2020" or "smith, 2020a";
    /// "2.12" for a later list's. A surname alone, or a number several lists have, names the entry
    /// when only one fits.
    /// - Parameter links: the file's links, of which one over the entry's words to doi.org gives
    ///   its DOI when its words give none.
    public mutating func lookup(
        _ id: String, notes: [Int: PageNotes], keys: [String], store: Store,
        links: [FileFacts.Annotation] = []
    ) throws -> Outcome {
        if judged == nil { judged = References.resolve(digests: digests, notes: notes, outline: outline) }
        let judged = judged!
        let ids = judged.entries.map(\.id)
        func key(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
            }
        }
        let wanted = key(id.trimmingCharacters(in: CharacterSet(charactersIn: " []")))
        guard !wanted.isEmpty else { return .missing(ids) }
        var matches = judged.entries.filter { key($0.id) == wanted }
        if matches.isEmpty {
            // A later list's entry by its own id; a surname and a year without the year's letter;
            // a surname alone.
            matches = judged.entries.filter { entry in
                let own = key(entry.id)
                let bare = entry.list > 0 ? String(own.drop { $0 != "." }.dropFirst()) : own
                if bare == wanted { return true }
                guard wanted.contains(where: \.isLetter), bare.hasPrefix(wanted) else { return false }
                let rest = bare.dropFirst(wanted.count)
                return wanted.last!.isNumber ? rest.allSatisfy { $0.isLetter || $0 == "-" || $0.isNumber } : rest.first?.isNumber == true
            }
        }
        guard let match = matches.first else { return .missing(ids) }
        guard matches.count == 1 else { return .ambiguous(matches.map(\.id)) }
        var places: [Found.Place] = []
        for page in judged.pages.keys.sorted() {
            let blocks = judged.pages[page]!.cites.filter { $0.value.contains(match.id) }.keys.sorted()
            guard !blocks.isEmpty, let layer = try store.results(keys: [keys[page]])[keys[page]]?.pageText else { continue }
            for block in blocks where layer.blocks.indices.contains(block) {
                let text = References.linked(
                    layer.blocks[block].visibleText, notes: notes[page]?.references[block] ?? [],
                    raised: judged.pages[page]!.raised[block] ?? [])
                places.append(Found.Place(page: page + 1, block: block + 1, excerpt: Self.excerpt(text, citing: match.entry)))
            }
        }
        var entry = ReferenceEntry(match)
        if entry.doi == nil, let layer = try store.results(keys: [keys[entry.page]])[keys[entry.page]]?.pageText {
            let boxes = entry.blocks.filter(layer.blocks.indices.contains).map { layer.blocks[$0].box }
            entry.doi =
                links.lazy.filter { link in
                    link.page == entry.page && link.kind == .link && boxes.contains { Output.share(of: link.box, inside: $0) >= 0.5 }
                }.compactMap { $0.target.flatMap(References.doi) }.first
        }
        return .found(Found(id: match.id, page: entry.page + 1, text: entry.text, doi: entry.doi, citations: places))
    }

    /// The words around the first place a block's text cites an entry: its label, or its first
    /// author's surname.
    static func excerpt(_ text: String, citing entry: References.Entry) -> String {
        let label = entry.label
        let range: Range<String.Index>? =
            label.isEmpty
            ? text.range(of: entry.surname ?? "\u{0}")
            : text.range(of: #"[\[,\s–-]"# + NSRegularExpression.escapedPattern(for: label) + #"[\],\s–-]"#, options: .regularExpression)
        guard let range else { return text.count > 140 ? String(text.prefix(140)) + "…" : text }
        let before = text[..<range.lowerBound].suffix(70)
        let after = text[range.lowerBound...].prefix(80)
        return (before.count == 70 ? "…" : "") + before + after + (text[range.lowerBound...].count > 80 ? "…" : "")
    }
}
