import ArgumentParser
import Foundation
import PDFCore

/// Finds the pages that hold words or a pattern, in one PDF or across the library (FEATURES.md →
/// F4), within the token budget (DESIGNS.md → Decision: a 5,000-token default budget).
struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find the pages that hold words or a pattern, in one PDF or in every PDF in the library.",
        discussion: """
            pdf search paper.pdf dropout ablation searches one PDF; pdf search dropout searches the library. \
            Hits come best first, each with its page, paragraph, section and the words around it. Output stops \
            at about 5,000 tokens and ends with the command that goes on.

            Examples:
              pdf search paper.pdf dropout ablation
              pdf search dropout
              pdf search paper.pdf --regex 'Table.[0-9]+' --top 5
            """
    )

    @Argument(help: ArgumentHelp("A PDF, then the words to find. Without a PDF, every PDF in the library.",
                                 valueName: "pdf> <words"))
    var words: [String] = []
    @Option(help: ArgumentHelp("A regular expression, matched across line, column and page breaks.", valueName: "pattern"))
    var regex: String?
    @Option(help: ArgumentHelp("Show at most N hits.", valueName: "N")) var top: Int?
    @Option(help: ArgumentHelp("Start at hit N, as a next: line says.", valueName: "N")) var from = 1
    @Option(help: ArgumentHelp("Stop at about N tokens, or all for no limit.", valueName: "N")) var budget = "5000"
    @Flag(help: "Print JSON.") var json = false

    /// How long a search of one PDF waits for its pages to parse before it searches those that are.
    static let wait: TimeInterval = 10

    func validate() throws {
        guard ReadCommand.tokens(budget) != nil else { throw ValidationError("--budget takes a number of tokens, or all") }
        if let top, top < 1 { throw ValidationError("--top takes a number of hits, 1 or more") }
        if from < 1 { throw ValidationError("--from takes a hit number, 1 or more") }
        if let regex {
            do { _ = try NSRegularExpression(pattern: regex) } catch {
                throw ValidationError("--regex takes a regular expression: \(error.localizedDescription)")
            }
            if words.count > 1 { throw ValidationError("with --regex, give at most a PDF, and no words") }
        } else if words.count == 1 && Self.namesFile(words[0]) {
            throw ValidationError("give the words to find after the PDF, or --regex with a pattern")
        } else if scope.query.isEmpty || Search.query(scope.query) == nil {
            throw ValidationError("give the words to find, or --regex with a pattern")
        }
    }

    /// Whether a word names a PDF: it ends in ".pdf", or names a file. A folder is no PDF, so
    /// a word that happens to name one stays a word.
    static func namesFile(_ word: String) -> Bool {
        if word.lowercased().hasSuffix(".pdf") { return true }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: word, isDirectory: &folder) && !folder.boolValue
    }

    /// The PDF, if the first word names one, and the words to find.
    var scope: (path: String?, query: String) {
        guard let first = words.first else { return (nil, "") }
        if regex != nil { return (words.count == 1 ? first : nil, "") }
        return Self.namesFile(first) && words.count > 1
            ? (first, words.dropFirst().joined(separator: " ")) : (nil, words.joined(separator: " "))
    }

    /// A PDF the search covers, and how much of it is parsed.
    struct Target {
        var path: String
        var docID: String
        var pageCount: Int
        var parsed: Int
    }

    func run() throws {
        try Contract.guarding(scope.path ?? "pdf search", json: json) { try search() }
    }

    func search() throws {
        let store = try Store()
        let library = try Library()
        let (path, query) = scope
        var targets: [Target] = []
        if let path {
            switch try Reader(store: store, library: library).read(path: path, pages: [0]) {
            case .fileFailed(let reason):
                throw Contract.fail(file: path, reason: reason, json: json)
            case .pages(let docID, let pageCount, _):
                targets = [Target(path: path, docID: docID, pageCount: pageCount,
                                  parsed: try Self.waitForPages(docID: docID, store: store))]
            }
        } else {
            // Copies of one file are one document, searched once, under a path that still exists.
            var known: [String: Int] = [:]
            for entry in try library.entries() {
                if let index = known[entry.docID] {
                    if !FileManager.default.fileExists(atPath: targets[index].path) && FileManager.default.fileExists(atPath: entry.path) {
                        targets[index].path = entry.path
                    }
                    continue
                }
                let keys = try store.pageKeys(docID: entry.docID)
                guard !keys.isEmpty else { continue }
                let cached = try store.cachedKeys(keys)
                known[entry.docID] = targets.count
                targets.append(Target(path: entry.path, docID: entry.docID, pageCount: keys.count,
                                      parsed: keys.filter { cached.contains($0) }.count))
            }
            if targets.isEmpty {
                let report = Report(
                    query: regex ?? query, regex: regex != nil, targets: [], single: false, total: 0, loose: false,
                    capped: false, from: from, store: store, picks: nil)
                if json {
                    print(String(decoding: try report.json([], next: nil), as: UTF8.self))
                } else {
                    print("the library is empty: pdf add puts PDFs in it, and every PDF pdf reads joins it")
                }
                return
            }
        }
        let docIDs = targets.map(\.docID)
        let limit = ReadCommand.tokens(budget)!
        let wanted = top.map { $0 } ?? Int.max

        // Hits come in pages of 200, best first, until the budget or --top stops them.
        var hits: [SearchHit] = []
        var total = 0
        var loose = false
        var capped = false
        let pattern = regex.map { try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
        if let pattern {
            // A pattern with nested repeats can run for minutes, and NSRegularExpression has no
            // time limit, so the command stops itself, and says why.
            let seconds = min(Env.pageTimeLimit, 10)
            let watchdog = DispatchWorkItem {
                FileHandle.standardError.write(Data("""
                    Error: the pattern ran longer than \(Int(seconds)) s. Nested repeats, as in (\\w+\\s?)+, can take \
                    minutes on a page; simplify it.\n
                    """.utf8))
                Foundation.exit(1)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)
            for target in targets {
                let pages = try InfoCommand.cachedPages(docID: target.docID, store: store)
                    .compactMap { page in page.result.pageText.map { (index: page.index, layer: $0) } }
                let found = Search.matches(pattern, docID: target.docID, pages: pages)
                if found.count >= Search.maxMatches { capped = true }
                hits += found
            }
            watchdog.cancel()
            total = hits.count
            hits = Array(hits.dropFirst(from - 1).prefix(wanted))
        } else {
            try store.indexForSearch(docIDs: docIDs)
            var match = Search.query(query)!
            total = try store.search(match, docIDs: docIDs, limit: 0, offset: 0).total
            if total == 0, let any = Search.query(query, any: true), any != match {
                // No block holds every word: blocks that hold some of them, best first.
                let some = try store.search(any, docIDs: docIDs, limit: 0, offset: 0).total
                if some > 0 {
                    match = any
                    loose = true
                    total = some
                }
            }
            var offset = from - 1
            while hits.count < min(wanted, total - (from - 1)) && offset < total {
                let page = try store.search(match, docIDs: docIDs, limit: min(200, wanted - hits.count), offset: offset).hits
                guard !page.isEmpty else { break }
                hits += page
                offset += page.count
                // A page of hits is about 60 tokens each, so more than the budget holds needs no more.
                if let limit, hits.count * 30 > limit { break }
            }
        }

        let report = Report(query: regex ?? query, regex: regex != nil, targets: targets, single: path != nil,
                            total: total, loose: loose, capped: capped, from: from, store: store, picks: try? Picks())
        let shown = report.render(hits, budget: limit, top: top)
        let flags = (regex.map { " --regex " + Output.quoted($0) } ?? "")
            + (budget == "5000" ? "" : " --budget \(budget)") + (json ? " --json" : "")
        var next: String?
        let end = from - 1 + shown.count
        if end < total && (top.map { shown.count < $0 } ?? true) {
            let rest = top.map { " --top \($0 - shown.count)" } ?? ""
            let words = regex == nil ? " " + Output.quoted(query) : ""
            next = "pdf search" + (path.map { " " + Output.quoted($0) } ?? "") + words + flags + " --from \(end + 1)" + rest
        }
        if json {
            print(String(decoding: try report.json(shown, next: next), as: UTF8.self))
        } else {
            print(report.text(shown, next: next), terminator: "")
        }
    }

    /// Waits up to `wait` seconds for every page of the document to be cached, and returns how
    /// many are. The runner the first read started parses them.
    static func waitForPages(docID: String, store: Store) throws -> Int {
        let keys = try store.pageKeys(docID: docID)
        let unique = Set(keys)
        let deadline = Date().addingTimeInterval(wait)
        var cached = try store.cachedKeys(keys)
        while cached.count < unique.count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            cached = try store.cachedKeys(keys)
        }
        return keys.filter { cached.contains($0) }.count
    }

    /// The hits, written for the agent: each with its file, page, paragraph, section and
    /// snippet, and a summary line that says how much was searched.
    struct Report {
        var query: String
        var regex: Bool
        var targets: [Target]
        var single: Bool
        var total: Int
        var loose: Bool
        /// True when a pattern matched more than `Search.maxMatches` times in a file.
        var capped: Bool
        var from: Int
        var store: Store
        var picks: Picks?

        struct Line: Encodable {
            var file: String
            var page: Int
            var block: Int
            var section: String?
            var flagged: String?
            /// The figure, table or equation the hit lies in, as "table 3", and the command that crops it.
            var inside: String?
            var crop: String?
            var snippet: String
        }

        /// A document's sections, as far as a search needs them: where each starts. With
        /// bookmarks, only the pages they point at are decoded; headings in the text need every
        /// cached page.
        func sections(_ target: Target) -> [Section] {
            let resolved = Reader.resolve(target.path)
            guard let keys = try? store.pageKeys(docID: target.docID) else { return [] }
            let facts = FileStat(path: resolved).flatMap { try? store.facts(path: resolved, stat: $0) }
            if let outline = facts?.outline, !outline.isEmpty {
                let wanted = Set(outline.map(\.page)).filter { keys.indices.contains($0) }.sorted()
                let results = (try? store.results(keys: wanted.map { keys[$0] })) ?? [:]
                let pages = wanted.compactMap { index in results[keys[index]].map { Output.Page(index: index, result: $0, key: keys[index]) } }
                return Info.starts(outline: outline, pages: pages, pageCount: keys.count)
            }
            return (try? InfoCommand.cachedPages(docID: target.docID, store: store)).map {
                Info.textSections($0, pageCount: keys.count)
            } ?? []
        }

        /// The status of each page with a hit that is not ok, such as "low-quality", keyed by
        /// document and page, and the figure, table or equation each hit lies in, keyed by
        /// document, page and block, read in one pass per document.
        func flags(_ hits: [SearchHit]) -> (flags: [String: String], regions: [String: Region]) {
            var flags: [String: String] = [:]
            var regions: [String: Region] = [:]
            for (docID, docHits) in Dictionary(grouping: hits, by: \.docID) {
                guard let keys = try? store.pageKeys(docID: docID) else { continue }
                let pages = Set(docHits.map(\.page)).filter { keys.indices.contains($0) }
                let wanted = pages.map { keys[$0] }
                let results = (try? store.results(keys: wanted)) ?? [:]
                let picked = (try? picks?.picks(keys: wanted)) ?? [:]
                for page in pages {
                    guard let result = results[keys[page]] else { continue }
                    let status = Output.judge(Output.Page(index: page, result: result, key: keys[page]), picks: picked)
                        .quality.status
                    if status != .ok { flags["\(docID) \(page)"] = status.rawValue }
                    guard let layer = result.pageText else { continue }
                    for hit in docHits where hit.page == page {
                        if let region = Region.holding(hit.block - 1, in: layer) { regions["\(docID) \(page) \(hit.block)"] = region }
                    }
                }
            }
            return (flags, regions)
        }

        /// The hits that fit the budget, as lines. The first always goes out. The budget keeps
        /// room for the lines that close the output.
        func render(_ hits: [SearchHit], budget: Int?, top: Int?) -> [Line] {
            var known: [String: [Section]] = [:]
            var lines: [Line] = []
            var used = Output.tokens(header()) + 60
            let (flagged, regions) = flags(hits)
            for hit in hits {
                guard let target = targets.first(where: { $0.docID == hit.docID }) else { continue }
                let found = known[hit.docID] ?? sections(target)
                known[hit.docID] = found
                let region = regions["\(hit.docID) \(hit.page) \(hit.block)"]
                let line = Line(file: target.path, page: hit.page + 1, block: hit.block,
                                section: Info.section(at: hit.page + 1, block: hit.block, in: found)?.title,
                                flagged: flagged["\(hit.docID) \(hit.page)"], inside: region?.name,
                                crop: region.map { "pdf crop \(Output.quoted(target.path)) --page \(hit.page + 1) --\($0.kind.rawValue) \($0.number)" },
                                snippet: hit.snippet)
                let cost = Output.tokens(text(line))
                if let budget, !lines.isEmpty, used + cost > budget { break }
                used += cost
                lines.append(line)
            }
            return lines
        }

        /// A file as a hit names it: its name, or its whole path when two files share the name.
        func name(_ path: String) -> String {
            let base = URL(fileURLWithPath: path).lastPathComponent
            let shared = targets.filter { URL(fileURLWithPath: $0.path).lastPathComponent == base }.count > 1
            return shared ? path : base
        }

        func header() -> String {
            let hits = capped ? "\(total)+ hits: a pattern stops counting at \(Search.maxMatches) in each PDF"
                : "\(total) hit\(total == 1 ? "" : "s")"
            let shown = regex ? "/\(query)/" : "\"\(query)\""
            let parts: [String]
            if single, let target = targets.first {
                parts = ["\(shown) in \(target.path)", hits, target.parsed == target.pageCount
                         ? "all \(target.pageCount) pages searched"
                         : "\(target.parsed) of \(target.pageCount) pages searched so far; pdf search again covers the rest"]
            } else {
                parts = ["\(shown) in the library", hits, "\(targets.count) PDF\(targets.count == 1 ? "" : "s") searched"]
            }
            var lines = [parts.joined(separator: " · ")]
            if !single {
                let partial = targets.filter { $0.parsed < $0.pageCount }
                if !partial.isEmpty {
                    lines.append("still parsing, searched so far: " + partial.prefix(5)
                        .map { "\(name($0.path)) \($0.parsed) of \($0.pageCount) pages" }.joined(separator: ", ")
                        + (partial.count > 5 ? ", and \(partial.count - 5) more" : ""))
                }
            }
            if loose { lines.append("no paragraph holds every word, so these hold some of them") }
            return lines.joined(separator: "\n")
        }

        func text(_ line: Line) -> String {
            (single ? "" : Output.quoted(name(line.file)) + " ") + "p.\(line.page) ¶\(line.block)"
                + (line.section.map { " · " + $0 } ?? "") + (line.flagged.map { " · \($0) page" } ?? "")
                + (line.inside.map { " · in \($0)" + (line.crop.map { " (crop: \($0))" } ?? "") } ?? "")
                + " · " + line.snippet.replacingOccurrences(of: "\n", with: " ")
        }

        func text(_ lines: [Line], next: String?) -> String {
            var out = [header()]
            if lines.isEmpty {
                out.append(total == 0 ? "no hits" : "no hits from \(from) on")
            } else {
                out.append("")
                out += lines.map(text)
                out.append("")
                let first = lines[0]
                out.append("read a hit: pdf read \(Output.quoted(first.file)) --from \(Output.address(page: first.page, block: first.block, offset: nil))")
            }
            if let next { out.append("next: " + next) }
            return out.joined(separator: "\n") + "\n"
        }

        func json(_ lines: [Line], next: String?) throws -> Data {
            struct File: Encodable {
                var file: String
                var pageCount: Int
                var pagesSearched: Int
            }
            struct Body: Encodable {
                var query: String
                var regex: Bool
                var total: Int
                var someWords: Bool
                var capped: Bool
                var files: [File]
                var hits: [Line]
                var next: String?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            return try encoder.encode(Body(query: query, regex: regex, total: total, someWords: loose, capped: capped,
                                           files: targets.map { File(file: $0.path, pageCount: $0.pageCount, pagesSearched: $0.parsed) },
                                           hits: lines, next: next))
        }
    }
}
