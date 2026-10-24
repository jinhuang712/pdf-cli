import ArgumentParser
import Foundation
import PDFCore

/// Saves the agent's choice between the two readings of a block's unsure words (FEATURES.md →
/// F8). Only the tool's own readings can be picked, never free text.
struct PickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick",
        abstract: "Pick one of the two readings that an unsure block shows.",
        discussion: """
            Later reads show the picked words in place, labelled [picked] with the date. --dry-run says what would be \
            kept, and whether it would replace an earlier pick, and changes nothing; it needs the page read before.

            Examples:
              pdf pick paper.pdf p2.3 a
              pdf pick paper.pdf p7.1 b
              pdf pick paper.pdf p7.1 b --json
              pdf pick paper.pdf p7.1 b --dry-run
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Argument(help: "The block, as its unsure block names it: p2.3 is page 2, paragraph 3.") var block: String
    @Argument(help: "The reading to keep: a or b.") var reading: String
    @Flag(help: "Say what would be kept and change nothing.") var dryRun = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if Self.address(block) == nil { throw ValidationError("name the block as its unsure block does, such as p2.3") }
        if !["a", "b"].contains(reading.lowercased()) { throw ValidationError("pick a or b") }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try pick() }
    }

    func pick() throws {
        let (page, index) = Self.address(block)!
        let chosen = ["a", "b"].firstIndex(of: reading.lowercased())!
        if dryRun && !Store.exists() { throw Contract.fail(path, Contract.notReadYet(path, page: page + 1), json: json) }
        let store = try Store()
        let outcome: ReadOutcome
        if dryRun {
            // Only what the cache holds: a dry run parses nothing and writes nothing.
            guard let cached = try Reader(store: store).peek(path: path, pages: [page]) else {
                throw Contract.fail(path, Contract.notReadYet(path, page: page + 1), json: json)
            }
            outcome = cached
        } else {
            outcome = try Reader(store: store, library: try Library()).read(path: path, pages: [page])
        }
        switch outcome {
        case .fileFailed(let reason):
            throw Contract.fail(file: path, reason: reason, json: json)
        case .pages(let docID, _, let results):
            let spans = Quality.judge(results[0].result).unsure.filter { $0.block == index && $0.pickable }
            guard !spans.isEmpty else {
                throw Contract.fail(path, "p.\(page + 1) ¶\(index + 1) has no unsure words to pick from", json: json)
            }
            let readings = Picks.readings(of: spans)
            let key = try store.pageKeys(docID: docID)[page]
            var replaces: String?
            if dryRun {
                if Library.exists(), let earlier = try Picks(readOnly: true).picks(keys: [key])[key]?.first(where: { $0.block == index }) {
                    replaces = ["a", "b"][earlier.chosen]
                }
            } else {
                try Picks().save(Pick(pageKey: key, block: index, readings: readings, chosen: chosen, pickedAt: Date()))
            }
            if json {
                struct Body: Encodable {
                    var file: String
                    var page: Int
                    var block: Int
                    var picked: String
                    var text: String
                    var dryRun: Bool?
                    var replaces: String?
                }
                print(
                    Contract.json(
                        Body(
                            file: path, page: page + 1, block: index + 1, picked: reading.lowercased(), text: readings[chosen],
                            dryRun: dryRun ? true : nil, replaces: replaces)))
            } else if dryRun {
                print(
                    "dry run: would pick \(reading.lowercased()) for p.\(page + 1) ¶\(index + 1): \(readings[chosen])"
                        + (replaces.map { " (replaces an earlier pick, \($0))" } ?? "") + "; nothing was kept")
            } else {
                print("picked \(reading.lowercased()) for p.\(page + 1) ¶\(index + 1): \(readings[chosen])")
            }
        }
    }

    /// "p2.3" as page and block, each counted from 0.
    static func address(_ text: String) -> (page: Int, block: Int)? {
        guard text.hasPrefix("p") else { return nil }
        let parts = text.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let page = Int(parts[0]), let block = Int(parts[1]), page > 0, block > 0 else { return nil }
        return (page - 1, block - 1)
    }
}
