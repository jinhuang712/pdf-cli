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

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(name: .customLong("page"),
            help: ArgumentHelp("Pages by their position in the file, such as 3, 3-5 or 3,7-9. The flag can repeat.",
                               valueName: "pages"))
    var pageSpecs: [String] = []
    @Flag(help: "Read the whole document, page after page, within the budget.") var full = false
    @Option(help: ArgumentHelp("Stop at about N tokens, or all for no limit.", valueName: "N")) var budget = "5000"
    @Option(help: ArgumentHelp("Go on from where a read stopped, as its next: line says, such as p4.7.", valueName: "address"))
    var from: String?
    @Option(help: "The output format: md or text.") var format: Format = .md
    @Flag(help: "Show the text set aside as doubtful, labelled with its reason.") var raw = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        guard Self.tokens(budget) != nil else { throw ValidationError("--budget takes a number of tokens, or all") }
        if let from, Self.place(from) == nil {
            throw ValidationError("--from takes an address such as p4, p4.7 or p4.7:120")
        }
        if pageSpecs.contains(where: { Self.pages($0) == nil }) {
            throw ValidationError("--page takes pages such as 3, 3-5 or 3,7-9")
        }
        if full && !pageSpecs.isEmpty { throw ValidationError("--full reads every page; leave out --page") }
    }

    func run() throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let start = from.flatMap(Self.place)
        var wanted: [Int] = []
        for number in pageSpecs.flatMap({ Self.pages($0)! }) where !wanted.contains(number) { wanted.append(number) }
        let first = start?.page ?? wanted.first ?? 1

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
        let limit = Self.tokens(budget)!
        let picks = try Picks().picks(keys: keys)
        let flags = (raw ? " --raw" : "") + (format == .text ? " --format text" : "") + (budget == "5000" ? "" : " --budget \(budget)")
        let quotedPath = Output.quoted(path)
        let specified = !wanted.isEmpty
        let order = numbers
        var document = Output.Document(
            file: path, pageCount: pageCount, style: format == .md ? .md : .text, raw: raw, picks: picks, budget: limit,
            continuation: { page, block, offset in
                let rest = specified ? " --page " + Self.spec(Array(order.drop { $0 != page })) : ""
                return "pdf read \(quotedPath)\(rest) --from \(Output.address(page: page, block: block, offset: offset))\(flags)"
            })

        // Pages are fetched a few at a time, so a read that the budget stops early waits only
        // for the pages it shows.
        let batch = max(1, min(8, (limit ?? 40_000) / 1_000))
        var index = 0
        reading: while index < numbers.count {
            let chunk = Array(numbers[index..<min(index + batch, numbers.count)])
            guard case .pages(_, _, let results) = try reader.read(path: path, pages: chunk.map { $0 - 1 }) else { break }
            for (page, result) in results {
                let resume = index == 0 && page + 1 == start?.page
                let added = document.add(Output.Page(index: page, result: result, key: keys[page]),
                                         from: resume ? start?.block : nil, offset: resume ? start?.offset : nil)
                if !added { break reading }
                index += 1
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

    /// A budget in tokens: nil inside for no limit, nil outside for a value that is neither.
    static func tokens(_ text: String) -> Int?? {
        if text == "all" { return .some(nil) }
        guard let value = Int(text), value > 0 else { return nil }
        return .some(value)
    }

    /// Page numbers from "3", "3-5" or "3,7-9", counted from 1.
    static func pages(_ text: String) -> [Int]? {
        var numbers: [Int] = []
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (1...2).contains(ends.count), let low = ends[0], let high = ends.last!, low >= 1, high >= low else { return nil }
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
