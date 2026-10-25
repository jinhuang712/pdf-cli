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

            Which part: --page, --printed-page, --section, --full, --from.
            How much and in what form: --budget, --format, --json.
            Set-aside text, shown on request: --show raw,hidden,headers.
            Notes and references: --notes, --refs. To look up one note or entry: pdf note, pdf ref.

            Examples:
              pdf read paper.pdf --section Method
              pdf read paper.pdf --page 3-5 --notes inline
              pdf read paper.pdf --budget all --format text
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
    @Option(
        name: .customLong("show"),
        help: ArgumentHelp(
            "Show what is set aside, in place and labelled: raw (text set aside: doubtful, inside figures and tables, a replaced text layer), hidden (the words of text a reader cannot see) and headers (running headers, footers, page numbers, publisher stamps). A comma list, such as raw,hidden; the flag can repeat.",
            valueName: "raw|hidden|headers"))
    var shows: [String] = []
    @Option(
        help: ArgumentHelp(
            "Where footnotes and endnotes show: end of the output, inline by the paragraph that refers to each, or off.",
            valueName: "end|inline|off"))
    var notes: NotesOption = .end
    @Option(
        help: ArgumentHelp(
            "List the entries of the reference list that the text shown cites, after it, or not (the default).",
            valueName: "end|off"))
    var refs: RefsOption = .off
    @Flag(help: "Print JSON.") var json = false
    // The removed flags stay only to point to their commands (M2.16): hidden, they run nothing.
    @Option(help: .private) var footnote: String?
    @Option(help: .private) var ref: String?
    // The same for the three flags that `--show` took over (M2.17).
    @Flag(name: .customLong("raw"), help: .private) var removedRaw = false
    @Flag(name: .customLong("include-hidden"), help: .private) var removedIncludeHidden = false
    @Flag(name: .customLong("headers"), help: .private) var removedHeaders = false

    /// What `--show` asks for (DESIGNS.md → Decision: `--show` shows what was set aside, M2.17).
    static let shownValues = ["raw", "hidden", "headers"]
    /// The values of every `--show`, split at commas; nil when one is not a known value.
    static func shown(_ specs: [String]) -> Set<String>? {
        var found: Set<String> = []
        for spec in specs {
            for part in spec.split(separator: ",", omittingEmptySubsequences: false) {
                let value = part.trimmingCharacters(in: .whitespaces)
                guard shownValues.contains(value) else { return nil }
                found.insert(value)
            }
        }
        return found
    }
    /// The first value of a `--show` that is none of the three.
    static func badShown(_ specs: [String]) -> String? {
        specs.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !shownValues.contains($0) }
    }
    var raw: Bool { Self.shown(shows)?.contains("raw") ?? false }
    var includeHidden: Bool { Self.shown(shows)?.contains("hidden") ?? false }
    var headers: Bool { Self.shown(shows)?.contains("headers") ?? false }

    func validate() throws {
        if footnote != nil { throw ValidationError("`--footnote` is now its own command: pdf note <pdf> 7") }
        if ref != nil { throw ValidationError("`--ref` is now its own command: pdf ref <pdf> 12") }
        if removedRaw { throw ValidationError("`--raw` is now `--show raw`") }
        if removedIncludeHidden { throw ValidationError("`--include-hidden` is now `--show hidden`") }
        if removedHeaders { throw ValidationError("`--headers` is now `--show headers`") }
        if let bad = Self.badShown(shows) {
            throw ValidationError("--show: '\(bad)' is not raw, hidden or headers")
        }
        guard Self.tokens(budget) != nil else { throw ValidationError("--budget takes a number of tokens, or all") }
        if let from, Self.place(from) == nil {
            throw ValidationError("--from takes an address such as p4, p4.7 or p4.7:120")
        }
        if pageSpecs.contains(where: { Self.pages($0) == nil }) {
            throw ValidationError("--page takes pages such as 3, 3-5 or 3,7-9")
        }
        let scopes = [!pageSpecs.isEmpty, printedPage != nil, section != nil, full].filter { $0 }.count
        if scopes > 1 { throw ValidationError("choose one of --page, --printed-page, --section and --full") }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try read() }
    }

    func read() throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let resume = from.flatMap(Self.place)
        var wanted: [Int] = []
        for number in pageSpecs.flatMap({ Self.pages($0)! }) where !wanted.contains(number) { wanted.append(number) }
        let first = resume?.page ?? wanted.first ?? 1

        // The first page tells the page count, and starts the parse of a file not seen before.
        let docID: String, pageCount: Int
        switch try reader.read(path: path, pages: [first - 1]) {
        case .fileFailed(let reason):
            throw Contract.fail(file: path, reason: reason, json: json)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }
        var start = resume
        var until: (page: Int, block: Int)?
        var scope = ""
        if let printedPage {
            wanted = [try Self.printed(printedPage, path: path, pageCount: pageCount, store: store, json: json)]
            scope = " --printed-page " + Output.quoted(printedPage)
        } else if let section {
            let (found, end) = try Self.section(section, path: path, docID: docID, pageCount: pageCount, store: store,
                                                reader: reader, json: json)
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
                throw Contract.fail(path, "--from p\(start.page) is not among the pages to read", json: json)
            }
            numbers.removeFirst(position)
        }

        let keys = try store.pageKeys(docID: docID)
        // The file's facts and annotations belong to this version of the file.
        let resolved = Reader.resolve(path)
        let fileStat = FileStat(path: resolved)
        let facts = try fileStat.flatMap { try store.facts(path: resolved, stat: $0) }
        let limit = Self.tokens(budget)!
        let picks = try Picks().picks(keys: keys)
        let transcripts = try Transcripts().transcripts(keys: keys)
        let shownList = Self.shownValues.filter { Self.shown(shows)!.contains($0) }
        let flags =
            (shownList.isEmpty ? "" : " --show " + shownList.joined(separator: ","))
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
            // The annotations of these pages only: the cache keeps them per page.
            let annotations = (try? fileStat.map { try store.annotations(path: resolved, stat: $0, pages: chunk.map { $0 - 1 }) }) ?? [:]
            // Running headers and footers, judged against the pages around these that are parsed.
            let furniture = (try? Furniture.find(pages: results.map(\.page), keys: keys, store: store)) ?? [:]
            // Footnotes, endnotes and the rest, judged against the pages parsed so far, and the
            // citations of the list of references, whose raised markers lead to no note.
            let judged = (try? noteIndex.resolve(pages: everyPage, keys: keys, store: store)) ?? [:]
            try? referenceIndex.refresh(keys: keys, store: store)
            let cited = referenceIndex.resolve(pages: results.map(\.page), notes: judged)
            document.listEntries = referenceIndex.allEntries(notes: judged).count
            for (page, result) in results {
                let resume = index == 0 && page + 1 == start?.page
                let added = document.add(
                    Output.Page(
                        index: page, result: result, key: keys[page], annotations: annotations[page]?.annotations ?? [],
                        moreAnnotations: annotations[page]?.more ?? 0,
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

    /// The page, counted from 1, that bears a printed number, from the file's page labels. A file
    /// without labels prints each page's position.
    static func printed(_ label: String, path: String, pageCount: Int, store: Store, json: Bool) throws -> Int {
        let resolved = Reader.resolve(path)
        let labels = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }?.labels
        if let labels, let index = labels.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            return index + 1
        }
        if labels == nil, let number = Int(label), (1...pageCount).contains(number) { return number }
        var known = ""
        if let labels {
            let shown = labels.prefix(12).joined(separator: ", ")
            known = "; the pages are printed " + shown + (labels.count > 12 ? ", and \(labels.count - 12) more, up to \(labels[labels.count - 1])" : "")
        }
        throw Contract.fail(path, "no page is printed \(label)" + (labels == nil ? "; the file has no page labels" : known), json: json)
    }

    /// The section a `--section` value names, and where the next section at its level or above
    /// starts. Bookmarks name sections at once; headings in the text need every page parsed.
    static func section(_ query: String, path: String, docID: String, pageCount: Int, store: Store,
                        reader: Reader, json: Bool) throws -> (Section, (page: Int, block: Int)?) {
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
            throw Contract.fail(path, "no section matches \(query)" + (known.isEmpty ? "; the file has no bookmarks or numbered headings"
                : "; sections: " + known.joined(separator: ", ")), json: json)
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

}
