import ArgumentParser
import Foundation
import PDFCore

/// Keeps the LaTeX the agent read from an equation's crop, so later reads show it in place and
/// need no crop (FEATURES.md → F3, ROADMAP.md → M2.13). The tool rebuilds no LaTeX itself: what it
/// keeps is the agent's reading, and the output labels it so.
struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Keep the LaTeX you read from an equation's crop, so later reads show it in place.",
        discussion: """
            Give the LaTeX on standard input: pdf transcribe paper.pdf --page 4 --equation 5 <<'EOF', then the LaTeX, then \
            EOF on a line of its own. The quotes around EOF keep backslashes and dollar signs as written. Later reads show \
            it in the equation's block, labelled transcribed with the day. Another transcribe replaces it; --clear removes \
            it. At most 4,000 characters.
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(help: ArgumentHelp("The page, by its position in the file.", valueName: "N")) var page: Int
    @Option(help: ArgumentHelp("The equation, by its number, as pdf read shows it, such as 5.", valueName: "N")) var equation: String
    @Flag(help: "Remove the LaTeX kept for the equation.") var clear = false

    /// Why nothing was kept: an error with no usage after it, as the command was used right.
    struct Refusal: Error, CustomStringConvertible {
        var description: String
    }

    func validate() throws {
        if page < 1 { throw ValidationError("--page takes a page number, 1 or more") }
        if Region.normalized(equation).isEmpty { throw ValidationError("--equation takes the equation's number, such as 5") }
    }

    func run() throws {
        let number = Region.normalized(equation)
        let name = "equation \(number) on p.\(page)"
        // The LaTeX first, so a read with none fails before anything is parsed.
        var latex: String?
        if !clear {
            let given = isatty(STDIN_FILENO) == 1 ? Data() : ((try? FileHandle.standardInput.read(upToCount: 100_000)) ?? nil) ?? Data()
            guard let text = Transcripts.cleaned(String(decoding: given, as: UTF8.self)) else {
                throw Refusal(description: "no LaTeX on standard input: pdf transcribe \(Output.quoted(path)) --page \(page) "
                    + "--equation \(number) <<'EOF', then the LaTeX, then EOF")
            }
            guard text.count <= Transcripts.limit else {
                throw Refusal(description: "the LaTeX holds \(text.count) characters; at most \(Transcripts.limit) are kept")
            }
            latex = text
        }
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let docID: String
        switch try reader.read(path: path, pages: []) {
        case .fileFailed(let reason):
            print("\(path): failed: \(Output.failure(reason, file: path))")
            throw ExitCode(3)
        case .pages(let id, let pageCount, _):
            if page > pageCount { throw ReadError.pageOutOfRange(page: page - 1, pageCount: pageCount) }
            docID = id
        }
        guard case .pages(_, _, let results) = try reader.read(path: path, pages: [page - 1]), let layer = results.first?.result.pageText
        else { throw Refusal(description: "p.\(page) has no text to find \(name) in") }
        guard !Region.find(.equation, number, in: [(page - 1, layer)]).isEmpty else {
            let numbers = (layer.regions ?? []).filter { $0.kind == .equation }.map(\.number)
            throw Refusal(description: "no \(name)" + (numbers.isEmpty ? "; it holds no numbered equation"
                : "; equations found there: " + numbers.joined(separator: ", ")))
        }
        let key = try store.pageKeys(docID: docID)[page - 1]
        let transcripts = try Transcripts()
        guard let latex else {
            print(try transcripts.remove(pageKey: key, kind: .equation, number: number)
                ? "removed the LaTeX kept for \(name)" : "\(name) has no LaTeX kept")
            return
        }
        let kept = Transcript(pageKey: key, kind: .equation, number: number, text: latex, madeAt: Date())
        try transcripts.save(kept)
        print("kept the LaTeX of \(name); pdf read shows it there, labelled [equation \(number), transcribed \(kept.day)]")
    }
}
