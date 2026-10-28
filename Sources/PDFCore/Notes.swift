import Foundation

/// A note on a page, found when the page is parsed: footnotes, endnotes, a headnote and margin
/// notes (FEATURES.md → F14, plan/ROADMAP.md → M2.7). `pdf read` shows each in its own place; what
/// depends on the whole document, as a note's number when numbering restarts, is judged when a
/// page is read (`Notes.resolve`), as running headers are.
public struct PageNote: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case footnote, endnote, headnote, margin
    }

    public var kind: Kind
    /// The number or sign the note starts with, as "7" or "*", for a footnote or an endnote.
    public var marker: String?
    /// The blocks of the note, counted from 0, in order: a footnote's text may go on in the
    /// blocks below its first.
    public var blocks: [Int]
    /// The note's own words, when its blocks hold several notes that run together, as an endnote
    /// list set as running text: "… (Jan. 25, 2004). 35.AAL transcript …".
    public var text: String? = nil
}

/// What `pdf read` shows of one page's notes, judged against the document.
public struct PageNotes: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var kind: PageNote.Kind
        /// How the document names the note: "7", "*", or "3.7" where numbering restarts. Nil for
        /// a headnote and a margin note.
        public var id: String?
        public var blocks: [Int]
        /// Its own words, where its blocks hold several notes.
        public var text: String? = nil
        /// A footnote on the first pages that tells about the authors: who contributed equally,
        /// whom to write to, where they work.
        public var author = false
    }

    /// A raised marker in a block of the page's text that leads to one or more notes.
    public struct Reference: Equatable, Sendable {
        /// What stands between the braces of `^{…}`, as "7" or "1,†".
        public var token: String
        public var ids: [String]
        /// Which of the block's references with this token it is, counted from 0: in "5 cm^{2}
        /// … the board^{2}", only one leads to note 2.
        public var index = 0

        public init(token: String, ids: [String], index: Int = 0) {
            self.token = token
            self.ids = ids
            self.index = index
        }
    }

    public var entries: [Entry] = []
    /// The references of the page's blocks, by block.
    public var references: [Int: [Reference]] = [:]

    public init(entries: [Entry] = [], references: [Int: [Reference]] = [:]) {
        self.entries = entries
        self.references = references
    }

    public var isEmpty: Bool { entries.isEmpty }
}

public enum Notes {
    // MARK: Finding notes on a page

    struct Found {
        var notes: [PageNote] = []
        /// The page has a block that heads a list of endnotes: "Notes", "Endnotes".
        var heading = false
        /// Another heading, as "References", ends a list of endnotes on the page: the page after
        /// does not go on from it.
        var ended = false
    }

    /// Signs a note may start with.
    static let signs = "*†‡§¶‖#∗"

    /// A block of the text is a note's start when a number or a sign that is raised, or stands
    /// alone before a space, leads it.
    private static let start = try! NSRegularExpression(
        pattern: #"^(?:\^\{([0-9]{1,3}|[*†‡§¶‖#∗]{1,3}|[a-z])\}|([0-9]{1,3})[.)]?(?=\s)|([*†‡§¶‖∗]))\s*(.*)$"#,
        options: [.dotMatchesLineSeparators])
    /// An endnote's entry: "12.", "12 ", "[12]" or a raised 12.
    private static let entry = try! NSRegularExpression(
        pattern: #"^(?:\^\{([0-9]{1,3})\}|\[([0-9]{1,3})\]|([0-9]{1,3})[.)]?(?=\s))\s*(.*)$"#,
        options: [.dotMatchesLineSeparators])
    /// A raised marker inside the text, as `^{7}` or `^{1,†}`.
    private static let raised = try! NSRegularExpression(pattern: #"\^\{([^{}]{1,12})\}"#)
    private static let heading = try! NSRegularExpression(
        pattern: #"^(?:(?:end|chapter|part)\s?)?notes(?:\s+(?:to|for|on)\s+.{1,40})?$"#, options: [.caseInsensitive])
    /// The heading of a part that ends a list of notes.
    private static let otherHeading = try! NSRegularExpression(
        pattern:
            #"^(?:[0-9]{1,2}\.?\s+|[A-Z]\.?\s+)?(?:references|bibliography|works cited|literature cited|acknowledge?ments?|appendix(?:\s+[A-Z0-9]{1,3})?|glossary|about the authors?)\s*[:.]?$"#,
        options: [.caseInsensitive])
    /// A bare number at a line's start, before a space and a word.
    private static let numberStart = try! NSRegularExpression(pattern: #"^([0-9]{1,3})[.)]?\s+\S"#)
    private static let dottedStart = try! NSRegularExpression(pattern: #"^([0-9]{1,3})\.\s+\S"#)
    private static let abstractLabel = try! NSRegularExpression(
        pattern: #"^(?:abstract|summary|keywords?|key words|résumé|resumen|zusammenfassung|contents|table of contents|摘要)\b"#,
        options: [.caseInsensitive])

    static func match(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// A marker as the document spells it: digits, signs with the asterisk's look-alikes made
    /// one, or a lowercase letter where `letters` allows it.
    static func marker(_ token: String, letters: Bool = false) -> String? {
        let text = token.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil { return text }
        if text.range(of: #"^[*†‡§¶‖#∗]{1,3}$"#, options: .regularExpression) != nil {
            return text.replacingOccurrences(of: "∗", with: "*")
        }
        if letters, text.range(of: #"^[a-z]$"#, options: .regularExpression) != nil { return text }
        return nil
    }

    /// The marker a block's text starts with, whether it was raised, and the text after it.
    static func leading(_ text: String) -> (marker: String, raised: Bool, rest: String)? {
        guard let found = match(start, text) else { return nil }
        let ns = text as NSString
        func group(_ index: Int) -> String? {
            found.range(at: index).location == NSNotFound ? nil : ns.substring(with: found.range(at: index))
        }
        let rest = group(4) ?? ""
        guard rest.contains(where: \.isLetter), rest.count >= 3 else { return nil }
        if let token = group(1) {
            guard let marker = marker(token, letters: true) else { return nil }
            return (marker, true, rest)
        }
        if let digits = group(2) { return (digits, false, rest) }
        if let sign = group(3) { return (sign == "∗" ? "*" : sign, false, rest) }
        return nil
    }

    /// The number an endnote's entry starts with, and its text.
    static func numbered(_ text: String) -> (number: Int, rest: String)? {
        guard let found = match(entry, text) else { return nil }
        let ns = text as NSString
        for index in 1...3 where found.range(at: index).location != NSNotFound {
            guard let number = Int(ns.substring(with: found.range(at: index))) else { return nil }
            let rest = found.range(at: 4).location == NSNotFound ? "" : ns.substring(with: found.range(at: 4))
            return (number, rest)
        }
        return nil
    }

    /// The raised markers inside a block's text: where, what is between the braces, the notes'
    /// markers it names, and which of the block's references with this token it is. Only a marker
    /// that follows a punctuation mark or a word of two letters or more counts: `x^{2}` and
    /// `10^{3}` are maths, and so is a unit's power, as `5 cm^{2}`.
    static func references(in text: String) -> [(range: NSRange, token: String, markers: [String], index: Int)] {
        let ns = text as NSString
        var found: [(NSRange, String, [String], Int)] = []
        var seen: [String: Int] = [:]
        raised.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, follows(ns, match.range.location), !power(ns, match.range) else { return }
            let token = ns.substring(with: match.range(at: 1))
            let markers = token.split(separator: ",", omittingEmptySubsequences: false).map { marker(String($0), letters: true) }
            guard !markers.isEmpty, markers.allSatisfy({ $0 != nil }) else { return }
            found.append((match.range, token, markers.compactMap { $0 }, seen[token, default: 0]))
            seen[token, default: 0] += 1
        }
        return found
    }

    private static let unit = try! NSRegularExpression(pattern: #"[0-9][  ]?[A-Za-zµμ]{1,3}$"#)

    /// A unit's square or cube after a number: `5 cm^{2}`, `3 km^{3}`.
    static func power(_ text: NSString, _ range: NSRange) -> Bool {
        let token = text.substring(with: range)
        guard token == "^{2}" || token == "^{3}" else { return false }
        let start = max(0, range.location - 6)
        let before = text.substring(with: NSRange(location: start, length: range.location - start))
        return match(unit, before) != nil
    }

    static func isSign(_ marker: String) -> Bool { marker.contains { signs.contains($0) } }

    /// Whether the character before `at` lets a note's marker follow it: a punctuation mark, a closing
    /// quote or a word of two letters or more. A closing bracket does not: `(a+b)^{2}` is maths.
    static func follows(_ text: NSString, _ at: Int) -> Bool {
        guard at > 0 else { return false }
        let before = Character(Unicode.Scalar(text.character(at: at - 1)) ?? " ")
        if ".,;:?!”’\"'»".contains(before) { return true }
        guard before.isLetter else { return false }
        var letters = 0
        var index = at - 1
        while index >= 0, let scalar = Unicode.Scalar(text.character(at: index)), Character(scalar).isLetter {
            letters += 1
            index -= 1
        }
        return letters >= 2
    }

    private static func size(_ block: TextBlock) -> Double? {
        let sizes = block.lines.compactMap(\.size).sorted()
        return sizes.isEmpty ? nil : sizes[sizes.count / 2]
    }

    /// The page's body size: the largest size that a twentieth of its characters or more have. On a page
    /// of law reviews and humanities, the footnotes can hold more characters than the text, and the
    /// most common size would be theirs.
    private static func body(_ sizes: [(size: Double, weight: Int)]) -> Double? {
        var weights: [Double: Int] = [:]
        for item in sizes { weights[(item.size * 2).rounded() / 2, default: 0] += item.weight }
        let total = weights.values.reduce(0, +)
        guard total >= 300 else { return nil }
        return weights.filter { $0.value * 20 >= total && $0.value >= 100 }.keys.max()
    }

    /// Whether a size is clearly smaller than the body's: a footnote's, a caption's.
    private static func small(_ size: Double?, body: Double) -> Bool {
        guard let size else { return false }
        return size <= body * 0.93 && size <= body - 0.5
    }

    /// Where a block must start for the notes to come apart: a line that starts with a raised
    /// number or sign in a size smaller than the page's text, as a footnote does; and, under a
    /// heading "Notes", a line that starts with the next number. Without them, a column of
    /// footnotes set with no gap between them joins into one block.
    static func starts(_ lines: [TextLayer.RawLine]) -> [Bool] {
        var result = [Bool](repeating: false, count: lines.count)
        let texts = lines.map { TextLayer.withoutMarks($0.text) }
        guard let body = body(zip(lines, texts).compactMap { line, text in line.size.map { ($0, text.count) } }) else { return result }
        // Lines that start with the next number, four in a row at least, as a page of endnotes does
        // under a heading on the page before: each begins a block.
        var chain: [Int] = []
        var previous: Int?
        for (index, text) in texts.enumerated() {
            guard let found = match(dottedStart, text), let number = Int((text as NSString).substring(with: found.range(at: 1))) else { continue }
            if let last = previous, number == last + 1 {
                chain.append(index)
            } else {
                chain = [index]
            }
            previous = number
            if chain.count >= 4 { for member in chain { result[member] = true } }
        }
        var listed = false
        var last: Int?
        // The number of the footnote before, in a run of small lines: the next bare number starts the next.
        var footnote: Int?
        for (index, text) in texts.enumerated() {
            let smaller = small(lines[index].size, body: body)
            let raisedStart = text.range(of: #"^\^\{(?:[0-9]{1,3}|[*†‡§¶‖#∗]{1,3})\}\s*\S"#, options: .regularExpression) != nil
            let opening = index == 0 || !small(lines[index - 1].size, body: body)
            if !smaller { footnote = nil }
            if match(heading, text.trimmingCharacters(in: .whitespaces)) != nil {
                listed = true
                last = nil
            } else if index > 0, smaller, raisedStart {
                result[index] = true
                footnote = Int(text.dropFirst(2).prefix { $0.isNumber })
            } else if listed, index > 0, let number = numbered(text)?.number, last == nil || number == last! + 1 {
                result[index] = true
                last = number
            } else if smaller, let found = match(numberStart, text) {
                let number = Int((text as NSString).substring(with: found.range(at: 1)))
                if opening {
                    footnote = number
                } else if let number, let previous = footnote, number == previous + 1, index > 0 {
                    result[index] = true
                    footnote = number
                }
            }
        }
        return result
    }

    /// An endnote's text split where the next numbers follow, one after another, with no line
    /// between: "… 2004). 35.AAL transcript …" makes two notes. Only the number after the last
    /// one counts, so a number in a citation splits nothing unless it is the next.
    static func split(_ text: String, after number: Int) -> [(number: Int, text: String)] {
        var parts: [(Int, String)] = []
        var current = number
        var rest = text
        while parts.count < 100 {
            let pattern = #"(?<=[.)\]”"’])\s*"# + String(current + 1) + #"\.\s*(?=[\p{L}“"(\[‘])"#
            guard let range = rest.range(of: pattern, options: .regularExpression) else { break }
            parts.append((current, String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)))
            rest = String(rest[range.upperBound...])
            current += 1
        }
        parts.append((current, rest.trimmingCharacters(in: .whitespaces)))
        return parts
    }

    /// The notes on a page, from its blocks and the regions it holds. A footnote is a block
    /// that starts with its marker, in the lower part of the page, set smaller than the page's
    /// text, with no text of the body's size below it in its column, and the smaller blocks
    /// that go on below it. An endnote is an entry of a run of numbers in order. A headnote is
    /// a short paragraph in a smaller size right under the page's first heading and above text
    /// of the body's size. A margin note is a block of three words or more wholly beside the
    /// body's columns. Pages read by OCR have no sizes, so no notes.
    static func find(_ blocks: [TextBlock], regions: [Region]) -> Found {
        var found = Found()
        let inside = Set(regions.flatMap { $0.caption + $0.blocks })
        guard
            let body = body(
                blocks.enumerated().compactMap { index, block in
                    !inside.contains(index) ? size(block).map { ($0, block.visibleText.count) } : nil
                })
        else { return found }
        func eligible(_ index: Int) -> Bool { !inside.contains(index) && (blocks[index].hidden ?? []).isEmpty }
        func isSmall(_ index: Int) -> Bool { small(size(blocks[index]), body: body) }
        func overlap(_ a: Box, _ b: Box) -> Double {
            let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
            return width <= 0 ? 0 : width / max(min(a.width, b.width), 0.0001)
        }
        func text(_ index: Int) -> String { blocks[index].visibleText.trimmingCharacters(in: .whitespacesAndNewlines) }
        var taken = Set<Int>()

        // The raised markers the page's text carries, to tell a footnote from a numbered list.
        var referred = Set<String>()
        for index in blocks.indices where eligible(index) {
            for reference in references(in: blocks[index].text) { referred.formUnion(reference.markers) }
        }

        // A table's notes, right under it, read as text after its block (FEATURES.md → F14).
        let tables = regions.filter { $0.kind == .table }.map(\.box)
        func underTable(_ box: Box) -> Bool {
            tables.contains { table in
                let gap = box.y - (table.y + table.height)
                return gap >= -0.01 && gap <= 0.04 && overlap(table, box) >= 0.5
            }
        }

        // The sizes of running text in the page's upper part, where no footnote stands.
        let upper = blocks.indices.filter { eligible($0) && blocks[$0].box.y < 0.4 && blocks[$0].visibleText.count >= 100 }
            .compactMap { size(blocks[$0]) }

        // Footnotes.
        var tried = 0
        for index in blocks.indices where !taken.contains(index) && eligible(index) && isSmall(index) && blocks[index].box.y >= 0.4 {
            // A page of thousands of small blocks costs no more than the first 200 their time.
            tried += 1
            guard tried <= 200 else { break }
            guard let lead = leading(text(index)),
                lead.raised || isSign(lead.marker) || referred.contains(lead.marker),
                !underTable(blocks[index].box)
            else { continue }
            // A number set as text, not raised, leads no note in a size the page sets running text
            // in above its lower part: a journal page set in 10 and 9 points starts a Methods
            // paragraph with a citation's number that lost its raise.
            if !lead.raised, !isSign(lead.marker), let own = size(blocks[index]), upper.contains(where: { abs($0 - own) <= 0.3 }) {
                continue
            }
            let block = blocks[index]
            // Body-size text below it in its column makes it a note to something, or a list.
            let bodyBelow = blocks.indices.contains { other in
                other != index && eligible(other) && !isSmall(other) && size(blocks[other]).map { $0 > body * 0.93 } == true
                    && blocks[other].visibleText.count >= 40 && blocks[other].box.y >= block.box.y + block.box.height - 0.01
                    && overlap(block.box, blocks[other].box) >= 0.5
            }
            guard !bodyBelow else { continue }
            var members = [index]
            var next = index + 1
            while next < blocks.count, eligible(next), isSmall(next), !taken.contains(next),
                blocks[next].box.y >= block.box.y - 0.01, overlap(block.box, blocks[next].box) >= 0.5,
                Furniture.pageNumber(text(next)) == nil,
                // Close below the note's last line: a conference's line or a licence under the
                // notes, set apart by a gap, is no part of them.
                blocks[next].box.y - (blocks[members.last!].box.y + blocks[members.last!].box.height)
                    <= 1.0 * blocks[members.last!].box.height / Double(max(blocks[members.last!].lines.count, 1))
            {
                if let again = leading(text(next)), again.raised || referred.contains(again.marker) || isSign(again.marker) { break }
                members.append(next)
                next += 1
            }
            taken.formUnion(members)
            found.notes.append(PageNote(kind: .footnote, marker: lead.marker, blocks: members))
        }

        // Endnotes: the entries after a heading "Notes", or all the page's, in a run of three
        // or more whose numbers go up. Only a document's reading decides which pages are lists
        // of notes, and which are lists of references: a heading, or a run that goes on.
        var after = 0
        for index in blocks.indices where eligible(index) && blocks[index].lines.count <= 2 && blocks[index].visibleText.count <= 60 {
            if match(heading, text(index)) != nil {
                found.heading = true
                after = index + 1
                break
            }
        }
        // A list ends at the next heading of another part: a list of references after the notes
        // is no notes.
        var end = blocks.count
        for index in blocks.indices where index >= after && blocks[index].lines.count <= 2 && match(otherHeading, text(index)) != nil {
            end = index
            found.ended = true
            break
        }
        // Every run of three or more numbers that go up, as a page holds where one chapter's notes
        // end and the next chapter's begin.
        var chain: [(index: Int, number: Int)] = []
        var runs: [[(index: Int, number: Int)]] = []
        for index in blocks.indices where index >= after && index < end && eligible(index) && !taken.contains(index) {
            guard let lead = numbered(text(index)) else { continue }
            if let last = chain.last, lead.number > last.number, lead.number <= last.number + 8 {
                chain.append((index, lead.number))
            } else {
                if chain.count >= 3 { runs.append(chain) }
                chain = [(index, lead.number)]
            }
        }
        if chain.count >= 3 { runs.append(chain) }
        let best = runs.flatMap { $0 }
        if !best.isEmpty {
            let entries = Set(best.map(\.index))
            for (position, item) in best.enumerated() {
                var members = [item.index]
                var next = item.index + 1
                let limit = position + 1 < best.count ? best[position + 1].index : end
                while next < limit, eligible(next), !taken.contains(next), !entries.contains(next),
                    size(blocks[next]) == size(blocks[item.index]), Furniture.pageNumber(text(next)) == nil
                {
                    members.append(next)
                    next += 1
                }
                taken.formUnion(members)
                let words = members.map { text($0) }.joined(separator: " ")
                let parts = split(numbered(words)?.rest ?? words, after: item.number)
                if parts.count > 1 {
                    for part in parts {
                        found.notes.append(PageNote(kind: .endnote, marker: String(part.number), blocks: members, text: part.text))
                    }
                } else {
                    found.notes.append(PageNote(kind: .endnote, marker: String(item.number), blocks: members))
                }
            }
        }

        // A headnote: the first heading's block, then a smaller paragraph, then text of the
        // body's size.
        if let heading = blocks.indices.first(where: { eligible($0) && blocks[$0].box.y >= 0.06 }),
            size(blocks[heading]).map({ $0 >= body * 1.15 }) == true, blocks[heading].lines.count <= 3,
            heading + 2 < blocks.count
        {
            let note = heading + 1
            let words = text(note).split(whereSeparator: \.isWhitespace).count
            let follows = blocks[note + 1]
            if eligible(note), !taken.contains(note), isSmall(note), blocks[note].lines.count >= 2, words >= 25,
                blocks[note].box.y < 0.5, match(abstractLabel, text(note)) == nil, leading(text(note)) == nil,
                size(follows).map({ $0 >= body * 0.97 }) == true, follows.visibleText.count >= 30
            {
                taken.insert(note)
                found.notes.append(PageNote(kind: .headnote, marker: nil, blocks: [note]))
            }
        }

        // Margin notes: wholly beside the columns of the body's text.
        // Lines set horizontally, which excludes a page of vertical text, whose columns read as margins.
        func horizontal(_ block: TextBlock) -> Bool {
            block.lines.filter { $0.box.width >= 2 * $0.box.height }.count * 10 >= block.lines.count * 7
        }
        // The columns' text is in the body's size, or the size most of the words of the page's wide
        // blocks have, where a lead paragraph in large type makes the body's size its own.
        var weights: [Double: Int] = [:]
        for index in blocks.indices where eligible(index) && blocks[index].box.width > 0.3 {
            if let size = size(blocks[index]) { weights[size, default: 0] += blocks[index].visibleText.count }
        }
        let running = min(body, weights.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? body)
        let columns = blocks.indices.filter {
            eligible($0) && size(blocks[$0]).map { $0 >= running * 0.93 } == true && blocks[$0].visibleText.count >= 40 && horizontal(blocks[$0])
        }
        if columns.count >= 3 {
            let lefts = columns.map { blocks[$0].box.x }.sorted()
            let rights = columns.map { blocks[$0].box.x + blocks[$0].box.width }.sorted()
            let left = lefts[lefts.count / 10]
            let right = rights[rights.count - 1 - rights.count / 10]
            for index in blocks.indices where eligible(index) && !taken.contains(index) {
                let block = blocks[index]
                // Words of running text, not a chart's labels, a table's cells or an abbreviation list's
                // capitals: four words of three letters or more with a lowercase one among them.
                let words = text(index).split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 && $0.contains(where: \.isLowercase) }.count
                guard words >= 4, block.box.width <= 0.3, horizontal(block), size(block).map({ $0 <= body * 1.1 }) == true,
                    true
                else { continue }
                if block.box.x + block.box.width <= left - 0.005 || block.box.x >= right + 0.005 {
                    taken.insert(index)
                    found.notes.append(PageNote(kind: .margin, marker: nil, blocks: [index]))
                }
            }
        }
        return found
    }

    // MARK: Judging notes against the document

    /// What a read needs of one parsed page to judge its notes against the others.
    struct Digest {
        var notes: [PageNote]
        var heading: Bool
        var ended = false
        /// The raised markers in the page's body blocks that name a marker, in reading order, in
        /// the text a reader sees.
        var references: [(block: Int, token: String, markers: [String], index: Int)]
        /// The first words of each note block, for the first pages only, to tell author notes.
        var texts: [Int: String]
    }

    static func digest(_ layer: PageText, index: Int) -> Digest {
        let notes = layer.notes ?? []
        let inNote = Set(notes.flatMap(\.blocks))
        let inside = Set((layer.regions ?? []).flatMap { $0.caption + $0.blocks })
        var references: [(Int, String, [String], Int)] = []
        for (block, item) in layer.blocks.enumerated() where !inNote.contains(block) && !inside.contains(block) {
            for found in Notes.references(in: item.visibleText) { references.append((block, found.token, found.markers, found.index)) }
        }
        var texts: [Int: String] = [:]
        if index < 2 {
            for note in notes where note.kind == .footnote {
                texts[note.blocks[0]] = note.blocks.compactMap { layer.blocks.indices.contains($0) ? layer.blocks[$0].visibleText : nil }.joined(
                    separator: " ")
            }
        }
        return Digest(
            notes: notes, heading: layer.noteHeading ?? false, ended: layer.noteListEnded ?? false, references: references, texts: texts)
    }

    /// A footnote of the first pages that tells about the authors: a sign for a marker, or
    /// words as "equal contribution" and "corresponding author".
    static func isAuthor(_ text: String, marker: String?) -> Bool {
        if let marker, isSign(marker) { return true }
        return text.range(
            of:
                #"(?i)equal(ly)? contribut|contributed equally|corresponding author|correspondence|e-?mail|@|joint first|co-first|work (was )?(done|performed|conducted)|present address|current address|affiliat"#,
            options: .regularExpression) != nil
    }

    /// Adds to `known` the digests of the pages cached under `keys` that it lacks.
    static func refresh(_ known: inout [Int: Digest], keys: [String], store: Store) throws {
        let missing = keys.indices.filter { known[$0] == nil }
        var from = 0
        while from < missing.count {
            let chunk = Array(missing[from..<min(from + 50, missing.count)])
            let results = try store.results(keys: chunk.map { keys[$0] })
            for page in chunk {
                if let layer = results[keys[page]]?.pageText { known[page] = digest(layer, index: page) }
            }
            from += 50
        }
    }

    /// The notes of each page asked for, counted from 0, judged against the pages parsed so far.
    /// Numbering that restarts, as in each chapter or on each page, starts a series, and ids then
    /// carry theirs, but the first's: "3.7" is the seventh note of the third series, "7" of the
    /// first. A list of endnotes is the notes under a heading "Notes", and the pages that go on
    /// from it with numbers that follow, of which the text cites one at least. A footnote's
    /// reference is the next raised marker of its number on its page; an endnote's, the last
    /// before its list, or before the reference of the note after it, in the pages that are no
    /// list (`align`).
    static func resolve(pages: [Int], digests: [Int: Digest]) -> [Int: PageNotes] {
        let order = digests.keys.sorted()

        // Which endnote entries are a list of notes.
        var kept: [Int: [PageNote]] = [:]
        var run: [Int: Int] = [:]
        var runs = 0
        var active = false
        var lastNumber = 0
        var previous = -2
        var ended = false
        for page in order {
            let digest = digests[page]!
            let entries = digest.notes.filter { $0.kind == .endnote }
            let first = entries.first.flatMap { $0.marker.flatMap(Int.init) }
            // A list goes on over the next page only, and not past another part's heading.
            if page != previous + 1 || ended { active = false }
            previous = page
            ended = digest.ended
            if digest.heading, !entries.isEmpty {
                // A running header "Notes to Chapter 1" heads every page of the list: a page that
                // follows one goes on from it.
                if !active { runs += 1 }
                active = true
            } else if active, let first, first == 1 || (first > lastNumber && first <= lastNumber + 40) {
                // The list goes on.
            } else {
                active = false
            }
            if active {
                kept[page] = entries
                run[page] = runs
                lastNumber = entries.last?.marker.flatMap(Int.init) ?? lastNumber
            }
        }

        struct Item {
            var page: Int
            var note: PageNote
            /// The list of endnotes it is in.
            var run: Int?
            /// The reference it was matched to, in `places`, and the others that lead to it.
            var place: Int? = nil
            var more: [Int] = []
            var series = 0
            /// For a sign that stands more than once on its page, which of them it is, from 1.
            var ordinal = 1
        }
        var items: [Item] = []
        for page in order {
            let notes = (digests[page]!.notes.filter { $0.kind == .footnote } + (kept[page] ?? [])).enumerated()
                .sorted { ($0.element.blocks[0], $0.offset) < ($1.element.blocks[0], $1.offset) }.map(\.element)
            for note in notes where note.marker != nil {
                items.append(Item(page: page, note: note, run: note.kind == .endnote ? run[page] : nil))
            }
        }

        // The references, in reading order.
        struct Place {
            var page: Int
            var block: Int
            var token: String
            var index: Int
            var markers: [String]
        }
        var places: [Place] = []
        var firstPlace: [Int: Int] = [:]
        for page in order {
            firstPlace[page] = places.count
            for reference in digests[page]!.references {
                places.append(Place(page: page, block: reference.block, token: reference.token, index: reference.index, markers: reference.markers))
            }
        }
        var taken = Set<String>()
        /// Matches the notes, in their order, to references among `candidates`, in theirs: each
        /// note takes the next reference of its marker that no note has, unless the next note's
        /// marker comes first, which means its own reference was lost: the notes after it still
        /// find theirs.
        func align(_ notes: [Int], _ candidates: [Int]) {
            var cursor = 0
            for (position, item) in notes.enumerated() {
                guard let marker = items[item].note.marker else { continue }
                let following = position + 1 < notes.count ? items[notes[position + 1]].note.marker : nil
                var at = cursor
                var found: Int?
                while at < candidates.count {
                    let place = places[candidates[at]]
                    if place.markers.contains(marker), !taken.contains("\(candidates[at])|\(marker)") {
                        found = at
                        break
                    }
                    if let following, following != marker, place.markers.contains(following),
                        !taken.contains("\(candidates[at])|\(following)")
                    {
                        break
                    }
                    at += 1
                }
                guard let found else { continue }
                taken.insert("\(candidates[found])|\(marker)")
                items[item].place = candidates[found]
                // The same reference may name the next note too, as `^{1,†}`.
                cursor = found
            }
        }
        // Footnotes, on their page.
        let byPage = Dictionary(grouping: items.indices.filter { items[$0].note.kind == .footnote }, by: { items[$0].page })
        for page in byPage.keys.sorted() {
            let start = firstPlace[page]!
            let range = start..<start + digests[page]!.references.count
            align(byPage[page]!, Array(range))
            // The page's other markers of a footnote's number lead to it too, as authors' to the
            // affiliation they share, where no other note of the page has that marker.
            let markers = Dictionary(grouping: byPage[page]!, by: { items[$0].note.marker! })
            for (marker, notes) in markers where notes.count == 1 && items[notes[0]].place != nil {
                for position in range where places[position].markers.contains(marker) && !taken.contains("\(position)|\(marker)") {
                    taken.insert("\(position)|\(marker)")
                    items[notes[0]].more.append(position)
                }
            }
        }
        // Endnotes: the most of them matched in order to references in the text that is no list,
        // each before its list (the longest common subsequence of their markers), and of such
        // matchings the one with the latest references, closest to each list. All the notes at
        // a book's end, or a chapter's after it, find their chapter's text, though a list between
        // was missed, and a chapter whose markers the text lost leaves its own notes unmatched,
        // not its neighbours'.
        let listPages = Set(run.keys)
        let byRun = Dictionary(grouping: items.indices.filter { items[$0].run != nil }, by: { items[$0].run! })
        let startOf = byRun.mapValues { $0.map { items[$0].page }.min()! }
        var elements: [(place: Int, marker: String)] = []
        for (position, place) in places.enumerated() where !listPages.contains(place.page) {
            for marker in place.markers where !taken.contains("\(position)|\(marker)") { elements.append((position, marker)) }
        }
        // Each marker's elements, latest first.
        var latest: [String: [Int]] = [:]
        for element in elements.indices.reversed() { latest[elements[element].marker, default: []].append(element) }
        // Hunt and Szymanski's method, from the end of both: `thresholds[k]` is the least distance
        // from the end at which a matching of k + 1 notes can stop so far.
        struct Link {
            var note: Int
            var element: Int
            var previous: Int?
        }
        var links: [Link] = []
        var thresholds: [Int] = []
        var ends: [Int] = []
        for note in byRun.keys.sorted().flatMap({ byRun[$0]! }).reversed() {
            let start = firstPlace[startOf[items[note].run!]!] ?? places.count
            // A reference within the 400 latest of its marker before the list: no chapter is so far back.
            let candidates = Array((latest[items[note].note.marker!] ?? []).lazy.filter { elements[$0].place < start }.prefix(400))
            // Farthest from the end first, so a note extends no matching it is already in.
            for element in candidates.reversed() {
                let distance = elements.count - 1 - element
                var low = 0
                var high = thresholds.count
                while low < high {
                    let middle = (low + high) / 2
                    if thresholds[middle] < distance { low = middle + 1 } else { high = middle }
                }
                links.append(Link(note: note, element: element, previous: low > 0 ? ends[low - 1] : nil))
                if low == thresholds.count {
                    thresholds.append(distance)
                    ends.append(links.count - 1)
                } else {
                    thresholds[low] = distance
                    ends[low] = links.count - 1
                }
            }
        }
        var link = ends.last
        var matchedElement: [Int: Int] = [:]
        while let current = link {
            items[links[current].note].place = elements[links[current].element].place
            matchedElement[links[current].note] = links[current].element
            taken.insert("\(elements[links[current].element].place)|\(elements[links[current].element].marker)")
            link = links[current].previous
        }
        // A series of notes cites one stretch of text. Where its references straddle a "1" that
        // starts the text's numbering again, it took an earlier chapter's markers for want of a
        // few of its own: it keeps those after that "1", and its notes before them match from there.
        // A "1" that a 2 follows within the next 5 markers, and a 3 within 5 after, in 3 pages: a
        // lone `^{1}`, as a figure's or a stray one, starts nothing.
        func near(_ marker: String, after start: Int, from origin: Int) -> Int? {
            elements[(start + 1)..<min(start + 6, elements.count)].firstIndex {
                $0.marker == marker && places[$0.place].page <= places[elements[origin].place].page + 3
            }
        }
        let restarts = elements.indices.filter { start in
            guard elements[start].marker == "1", let two = near("2", after: start, from: start) else { return false }
            return near("3", after: two, from: start) != nil
        }
        for number in byRun.keys.sorted() {
            var series: [[Int]] = []
            var last = Int.max
            for note in byRun[number]! {
                let value = Int(items[note].note.marker!) ?? 0
                if value <= last { series.append([]) }
                series[series.count - 1].append(note)
                last = value
            }
            for notes in series {
                let matched = notes.compactMap { matchedElement[$0] }
                guard let first = matched.first, let end = matched.last,
                    let restart = restarts.last(where: { $0 > first && $0 < end && !matched.contains($0) })
                else { continue }
                for note in notes {
                    guard let element = matchedElement[note], element < restart else { continue }
                    taken.remove("\(elements[element].place)|\(elements[element].marker)")
                    items[note].place = nil
                    matchedElement[note] = nil
                }
                let kept = notes.first { matchedElement[$0] != nil }
                let stop = kept.flatMap { matchedElement[$0] }.map { elements[$0].place } ?? elements[restart].place
                let window = (elements[restart].place...max(stop, elements[restart].place)).filter { !listPages.contains(places[$0].page) }
                align(Array(notes.prefix { matchedElement[$0] == nil }), window)
            }
        }
        // A list that the text never cites is none: a numbered list of steps under a heading "Notes".
        let cited = Set(items.filter { $0.place != nil }.compactMap(\.run))
        items.removeAll { $0.run.map { !cited.contains($0) } ?? false }

        // The numbering's series. A sign names a note by itself, or by its page where the sign
        // stands on more than one page or twice on one: only numbers make series.
        var series = 0
        var highest = 0
        var lastRun: Int?
        var signPages: [String: Set<Int>] = [:]
        var signsOnPage: [String: Int] = [:]
        for position in items.indices {
            let marker = items[position].note.marker!
            guard let number = Int(marker) else {
                let page = items[position].page
                signPages[marker, default: []].insert(page)
                signsOnPage["\(page)|\(marker)", default: 0] += 1
                items[position].ordinal = signsOnPage["\(page)|\(marker)"]!
                continue
            }
            // Numbering restarts where a number does not go up, or a list of endnotes begins.
            var restart = number <= highest
            if items[position].note.kind == .endnote {
                if items[position].run != lastRun { restart = true }
                lastRun = items[position].run
            }
            if restart || series == 0 {
                series += 1
                highest = 0
            }
            highest = max(highest, number)
            items[position].series = series
        }
        func id(_ item: Item) -> String {
            let marker = item.note.marker ?? ""
            if item.series == 0 {
                let several = (signPages[marker]?.count ?? 0) > 1 || (signsOnPage["\(item.page)|\(marker)"] ?? 0) > 1
                return several ? "p\(item.page + 1)\(marker)" + (item.ordinal > 1 ? "\(item.ordinal)" : "") : marker
            }
            // The first series goes unprefixed, so an id does not change while later pages parse.
            return item.series > 1 ? "\(item.series).\(marker)" : marker
        }
        var identified: [String: [String: String]] = [:]
        for item in items {
            guard let position = item.place, let marker = item.note.marker else { continue }
            for position in [position] + item.more {
                let place = places[position]
                identified["\(place.page).\(place.block).\(place.token).\(place.index)", default: [:]][marker] = id(item)
            }
        }

        var result: [Int: PageNotes] = [:]
        for page in pages {
            guard let digest = digests[page] else { continue }
            var notes = PageNotes()
            let numbered = items.filter { $0.page == page }
            var entries: [(first: Int, entry: PageNotes.Entry)] = []
            for item in numbered {
                let text = digest.texts[item.note.blocks[0]] ?? ""
                let author = item.note.kind == .footnote && page < 2 && isAuthor(text, marker: item.note.marker)
                entries.append(
                    (
                        item.note.blocks[0],
                        PageNotes.Entry(kind: item.note.kind, id: id(item), blocks: item.note.blocks, text: item.note.text, author: author)
                    ))
            }
            for note in digest.notes where note.kind == .headnote || note.kind == .margin {
                entries.append((note.blocks[0], PageNotes.Entry(kind: note.kind, id: nil, blocks: note.blocks)))
            }
            notes.entries = entries.enumerated().sorted { ($0.element.first, $0.offset) < ($1.element.first, $1.offset) }.map(\.element.entry)
            for reference in digest.references {
                guard let ids = identified["\(page).\(reference.block).\(reference.token).\(reference.index)"],
                    reference.markers.allSatisfy({ ids[$0] != nil })
                else { continue }
                notes.references[reference.block, default: []].append(
                    PageNotes.Reference(token: reference.token, ids: reference.markers.compactMap { ids[$0] }, index: reference.index))
            }
            if !notes.entries.isEmpty || !notes.references.isEmpty { result[page] = notes }
        }
        return result
    }

    /// A block's text with its references to notes written `[^7]`: each the raised marker of its
    /// token and its place among the block's references with that token.
    static func linked(_ text: String, _ references: [PageNotes.Reference]) -> String {
        guard !references.isEmpty else { return text }
        let found = Notes.references(in: text)
        var replacements: [(range: NSRange, text: String)] = []
        for reference in references {
            guard let place = found.first(where: { $0.token == reference.token && $0.index == reference.index }) else { continue }
            replacements.append((place.range, reference.ids.map { "[^\($0)]" }.joined()))
        }
        // From the end, so the places before stay where they are.
        var result = text as NSString
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: replacement.range, with: replacement.text) as NSString
        }
        return result as String
    }

    /// A note's text: its blocks' visible text joined, without the marker it starts with.
    static func text(of kind: PageNote.Kind, blocks members: [Int], in layer: PageText) -> String {
        var texts = members.filter(layer.blocks.indices.contains).map {
            layer.blocks[$0].visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !texts.isEmpty else { return "" }
        texts[0] = (kind == .footnote ? leading(texts[0])?.rest : numbered(texts[0])?.rest) ?? texts[0]
        return texts.joined(separator: " ")
    }

    public static func text(of entry: PageNotes.Entry, in layer: PageText) -> String {
        entry.text ?? text(of: entry.kind, blocks: entry.blocks, in: layer)
    }
}

/// A document's notes as a read sees them, kept across the chunks of pages it fetches so each
/// page's notes are read from the cache once.
public struct NoteIndex {
    var digests: [Int: Notes.Digest] = [:]

    public init() {}

    /// The notes of the pages asked for, counted from 0, judged against the pages parsed so far.
    public mutating func resolve(pages: [Int], keys: [String], store: Store) throws -> [Int: PageNotes] {
        try Notes.refresh(&digests, keys: keys, store: store)
        guard digests.values.contains(where: { !$0.notes.isEmpty }) else { return [:] }
        return Notes.resolve(pages: pages, digests: digests)
    }

    /// One note, found by its id, with the places that refer to it.
    public struct Found: Encodable, Equatable, Sendable {
        public struct Place: Encodable, Equatable, Sendable {
            /// Counted from 1.
            public var page: Int
            public var block: Int
            /// The words around the reference.
            public var excerpt: String
        }

        public var id: String
        /// "footnote", "endnote" or "author note".
        public var kind: String
        /// Counted from 1.
        public var page: Int
        public var text: String
        public var references: [Place]
        /// Pages of the file are not parsed yet, so the note's id and its references can change.
        public var provisional: Bool? = nil
    }

    public enum Outcome: Equatable, Sendable {
        case found(Found)
        /// No note has this id; these are the ids the document has, in order.
        case missing([String])
        /// The id is a number several series of notes each have; these are the ids that match.
        case ambiguous([String])
    }

    /// The footnote or endnote an id names: "7", or "3.7" in a document whose numbering
    /// restarts. A number alone names the note when only one series has it.
    public mutating func lookup(_ id: String, keys: [String], store: Store) throws -> Outcome {
        try Notes.refresh(&digests, keys: keys, store: store)
        let wanted = id.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "∗", with: "*")
        let judged = Notes.resolve(pages: Array(digests.keys), digests: digests)
        var all: [(page: Int, entry: PageNotes.Entry)] = []
        for page in judged.keys.sorted() {
            for entry in judged[page]!.entries where entry.id != nil { all.append((page, entry)) }
        }
        let ids = all.compactMap(\.entry.id)
        // "7" also names "3.7", so it names a note alone only when one series has a 7; "*" names
        // "p3*", a sign's id on one of the pages it stands on.
        func named(_ id: String) -> Bool {
            if id.hasSuffix("." + wanted) { return true }
            guard id.hasPrefix("p"), !wanted.isEmpty else { return false }
            let rest = id.dropFirst().drop(while: \.isNumber)
            return rest.hasPrefix(wanted) && rest.dropFirst(wanted.count).allSatisfy(\.isNumber)
        }
        var matches = all.filter { $0.entry.id == wanted }
        let others = all.filter { $0.entry.id != wanted && named($0.entry.id!) }
        if matches.isEmpty || Int(wanted) != nil { matches += others }
        guard let match = matches.first else { return .missing(ids) }
        guard matches.count == 1 else { return .ambiguous(matches.map { $0.entry.id! }) }
        let layer = try store.results(keys: [keys[match.page]])[keys[match.page]]?.pageText
        let entryID = match.entry.id!
        var places: [Found.Place] = []
        for page in judged.keys.sorted() {
            let found = judged[page]!.references.filter { $0.value.contains { $0.ids.contains(entryID) } }
            guard !found.isEmpty else { continue }
            let source = page == match.page ? layer : try store.results(keys: [keys[page]])[keys[page]]?.pageText
            for block in found.keys.sorted() {
                guard let source, source.blocks.indices.contains(block) else { continue }
                let text = Notes.linked(source.blocks[block].visibleText, judged[page]!.references[block] ?? [])
                var excerpt = text
                if let range = text.range(of: "[^\(entryID)]") {
                    let before = text[..<range.lowerBound].suffix(70)
                    let after = text[range.upperBound...].prefix(70)
                    excerpt = (before.count == 70 ? "…" : "") + before + "[^\(entryID)]" + after + (after.count == 70 ? "…" : "")
                }
                places.append(Found.Place(page: page + 1, block: block + 1, excerpt: excerpt))
            }
        }
        let kind = match.entry.author ? "author note" : match.entry.kind.rawValue
        return .found(
            Found(
                id: entryID, kind: kind, page: match.page + 1,
                text: layer.map { Notes.text(of: match.entry, in: $0) } ?? "",
                references: places))
    }
}
