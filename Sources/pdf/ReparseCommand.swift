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
            --step ocr reads them with Apple's OCR instead: without --page it does every page. The pages \
            are replaced in chunks of 50, each in one step, so a command that is stopped keeps the chunks \
            it finished and a page whose new reading fails keeps its old result (the command ends 2). A \
            run goes on to 90 s and then stops, ends 2 and prints the command for the pages left.

            Speed, as measured: 231 pages plain take about 18 s; OCR takes about 0.4 s a page, so about 200 \
            OCR pages fill the 90 s; run the printed command again for the rest.

            A reparse never deletes a pick. A pick applies while its block still offers the readings it was made \
            for; one that no longer does stays stored and applies again if the readings come back (an OCR \
            reparse, then a plain one). The summary counts both. What you transcribed (an equation's LaTeX, a table's Markdown) is kept: it belongs to what the page \
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

    /// Pages as a `--page` list, such as 151-300,305.
    static func pageList(_ pages: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        while index < pages.count {
            var end = index
            while end + 1 < pages.count && pages[end + 1] == pages[end] + 1 { end += 1 }
            parts.append(end > index ? "\(pages[index])-\(pages[end])" : "\(pages[index])")
            index = end + 1
        }
        return parts.joined(separator: ",")
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
        let outcome = try reader.reparse(
            path: path, pages: wanted, ocr: step == .ocr, password: secret,
            progress: { done, total in
                // A file of several chunks says how far it got as it goes, so a run that is stopped shows it.
                // Not under --json: an agent's shell merges the error stream into the object.
                if total > Env.reparseChunk && !json {
                    FileHandle.standardError.write(Data("reparsed \(done) of \(total) pages\n".utf8))
                }
            })
        guard case .done(let done) = outcome else {
            if case .fileFailed(let reason) = outcome {
                throw Contract.fail(path, Output.failure(reason, file: path, command: "reparse"), json: json, code: Contract.fileFailed)
            }
            return
        }

        // The runner counted the picks on the replaced pages against what the cache holds now. Nothing
        // is deleted: a pick that no longer applies stays stored, and applies if its readings come back.
        let replaced = done.pages.filter { done.kept[$0] == nil }
        let applyPicks = done.picksApply
        let stalePicks = done.picksStale

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
        // The pages the time limit came before, and the command that reads them.
        let left = done.remaining.map { $0 + 1 }
        let next =
            left.isEmpty
            ? nil
            : "pdf reparse \(Output.quoted(path)) --page \(Self.pageList(left))" + (step == .ocr ? " --step ocr" : "")
                + (passwordStdin || password != nil ? " --password-stdin" : "")

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
                var picksApply: Int
                var picksStale: Int
                var picksUnknown: String?
                var remaining: [Int]?
                var next: String?
                var stopped: String?
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
                        kept: keptPages.map { Kept(page: $0 + 1, reason: done.kept[$0] ?? "") }, picksApply: applyPicks, picksStale: stalePicks,
                        picksUnknown: done.picksUnknown,
                        remaining: left.isEmpty ? nil : left, next: next, stopped: done.stopped,
                        neverRead: done.neverRead ? true : nil, changedSinceRead: done.changedSinceRead ? true : nil,
                        toolUpdated: done.toolUpdated ? true : nil)))
        } else {
            var parts = ["reparsed \(count(replaced.count, "page")) of \(done.pageCount) with \(method)"]
            if !keptPages.isEmpty { parts.append("\(count(keptPages.count, "page")) kept the old result") }
            parts.append(flagged.isEmpty ? "none flagged" : "\(flagged.count) flagged")
            parts.append(statusChanges == 0 ? "no page changed status" : "\(statusChanges) changed status")
            if applyPicks > 0 { parts.append("\(count(applyPicks, "pick")) still \(applyPicks == 1 ? "applies" : "apply")") }
            if stalePicks > 0 {
                parts.append("\(count(stalePicks, "pick")) no longer \(stalePicks == 1 ? "applies" : "apply") and stays stored")
            }
            if let unknown = done.picksUnknown { parts.append("picks not counted (\(unknown))") }
            if let next {
                parts.append(
                    "\(done.stopped ?? "stopped") with \(count(left.count, "page")) not read; the chunks before it are replaced; read the rest: \(next)"
                )
            }
            if done.neverRead {
                parts.append(
                    done.before.isEmpty
                        ? "not read before, so these pages are read for the first time"
                        : "not read before, but identical pages another file had cached are replaced")
            }
            if done.changedSinceRead {
                parts.append(
                    "the file changed since it was read; this is its current version"
                        + (done.earlierPages > 0
                            ? " (\(count(done.earlierPages, "page")) of the version before were replaced, and the picks counted include theirs)" : "")
                )
            }
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
        if !flagged.isEmpty || !keptPages.isEmpty || next != nil { throw ExitCode(2) }
    }
}
