import ArgumentParser
import Foundation
import PDFCore

/// Prints a PDF's text in reading order, every block with its page and position (FEATURES.md →
/// F3), within a token budget (DESIGNS.md → Decision: a 5,000-token default budget).
struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a PDF's text, every block with its page and position.",
        discussion: """
            Without --page, reading starts at the first page. Output stops at about 5,000 tokens and ends with \
            the command that goes on from there; --budget all turns the limit off.
            """
    )

    enum Format: String, ExpressibleByArgument {
        case md, text
    }

    enum NotesOption: String, ExpressibleByArgument {
        case end, inline, off
    }

    enum RefsOption: String, ExpressibleByArgument {
        case end, off
    }

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(name: .customLong("page"),
            help: ArgumentHelp("Pages by their position in the file, such as 3, 3-5 or 3,7-9. The flag can repeat.",
                               valueName: "pages"))
    var pageSpecs: [String] = []
    @Option(name: .customLong("printed-page"), help: ArgumentHelp("A page by the number printed on it, such as 237 or iv.", valueName: "label"))
    var printedPage: String?
    @Option(help: ArgumentHelp("A section by its number or its title, such as 2.1 or Method, as pdf info lists them.",
                               valueName: "section"))
    var section: String?
    @Flag(help: "Read the whole document, page after page, within the budget.") var full = false
    @Option(help: ArgumentHelp("Stop at about N tokens, or all for no limit.", valueName: "N")) var budget = "5000"
    @Option(help: ArgumentHelp("Go on from where a read stopped, as its next: line says, such as p4.7.", valueName: "address"))
    var from: String?
    @Option(help: "The output format: md or text.") var format: Format = .md
    @Flag(help: "Show the text set aside as doubtful, labelled with its reason.") var raw = false
    @Flag(help: "Show the words of text a reader cannot see, labelled, in place of their markers.") var includeHidden = false
    @Flag(help: "Show the running headers, footers, page numbers and publisher stamps in place, labelled.") var headers = false
    @Option(
        help: ArgumentHelp(
            "Where footnotes and endnotes show: end of the output, inline by the paragraph that refers to each, or off.",
            valueName: "end|inline|off"))
    var notes: NotesOption = .end
    @Option(
        help: ArgumentHelp(
            "Show one footnote or endnote, as 7 or 3.7 where numbering restarts, with the places that refer to it.",
            valueName: "id"))
    var footnote: String?
    @Option(
        help: ArgumentHelp(
            "List the entries of the reference list that the text shown cites, after it, or not (the default).",
            valueName: "end|off"))
    var refs: RefsOption = .off
    @Option(
        help: ArgumentHelp(
            "Show one entry of the reference list, as 12, BK06 or Smith2020, with its DOI and the places that cite it.",
            valueName: "id"))
    var ref: String?
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        guard Self.tokens(budget) != nil else { throw ValidationError("--budget takes a number of tokens, or all") }
        if let from, Self.place(from) == nil {
            throw ValidationError("--from takes an address such as p4, p4.7 or p4.7:120")
        }
        if pageSpecs.contains(where: { Self.pages($0) == nil }) {
            throw ValidationError("--page takes pages such as 3, 3-5 or 3,7-9")
        }
        let scopes = [!pageSpecs.isEmpty, printedPage != nil, section != nil, full].filter { $0 }.count
        if scopes > 1 { throw ValidationError("choose one of --page, --printed-page, --section and --full") }
        if footnote != nil, scopes > 0 || from != nil {
            throw ValidationError("--footnote reads the whole document for the note: it takes no --page, --printed-page, --section, --full or --from")
        }
        if footnote != nil, notes != .end || budget != "5000" || raw || headers || includeHidden || format != .md {
            throw ValidationError("--footnote shows one note whole: it takes only --json")
        }
        if let footnote, footnote.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--footnote takes a note's id, such as 7, 3.7 or *")
        }
        if ref != nil, footnote != nil { throw ValidationError("choose one of --footnote and --ref") }
        if ref != nil, scopes > 0 || from != nil {
            throw ValidationError("--ref reads the whole document for the entry: it takes no --page, --printed-page, --section, --full or --from")
        }
        if ref != nil, notes != .end || refs != .off || budget != "5000" || raw || headers || includeHidden || format != .md {
            throw ValidationError("--ref shows one entry whole: it takes only --json")
        }
        if footnote != nil, refs != .off { throw ValidationError("--footnote shows one note whole: it takes only --json") }
        if let ref, ref.trimmingCharacters(in: CharacterSet(charactersIn: " []")).isEmpty {
            throw ValidationError("--ref takes an entry's id, such as 12, BK06 or Smith2020")
        }
    }

    func run() throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        if let footnote { return try self.footnote(footnote) }
        if let ref { return try self.reference(ref) }
        let resume = from.flatMap(Self.place)
        var wanted: [Int] = []
        for number in pageSpecs.flatMap({ Self.pages($0)! }) where !wanted.contains(number) { wanted.append(number) }
        let first = resume?.page ?? wanted.first ?? 1

        // The first page tells the page count, and starts the parse of a file not seen before.
        let docID: String, pageCount: Int
        switch try reader.read(path: path, pages: [first - 1]) {
        case .fileFailed(let reason):
            print(json ? Self.failureJSON(path, reason) : "\(path): failed: \(Output.failure(reason, file: path))")
            throw ExitCode(3)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }
        var start = resume
        var until: (page: Int, block: Int)?
        var scope = ""
        if let printedPage {
            wanted = [try Self.printed(printedPage, path: path, pageCount: pageCount, store: store)]
            scope = " --printed-page " + Output.quoted(printedPage)
        } else if let section {
            let (found, end) = try Self.section(section, path: path, docID: docID, pageCount: pageCount, store: store,
                                                reader: reader)
            let last = end.map { $0.block <= 1 ? max($0.page - 1, found.page) : $0.page } ?? pageCount
            wanted = Array(found.page...max(last, found.page))
            until = end
            if start == nil { start = (page: found.page, block: found.block, offset: nil) }
            scope = " --section " + Output.quoted(section)
        } else if !wanted.isEmpty {
            scope = "pages"
        }
        var numbers = wanted.isEmpty ? Array(1...max(pageCount, 1)) : wanted
        if let bad = numbers.first(where: { $0 > pageCount }) {
            throw ReadError.pageOutOfRange(page: bad - 1, pageCount: pageCount)
        }
        if let start {
            guard let position = numbers.firstIndex(of: start.page) else {
                throw ValidationError("--from p\(start.page) is not among the pages to read")
            }
            numbers.removeFirst(position)
        }

        let keys = try store.pageKeys(docID: docID)
        // The file's annotations, from its facts, which belong to this version of the file.
        let resolved = Reader.resolve(path)
        let facts = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }
        let annotations = Dictionary(grouping: facts?.annotations ?? [], by: \.page)
        let limit = Self.tokens(budget)!
        let picks = try Picks().picks(keys: keys)
        let transcripts = try Transcripts().transcripts(keys: keys)
        let flags =
            (raw ? " --raw" : "") + (includeHidden ? " --include-hidden" : "") + (headers ? " --headers" : "")
            + (notes == .end ? "" : " --notes \(notes.rawValue)")
            + (refs == .off ? "" : " --refs \(refs.rawValue)")
            + (format == .text ? " --format text" : "")
            + (budget == "5000" ? "" : " --budget \(budget)")
        let quotedPath = Output.quoted(path)
        let order = numbers
        let named = scope
        var document = Output.Document(
            file: path, pageCount: pageCount, style: format == .md ? .md : .text, raw: raw, includeHidden: includeHidden,
            headers: headers, notes: Output.NotesMode(rawValue: notes.rawValue) ?? .end,
            refs: Output.RefsMode(rawValue: refs.rawValue) ?? .off, picks: picks,
            transcripts: transcripts, budget: limit,
            continuation: { page, block, offset in
                let rest = named == "pages" ? " --page " + Self.spec(Array(order.drop { $0 != page })) : named
                return "pdf read \(quotedPath)\(rest) --from \(Output.address(page: page, block: block, offset: offset))\(flags)"
            })
        document.until = until

        // Pages are fetched a few at a time, so a read that the budget stops early waits only
        // for the pages it shows.
        let batch = max(1, min(8, (limit ?? 40_000) / 1_000))
        var index = 0
        var noteIndex = NoteIndex()
        var referenceIndex = ReferenceIndex(outline: facts?.outline ?? [])
        let everyPage = Array(0..<pageCount)
        reading: while index < numbers.count {
            let chunk = Array(numbers[index..<min(index + batch, numbers.count)])
            // The file can change or go away between chunks. Pages of another version must not
            // join this read, so the read stops there, loudly, with the command that goes on.
            let outcome = try? reader.read(path: path, pages: chunk.map { $0 - 1 })
            guard case .pages(let id, _, let results)? = outcome, id == docID else {
                document.stop(at: chunk[0], because: "the file changed or could not be read; the command below reads on from here")
                break
            }
            // Running headers and footers, judged against the pages around these that are parsed.
            let furniture = (try? Furniture.find(pages: results.map(\.page), keys: keys, store: store)) ?? [:]
            // Footnotes, endnotes and the rest, judged against the pages parsed so far, and the
            // citations of the list of references, whose raised markers lead to no note.
            let judged = (try? noteIndex.resolve(pages: everyPage, keys: keys, store: store)) ?? [:]
            try? referenceIndex.refresh(keys: keys, store: store)
            let cited = referenceIndex.resolve(pages: results.map(\.page), notes: judged)
            for (page, result) in results {
                let resume = index == 0 && page + 1 == start?.page
                let added = document.add(
                    Output.Page(
                        index: page, result: result, key: keys[page], annotations: annotations[page] ?? [],
                        furniture: furniture[page] ?? [:], notes: judged[page] ?? PageNotes(), citations: cited[page] ?? PageCitations()),
                    from: resume ? start?.block : nil, offset: resume ? start?.offset : nil)
                if !added { break reading }
                index += 1
                if let until, page + 1 >= until.page { break reading }
            }
        }

        let cached = try store.cachedKeys(keys)
        let parsed = keys.filter { cached.contains($0) }.count
        let savedByPDFKit = try store.savedByPDFKit(docID: docID)
        let report = document.report(savedByPDFKit: savedByPDFKit, parsed: parsed)
        if json {
            print(String(decoding: try document.json(savedByPDFKit: savedByPDFKit, parsed: parsed), as: UTF8.self))
        } else {
            print(report.text, terminator: "")
        }
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }

    /// One footnote or endnote by its id, with the places that refer to it, from the whole
    /// document: every page is parsed first, as a section's end needs.
    func footnote(_ id: String) throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let docID: String
        let pageCount: Int
        switch try reader.read(path: path, pages: [0]) {
        case .fileFailed(let reason):
            print(json ? Self.failureJSON(path, reason) : "\(path): failed: \(Output.failure(reason, file: path))")
            throw ExitCode(3)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }
        _ = try reader.read(path: path, pages: nil)
        let keys = try store.pageKeys(docID: docID)
        // Pages alike share a key, so the pages parsed are counted by page, as a read counts them.
        let cached = try store.cachedKeys(keys)
        let parsed = keys.filter { cached.contains($0) }.count
        var index = NoteIndex()
        let outcome = try index.lookup(id, keys: keys, store: store)
        let provisional = parsed < pageCount ? " · provisional: \(parsed) of \(pageCount) pages parsed" : ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        switch outcome {
        case .found(var note):
            if json {
                if parsed < pageCount { note.provisional = true }
                print(String(decoding: try encoder.encode(note), as: UTF8.self))
                return
            }
            var lines = ["\(path) · \(note.kind) \(note.id) · p.\(note.page)\(provisional)", "[^\(note.id)] \(note.text)"]
            if note.references.isEmpty {
                lines.append("referenced: no raised marker of this number was found in the text")
            } else {
                lines.append("referenced:")
                lines += note.references.map { "  p.\($0.page) ¶\($0.block): \($0.excerpt)" }
            }
            print(lines.joined(separator: "\n\n").replacingOccurrences(of: "\n\nreferenced:\n\n", with: "\n\nreferenced:\n"))
        case .missing(let ids):
            throw ValidationError(
                "no footnote or endnote is \(id)"
                    + (ids.isEmpty
                        ? "; the file has none"
                        : "; it has " + ids.prefix(12).joined(separator: ", ") + (ids.count > 12 ? ", and \(ids.count - 12) more" : "")))
        case .ambiguous(let ids):
            throw ValidationError("\(id) names notes in several series of numbering; use one of " + ids.joined(separator: ", "))
        }
    }

    /// One entry of the list of references by its id, with its DOI and the places that cite it,
    /// from the whole document: every page is parsed first, as for a note.
    func reference(_ id: String) throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let docID: String
        let pageCount: Int
        switch try reader.read(path: path, pages: [0]) {
        case .fileFailed(let reason):
            print(json ? Self.failureJSON(path, reason) : "\(path): failed: \(Output.failure(reason, file: path))")
            throw ExitCode(3)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }
        _ = try reader.read(path: path, pages: nil)
        let keys = try store.pageKeys(docID: docID)
        let cached = try store.cachedKeys(keys)
        let parsed = keys.filter { cached.contains($0) }.count
        let resolved = Reader.resolve(path)
        let facts = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }
        var notes = NoteIndex()
        let judged = try notes.resolve(pages: Array(0..<pageCount), keys: keys, store: store)
        var index = ReferenceIndex(outline: facts?.outline ?? [])
        try index.refresh(keys: keys, store: store)
        let outcome = try index.lookup(id, notes: judged, keys: keys, store: store, links: facts?.annotations ?? [])
        let provisional = parsed < pageCount ? " · provisional: \(parsed) of \(pageCount) pages parsed" : ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        switch outcome {
        case .found(var entry):
            if json {
                if parsed < pageCount { entry.provisional = true }
                print(String(decoding: try encoder.encode(entry), as: UTF8.self))
                return
            }
            var lines = ["\(path) · reference \(entry.id) · p.\(entry.page)\(provisional)", "[\(entry.id)] \(entry.text)"]
            if let doi = entry.doi { lines.append("doi: \(doi)") }
            if entry.citations.isEmpty {
                lines.append("cited: no citation of it was found in the text")
            } else {
                lines.append("cited:\n" + entry.citations.map { "  p.\($0.page) ¶\($0.block): \($0.excerpt)" }.joined(separator: "\n"))
            }
            print(lines.joined(separator: "\n\n"))
        case .missing(let ids):
            throw ValidationError(
                "no entry of the reference list is \(id)"
                    + (ids.isEmpty
                        ? "; the file has no list of references found so far"
                        : "; it has " + ids.prefix(12).joined(separator: ", ") + (ids.count > 12 ? ", and \(ids.count - 12) more" : "")))
        case .ambiguous(let ids):
            throw ValidationError("\(id) names several entries; use one of " + ids.prefix(20).joined(separator: ", "))
        }
    }

    /// The page, counted from 1, that bears a printed number, from the file's page labels. A file
    /// without labels prints each page's position.
    static func printed(_ label: String, path: String, pageCount: Int, store: Store) throws -> Int {
        let resolved = Reader.resolve(path)
        let labels = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }?.labels
        if let labels, let index = labels.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            return index + 1
        }
        if labels == nil, let number = Int(label), (1...pageCount).contains(number) { return number }
        throw ValidationError("no page is printed \(label)" + (labels == nil ? "; the file has no page labels" : ""))
    }

    /// The section a `--section` value names, and where the next section at its level or above
    /// starts. Bookmarks name sections at once; headings in the text need every page parsed.
    static func section(_ query: String, path: String, docID: String, pageCount: Int, store: Store,
                        reader: Reader) throws -> (Section, (page: Int, block: Int)?) {
        func look() throws -> Info { try InfoCommand.info(path: path, docID: docID, pageCount: pageCount, store: store) }
        var info = try look()
        if info.sectionsFrom != "bookmarks" && info.pagesParsed < pageCount {
            _ = try reader.read(path: path, pages: nil)
            info = try look()
        }
        var sections = info.sections
        if Info.find(query, in: sections) == nil && info.sectionsFrom == "bookmarks" {
            // Bookmarks often leave out the numbers that the headings print, as in "2 Related
            // Work", so the headings in the text get a try too.
            _ = try reader.read(path: path, pages: nil)
            sections = Info.textSections(try InfoCommand.cachedPages(docID: docID, store: store), pageCount: pageCount)
        }
        guard var found = Info.find(query, in: sections) else {
            let known = sections.filter { $0.level <= 2 }.prefix(12).map(\.title)
            throw ValidationError("no section matches \(query)" + (known.isEmpty ? "; the file has no bookmarks or numbered headings"
                : "; sections: " + known.joined(separator: ", ")))
        }
        // A bookmark's block shows once its page is parsed, and so does the next section's.
        var needed = found.block == nil ? [found.page - 1] : []
        if let next = Info.next(after: found, in: sections), next.block == nil { needed.append(next.page - 1) }
        if !needed.isEmpty {
            _ = try reader.read(path: path, pages: needed)
            sections = try look().sections
            found = Info.find(query, in: sections) ?? found
        }
        // A next section on a page that failed has no block, so its whole page is read: the
        // failure block shows there, and nothing of this section is cut off unseen.
        guard let position = sections.firstIndex(of: found) else { return (found, nil) }
        return (found, Info.stop(position, in: sections).map { stop in stop.block.map { (stop.page, $0) } ?? (stop.page + 1, 1) })
    }

    /// A budget in tokens: nil inside for no limit, nil outside for a value that is neither.
    static func tokens(_ text: String) -> Int?? {
        if text == "all" { return .some(nil) }
        guard let value = Int(text), value > 0 else { return nil }
        return .some(value)
    }

    /// Page numbers from "3", "3-5" or "3,7-9", counted from 1. A page past 100,000 is refused
    /// before any range is spelled out, since no PDF has that many.
    static func pages(_ text: String) -> [Int]? {
        var numbers: [Int] = []
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (1...2).contains(ends.count), let low = ends[0], let high = ends.last!, low >= 1, high >= low,
                  high <= 100_000 else { return nil }
            numbers += Array(low...high)
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// Page numbers as the shortest spec, such as "15-20" or "15,17-19".
    static func spec(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        while index < numbers.count {
            var end = index
            while end + 1 < numbers.count && numbers[end + 1] == numbers[end] + 1 { end += 1 }
            parts.append(end > index ? "\(numbers[index])-\(numbers[end])" : "\(numbers[index])")
            index = end + 1
        }
        return parts.joined(separator: ",")
    }

    /// "p4", "p4.7" or "p4.7:120" as page, block and character, each counted from 1 but the
    /// character, counted from 0.
    static func place(_ text: String) -> (page: Int, block: Int?, offset: Int?)? {
        guard text.hasPrefix("p") else { return nil }
        let main = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(main.count) else { return nil }
        let parts = main[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let page = Int(parts[0]), page >= 1 else { return nil }
        let block = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2 && (block ?? 0) < 1 { return nil }
        let offset = main.count == 2 ? Int(main[1]) : nil
        if main.count == 2 && (offset == nil || block == nil || offset! < 0) { return nil }
        return (page, block, offset)
    }

    static func failureJSON(_ path: String, _ reason: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let body = ["file": path, "failed": Output.failure(reason, file: path)]
        return (try? encoder.encode(body)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
