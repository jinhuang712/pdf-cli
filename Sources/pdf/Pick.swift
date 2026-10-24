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
            Later reads show the picked words in place, labelled [picked] with the date.

            Examples:
              pdf pick paper.pdf p2.3 a
              pdf pick paper.pdf p7.1 b
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Argument(help: "The block, as its unsure block names it: p2.3 is page 2, paragraph 3.") var block: String
    @Argument(help: "The reading to keep: a or b.") var reading: String

    func validate() throws {
        if Self.address(block) == nil { throw ValidationError("name the block as its unsure block does, such as p2.3") }
        if !["a", "b"].contains(reading.lowercased()) { throw ValidationError("pick a or b") }
    }

    func run() throws {
        let (page, index) = Self.address(block)!
        let chosen = ["a", "b"].firstIndex(of: reading.lowercased())!
        let store = try Store()
        switch try Reader(store: store, library: try Library()).read(path: path, pages: [page]) {
        case .fileFailed(let reason):
            print("\(path): failed: \(Output.failure(reason, file: path))")
            throw ExitCode(3)
        case .pages(let docID, _, let results):
            let spans = Quality.judge(results[0].result).unsure.filter { $0.block == index && $0.pickable }
            guard !spans.isEmpty else {
                print("p.\(page + 1) ¶\(index + 1) has no unsure words to pick from")
                throw ExitCode(1)
            }
            let readings = Picks.readings(of: spans)
            let key = try store.pageKeys(docID: docID)[page]
            try Picks().save(Pick(pageKey: key, block: index, readings: readings, chosen: chosen, pickedAt: Date()))
            print("picked \(reading.lowercased()) for p.\(page + 1) ¶\(index + 1): \(readings[chosen])")
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
