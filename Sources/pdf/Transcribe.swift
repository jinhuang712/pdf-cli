import ArgumentParser
import Foundation
import PDFCore

/// Keeps what the agent read from a crop, an equation's LaTeX or a table's Markdown, so later
/// reads show it in place (FEATURES.md → F3, ROADMAP.md → M2.13). The tool rebuilds neither
/// itself: what it keeps is the agent's reading, and the output labels it so.
struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Keep the LaTeX of an equation, or the Markdown of a table, that you read from its crop.",
        discussion: """
            Give the text on standard input: pdf transcribe paper.pdf --page 4 --equation 5 <<'EOF', then the LaTeX, then \
            EOF on a line of its own. The quotes around EOF keep backslashes and dollar signs as written. Later reads show \
            it in the block, labelled transcribed with the day. Another transcribe replaces it; --clear removes it. At most \
            4,000 characters for an equation, 12,000 for a table. --dry-run reads the text, says what would be kept, \
            replaced or removed, and changes nothing; it needs the page read before.

            Examples:
              printf '%s\\n' '\\frac{a}{b}' | pdf transcribe paper.pdf --page 4 --equation 5
              pdf transcribe paper.pdf --page 6 --table 2 < table.md
              pdf transcribe paper.pdf --page 4 --equation 5 --clear
              pdf transcribe paper.pdf --page 6 --table 2 --json < table.md
              pdf transcribe paper.pdf --page 4 --equation 5 --dry-run < latex.txt
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(help: ArgumentHelp("The page, by its position in the file.", valueName: "N")) var page: Int
    @Option(help: ArgumentHelp("An equation, by its number, as pdf read shows it, such as 5.", valueName: "N")) var equation: String?
    @Option(help: ArgumentHelp("A table, by its number, as pdf read shows it, such as 2.", valueName: "N")) var table: String?
    @Flag(help: "Remove what is kept for it.") var clear = false
    @Flag(help: "Say what would be kept or removed and change nothing.") var dryRun = false
    @Flag(help: "Print JSON.") var json = false

    /// Why nothing was kept: an error with no usage after it, as the command was used right.
    struct Refusal: Error, CustomStringConvertible {
        var description: String
    }

    /// The bytes read from standard input at most: past them, the text is refused, not cut.
    static let readLimit = 100_000

    var wanted: (kind: Region.Kind, number: String)? {
        if let equation { return (.equation, Region.normalized(equation)) }
        return table.map { (.table, Region.normalized($0)) }
    }

    func validate() throws {
        if page < 1 { throw ValidationError("--page takes a page number, 1 or more") }
        if (equation == nil) == (table == nil) { throw ValidationError("give --equation or --table, one of them") }
        if wanted?.number.isEmpty != false { throw ValidationError("--equation and --table take a number, such as 5") }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try transcribe() }
    }

    func transcribe() throws {
        let (kind, asked) = wanted!
        let language = Transcript.language(of: kind)
        // The file first, so a missing or unreadable one is reported even when nothing is piped.
        try Contract.requireFile(path)
        guard FileManager.default.isReadableFile(atPath: Reader.resolve(path)) else {
            throw Contract.fail(path, "could not be read: permission denied", json: json, code: Contract.fileFailed)
        }
        // A dry run opens only what is there, and reads only what the cache holds.
        if dryRun, !Store.exists() { throw Contract.fail(path, Contract.notReadYet(path, page: page, .neverRead), json: json) }
        // The text next, so a read with none fails before anything is parsed.
        var given: String?
        if !clear {
            let data = isatty(STDIN_FILENO) == 1 ? Data() : ((try? FileHandle.standardInput.read(upToCount: Self.readLimit + 1)) ?? nil) ?? Data()
            let command = "pdf transcribe \(Output.quoted(path)) --page \(page) --\(kind.rawValue) \(asked) <<'EOF'"
            guard data.count <= Self.readLimit else {
                throw Refusal(description: "the \(language) on standard input is over \(Self.readLimit) bytes; nothing is kept")
            }
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw Refusal(description: "the \(language) on standard input is not UTF-8; nothing is kept")
            }
            guard let text = Transcripts.cleaned(decoded, kind: kind) else {
                throw Refusal(description: "no \(language) on standard input: \(command), then the \(language), then EOF")
            }
            let length = text.unicodeScalars.count
            guard length <= Transcripts.limit(kind) else {
                throw Refusal(description: "the \(language) holds \(length) characters; at most \(Transcripts.limit(kind)) are kept")
            }
            given = text
        }
        let store = try Store(readOnly: dryRun)
        let reader = Reader(store: store, library: dryRun ? nil : try Library())
        let docID: String
        let read: ReadOutcome
        if dryRun {
            let found: ReadOutcome
            switch try reader.peek(path: path, pages: [page - 1]) {
            case .uncached(let why): throw Contract.fail(path, Contract.notReadYet(path, page: page, why), json: json)
            case .found(let outcome): found = outcome
            }
            read = found
            switch found {
            case .fileFailed(let reason): throw Contract.fail(file: path, reason: reason, json: json)
            case .pages(let id, _, _): docID = id
            }
        } else {
            switch try reader.read(path: path, pages: []) {
            case .fileFailed(let reason):
                throw Contract.fail(file: path, reason: reason, json: json)
            case .pages(let id, let pageCount, _):
                if page > pageCount { throw ReadError.pageOutOfRange(page: page - 1, pageCount: pageCount) }
                docID = id
            }
            read = try reader.read(path: path, pages: [page - 1])
        }
        let key = try store.pageKeys(docID: docID)[page - 1]
        let transcripts: Transcripts? = dryRun ? nil : try Transcripts()
        guard case .pages(_, _, let results) = read, let layer = results.first?.result.pageText else {
            if clear { return try remove(key, kind, asked, transcripts) }
            throw Refusal(description: "p.\(page) has no text to find \(kind.rawValue) \(asked) in")
        }
        let found = Region.find(kind, asked, in: [(page - 1, layer)])
        // The number as the page gives it, which reads match: "S1" for "s1".
        guard let first = found.first else {
            // What a page no longer shows can still go.
            if clear { return try remove(key, kind, asked, transcripts) }
            let numbers = (layer.regions ?? []).filter { $0.kind == kind }.map(\.number)
            throw Refusal(description: "no \(kind.rawValue) \(asked) on p.\(page)" + (numbers.isEmpty ? "; it holds no numbered \(kind.rawValue)"
                : "; \(kind.rawValue)s found there: " + numbers.joined(separator: ", ")))
        }
        let number = Region.normalized(first.region.number)
        let name = "\(kind.rawValue) \(number) on p.\(page)"
        guard let given else { return try remove(key, kind, number, transcripts) }
        let kept = Transcript(pageKey: key, kind: kind, number: number, text: given, madeAt: Date())
        let earlier = dryRun ? try Self.earlier(key, kind, number) : nil
        try transcripts?.save(kept)
        if json {
            struct Body: Encodable {
                var file: String
                var page: Int
                var kind: String
                var number: String
                var kept: String
                var sameNumber: Int?
                var dryRun: Bool?
                var replaces: String?
                var characters: Int?

                /// In a dry run `replaces` is always there: the day of the reading it would replace, or null.
                enum CodingKeys: String, CodingKey { case file, page, kind, number, kept, sameNumber, dryRun, replaces, characters }
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(file, forKey: .file)
                    try c.encode(page, forKey: .page)
                    try c.encode(kind, forKey: .kind)
                    try c.encode(number, forKey: .number)
                    try c.encode(kept, forKey: .kept)
                    try c.encodeIfPresent(sameNumber, forKey: .sameNumber)
                    try c.encodeIfPresent(dryRun, forKey: .dryRun)
                    try c.encodeIfPresent(characters, forKey: .characters)
                    if dryRun != nil { try c.encode(replaces, forKey: .replaces) }
                }
            }
            print(
                Contract.json(
                    Body(
                        file: path, page: page, kind: kind.rawValue, number: number, kept: given,
                        sameNumber: found.count > 1 ? found.count : nil, dryRun: dryRun ? true : nil,
                        replaces: earlier?.day, characters: dryRun ? given.unicodeScalars.count : nil)))
            return
        }
        if dryRun {
            print(
                "dry run: would keep the \(language) of \(name), \(count(given.unicodeScalars.count, "character"))"
                    + (earlier.map { ", replacing the one kept \($0.day)" } ?? ", with none kept now") + "; nothing was kept")
        } else {
            print("kept the \(language) of \(name); pdf read shows it there, labelled [\(kind.rawValue) \(number), transcribed \(kept.day)]")
        }
        if found.count > 1 {
            print("p.\(page) numbers \(found.count) \(kind.rawValue)s \(number): this goes with the first, which pdf crop --\(kind.rawValue) \(number) crops")
        }
    }

    /// What a dry run finds kept: the library file is opened only when it exists, and read only.
    static func earlier(_ key: String, _ kind: Region.Kind, _ number: String) throws -> Transcript? {
        guard Library.exists() else { return nil }
        return try Transcripts(readOnly: true).transcripts(keys: [key])[key]?
            .first { $0.kind == kind && $0.number.lowercased() == number.lowercased() }
    }

    func remove(_ key: String, _ kind: Region.Kind, _ number: String, _ transcripts: Transcripts?) throws {
        let name = "\(kind.rawValue) \(number) on p.\(page)"
        let removed = try transcripts?.remove(pageKey: key, kind: kind, number: number) ?? (try Self.earlier(key, kind, number) != nil)
        if json {
            struct Body: Encodable {
                var file: String
                var page: Int
                var kind: String
                var number: String
                var removed: Bool
                var dryRun: Bool?
            }
            print(Contract.json(Body(file: path, page: page, kind: kind.rawValue, number: number, removed: removed, dryRun: dryRun ? true : nil)))
            return
        }
        if dryRun {
            print(removed ? "dry run: would remove the \(Transcript.language(of: kind)) kept for \(name); nothing was removed"
                : "dry run: \(name) has no \(Transcript.language(of: kind)) kept; nothing to remove")
            return
        }
        print(removed ? "removed the \(Transcript.language(of: kind)) kept for \(name)" : "\(name) has no \(Transcript.language(of: kind)) kept")
    }
}
