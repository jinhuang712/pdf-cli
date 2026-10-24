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
            --step ocr reads them with Apple's OCR instead, which takes about a second a page: without \
            --page it does every page. The old results stay until the new ones are all in, so a command that \
            stops half way changes nothing. A page whose new reading fails keeps its old result.

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
    }

    func reparse() throws {
        var wanted: [Int]?
        if !pageSpecs.isEmpty { wanted = Array(Set(pageSpecs.flatMap { ReadCommand.pages($0)! })).sorted().map { $0 - 1 } }
        let secret = passwordStdin ? Password.read(for: path) : password
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let outcome = try reader.reparse(path: path, pages: wanted, ocr: step == .ocr, password: secret)
        guard case .done(let done) = outcome else {
            if case .fileFailed(let reason) = outcome { throw Contract.fail(file: path, reason: reason, json: json) }
            return
        }

        // The picks on a page whose reading was replaced go; a page that kept its old result keeps them.
        let keys = try store.pageKeys(docID: done.docID)
        let replaced = done.pages.filter { done.kept[$0] == nil }
        let cleared = try Picks().clear(keys: replaced.map { keys[$0] })

        func status(_ result: PageResult?) -> String? { result.map { Quality.judge($0).status.rawValue } }
        var changes: [Change] = []
        var flagged: [(page: Int, status: String)] = []
        var whole = 0
        for page in done.pages {
            guard let after = done.after[page] else { continue }
            let judged = Quality.judge(after)
            if judged.status != .ok { flagged.append((page + 1, judged.status.rawValue)) }
            if judged.status == .failed || judged.wholePage { whole += 1 }
            let before = done.before[page]
            let textChanged = before.map { $0.text != after.text } ?? false
            if status(before) != judged.status.rawValue || textChanged || done.kept[page] != nil {
                changes.append(Change(page: page + 1, before: status(before), after: judged.status.rawValue, textChanged: textChanged))
            }
        }
        let statusChanges = changes.filter { $0.before != $0.after }.count
        let method = step == .ocr ? "OCR" : "the usual method"

        if json {
            struct Body: Encodable {
                var file: String
                var id: String
                var step: String
                var reparsed: Int
                var pages: [Int]
                var flagged: Int
                var flaggedPages: [[String: String]]
                var changes: [Change]
                var kept: [[String: String]]
                var picksCleared: Int
                var neverRead: Bool?
                var changedSinceRead: Bool?
            }
            print(
                Contract.json(
                    Body(
                        file: path, id: String(done.docID.prefix(8)), step: step?.rawValue ?? "usual", reparsed: done.pages.count,
                        pages: done.pages.map { $0 + 1 }, flagged: flagged.count,
                        flaggedPages: flagged.map { ["page": String($0.page), "status": $0.status] }, changes: changes,
                        kept: done.kept.sorted { $0.key < $1.key }.map { ["page": String($0.key + 1), "reason": $0.value] },
                        picksCleared: cleared, neverRead: done.neverRead ? true : nil,
                        changedSinceRead: done.changedSinceRead ? true : nil)))
        } else {
            var parts = ["reparsed \(count(done.pages.count, "page")) of \(done.pageCount) with \(method)"]
            parts.append(flagged.isEmpty ? "none flagged" : "\(flagged.count) flagged")
            parts.append(statusChanges == 0 ? "no page changed status" : "\(statusChanges) changed status")
            if cleared > 0 { parts.append("cleared \(count(cleared, "pick"))") }
            if done.neverRead { parts.append("not read before, so this only parsed") }
            if done.changedSinceRead { parts.append("the file changed since it was read; this is its current version") }
            parts.append(path)
            print(parts.joined(separator: " · "))
            if !flagged.isEmpty {
                let shown = flagged.prefix(Self.listed).map { "p.\($0.page) (\($0.status))" }.joined(separator: ", ")
                print("flagged: " + shown + (flagged.count > Self.listed ? ", and \(flagged.count - Self.listed) more" : ""))
            }
            for change in changes.prefix(Self.listed) {
                var line =
                    "p.\(change.page): "
                    + (change.before.map { $0 == change.after ? "\($0), text changed" : "\($0) -> \(change.after)" } ?? "now \(change.after)")
                if change.before != nil && change.before != change.after && change.textChanged { line += ", text changed" }
                if let reason = done.kept[change.page - 1] { line = "p.\(change.page): kept the old result, the new reading failed: \(reason)" }
                print(line)
            }
            if changes.count > Self.listed { print("and \(changes.count - Self.listed) more") }
        }
        if whole == done.pages.count && whole > 0 { throw ExitCode(Contract.fileFailed) }
        if !flagged.isEmpty { throw ExitCode(2) }
    }
}
