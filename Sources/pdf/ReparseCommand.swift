import ArgumentParser
import Foundation
import PDFCore

/// Reads pages again and replaces their cached results (FEATURES.md → F10, ROADMAP.md → M2.10).
struct ReparseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reparse",
        abstract: "Read pages again, and replace their cached results.",
        discussion: """
            Reads every page again with the usual method on the running macOS, or the pages in --page. \
            --step ocr reads them with Apple's OCR instead: without --page it does every page. The old \
            results stay until the new ones are all in, so a command that stops half way changes nothing. A page \
            whose new reading fails keeps its old result, and the command ends 2.

            Speed, as measured: 231 pages plain take about 18 s; OCR takes about 0.4 s a page, so about 300 \
            OCR pages or 400 pages whose fonts lose spaces pass 120 s, the limit many agents give a command. \
            Split a big file with --page ranges (pdf reparse big.pdf --page 1-150, then 151-300): a run that \
            is stopped changes none of its pages.

            It clears the picks on the pages it reads, since a new reading can offer other words. What \
            you transcribed (an equation's LaTeX, a table's Markdown) is kept: it belongs to what the page \
            draws, which does not change. A file never read is just parsed, only the pages asked for.

            Examples:
              pdf reparse paper.pdf
              pdf reparse paper.pdf --page 7
              pdf reparse scan.pdf --page 3-5 --step ocr
            """
    )

    enum Step: String, ExpressibleByArgument, CaseIterable {
        case ocr
    }

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(
        name: .customLong("page"),
        help: ArgumentHelp(
            "Only these pages, by their position in the file, such as 3, 3-5 or 3,7-9. The flag can repeat.",
            valueName: "pages"))
    var pageSpecs: [String] = []
    @Option(help: ArgumentHelp("Read with a stronger method than the usual one: ocr, Apple's OCR.", valueName: "ocr"))
    var step: Step?
    @Option(
        help:
            "The password that opens a locked PDF. Other users of the Mac can see it in this command's line while it runs; --password-stdin keeps it out."
    )
    var password: String?
    @Flag(help: "Read the password from standard input, as in: echo \"$PW\" | pdf reparse paper.pdf --password-stdin")
    var passwordStdin = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if pageSpecs.contains(where: { ReadCommand.pages($0) == nil }) {
            throw ValidationError("--page takes pages such as 3, 3-5 or 3,7-9")
        }
        if password != nil && passwordStdin { throw ValidationError("give the password one way: --password or --password-stdin") }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try reparse() }
    }

    /// The most pages the text lists by name, after which it says how many more.
    static let listed = 20

    struct Change: Encodable {
        var page: Int
        var before: String?
        var after: String
        var textChanged: Bool

        // A page with no result before shows `before: null`, not a missing key.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Keys.self)
            try values.encode(page, forKey: .page)
            try values.encode(before, forKey: .before)
            try values.encode(after, forKey: .after)
            try values.encode(textChanged, forKey: .textChanged)
        }
        enum Keys: String, CodingKey { case page, before, after, textChanged }
    }

    func reparse() throws {
        var wanted: [Int]?
        if !pageSpecs.isEmpty { wanted = Array(Set(pageSpecs.flatMap { ReadCommand.pages($0)! })).sorted().map { $0 - 1 } }
        let secret = passwordStdin ? Password.read(for: path) : password
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let outcome = try reader.reparse(path: path, pages: wanted, ocr: step == .ocr, password: secret)
        guard case .done(let done) = outcome else {
            if case .fileFailed(let reason) = outcome {
                throw Contract.fail(path, Output.failure(reason, file: path, command: "reparse"), json: json, code: Contract.fileFailed)
            }
            return
        }

        // The picks on a page whose reading was replaced go; a page that kept its old result keeps them.
        let keys = try store.pageKeys(docID: done.docID)
        let replaced = done.pages.filter { done.kept[$0] == nil }
        let cleared: Int
        do {
            cleared = try Picks().clear(keys: replaced.map { keys[$0] })
        } catch {
            throw Contract.fail(
                path,
                "the results of \(count(replaced.count, "page")) were replaced, but their picks could not be cleared (\(Contract.reason(of: error))); run pdf reparse again to clear them",
                json: json)
        }

        func status(_ result: PageResult?) -> String? { result.map { Quality.judge($0).status.rawValue } }
        var changes: [Change] = []
        var flagged: [(page: Int, status: String)] = []
        var whole = 0
        for page in replaced {
            guard let after = done.after[page] else { continue }
            let judged = Quality.judge(after)
            if judged.status != .ok { flagged.append((page + 1, judged.status.rawValue)) }
            if judged.status == .failed || judged.wholePage { whole += 1 }
            let before = done.before[page]
            let textChanged = before.map { $0.text != after.text } ?? false
            // A first reading is no change in the text: it shows in the flagged pages, if it is one.
            if status(before) != judged.status.rawValue || textChanged {
                changes.append(Change(page: page + 1, before: status(before), after: judged.status.rawValue, textChanged: textChanged))
            }
        }
        let shownChanges = changes.filter { $0.before != nil }
        let statusChanges = shownChanges.filter { $0.before != $0.after }.count
        let keptPages = done.kept.keys.sorted()
        let method = step == .ocr ? "OCR" : "the usual method"

        if json {
            struct Body: Encodable {
                var file: String
                var id: String
                var step: String
                var reparsed: Int
                var pages: [Int]
                var flagged: Int
                var flaggedPages: [Status]
                var changes: [Change]
                var kept: [Kept]
                var picksCleared: Int
                var neverRead: Bool?
                var changedSinceRead: Bool?
                var toolUpdated: Bool?
            }
            struct Status: Encodable {
                var page: Int
                var status: String
            }
            struct Kept: Encodable {
                var page: Int
                var reason: String
            }
            print(
                Contract.json(
                    Body(
                        file: path, id: String(done.docID.prefix(8)), step: step?.rawValue ?? "usual", reparsed: replaced.count,
                        pages: replaced.map { $0 + 1 }, flagged: flagged.count,
                        flaggedPages: flagged.map { Status(page: $0.page, status: $0.status) }, changes: changes,
                        kept: keptPages.map { Kept(page: $0 + 1, reason: done.kept[$0] ?? "") }, picksCleared: cleared,
                        neverRead: done.neverRead ? true : nil, changedSinceRead: done.changedSinceRead ? true : nil,
                        toolUpdated: done.toolUpdated ? true : nil)))
        } else {
            var parts = ["reparsed \(count(replaced.count, "page")) of \(done.pageCount) with \(method)"]
            if !keptPages.isEmpty { parts.append("\(keptPages.count) kept the old result") }
            parts.append(flagged.isEmpty ? "none flagged" : "\(flagged.count) flagged")
            parts.append(statusChanges == 0 ? "no page changed status" : "\(statusChanges) changed status")
            if cleared > 0 { parts.append("cleared \(count(cleared, "pick"))") }
            if done.neverRead {
                parts.append(
                    done.before.isEmpty
                        ? "not read before, so these pages are read for the first time"
                        : "not read before, but identical pages another file had cached are replaced")
            }
            if done.changedSinceRead { parts.append("the file changed since it was read; this is its current version") }
            if done.toolUpdated { parts.append("pdf was updated since it read the file, and indexed it again") }
            parts.append(path)
            print(parts.joined(separator: " · "))
            if !flagged.isEmpty {
                let shown = flagged.prefix(Self.listed).map { "p.\($0.page) (\($0.status))" }.joined(separator: ", ")
                print("flagged: " + shown + (flagged.count > Self.listed ? ", and \(flagged.count - Self.listed) more" : ""))
            }
            for page in keptPages.prefix(Self.listed) {
                print("p.\(page + 1): kept the old result, the new reading failed: \(done.kept[page] ?? "")")
            }
            if keptPages.count > Self.listed { print("and \(keptPages.count - Self.listed) more kept") }
            for change in shownChanges.prefix(Self.listed) {
                let before = change.before ?? ""
                var line = "p.\(change.page): " + (before == change.after ? "\(before), text changed" : "\(before) -> \(change.after)")
                if before != change.after && change.textChanged { line += ", text changed" }
                print(line)
            }
            if shownChanges.count > Self.listed { print("and \(shownChanges.count - Self.listed) more") }
        }
        if !replaced.isEmpty && whole == replaced.count { throw ExitCode(Contract.fileFailed) }
        if !flagged.isEmpty || !keptPages.isEmpty { throw ExitCode(2) }
    }
}
