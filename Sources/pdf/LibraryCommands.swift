import ArgumentParser
import Darwin
import Foundation
import PDFCore

/// Parses PDFs once, so every later command reads them from the cache (FEATURES.md → F1).
struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Parse PDFs once, so every later command reads them from the cache.",
        discussion: """
            Accepts files, folders and glob patterns. A folder adds every PDF in it and in its subfolders.

            Exit codes: 0 every page read well; 2 some pages failed or are flagged, the rest are \
            cached; 3 every path failed and one failed to open; 1 none could be tried (every path \
            missing); 64 used wrongly.

            Examples:
              pdf add paper.pdf
              pdf add ~/papers
              pdf add "papers/*.pdf" -j 2
              pdf add paper.pdf --json
            """
    )

    @Argument(help: "PDF files, folders or glob patterns.") var paths: [String]
    @Option(
        name: .customShort("j"),
        help: ArgumentHelp(
            "Parse with fewer workers than the Mac allows: at most the number pdf setup's memory budget gives, which is half the performance cores until it is set.",
            valueName: "N"))
    var workers: Int?
    @Option(help: "The password that opens a locked PDF. Other users of the Mac can see it in this command's line while it runs; --password-stdin keeps it out.")
    var password: String?
    @Flag(help: "Read the password from standard input, as in: echo \"$PW\" | pdf add paper.pdf --password-stdin")
    var passwordStdin = false
    @Flag(help: "Print JSON.") var json = false

    /// One file of the run: what was added, or why not.
    struct Added: Encodable {
        var file: String
        var id: String?
        var title: String?
        var pages: Int?
        /// The flagged pages, as the text line gives them; absent when none is.
        var flagged: String?
        var failed: String?
    }

    func validate() throws {
        if let workers, workers < 1 { throw ValidationError("-j needs 1 or more") }
        if password != nil && passwordStdin { throw ValidationError("give the password one way: --password or --password-stdin") }
    }

    func run() throws {
        try Contract.guarding("pdf add", json: json) { try add() }
    }

    func add() throws {
        var files: [String] = []
        var seen = Set<String>()
        var outcome: [Added] = []
        var missing = 0
        // A file that failed to open (exit 3) and one that could not be tried (exit 1) are counted apart.
        var unopenable = 0
        func note(_ entry: Added) {
            outcome.append(entry)
            if !json { print(entry.failed.map { "\(entry.file): failed: \($0)" } ?? "") }
        }
        for path in paths {
            let found = Self.pdfs(at: path)
            if found.isEmpty {
                // A path that names nothing is a missing file; one that names a folder or a pattern with no PDF in it is not.
                let names = FileManager.default.fileExists(atPath: path) || path.contains(where: { "*?[".contains($0) })
                note(Added(file: path, failed: names ? "no PDF found" : "no such file"))
                missing += 1
            }
            for file in found where seen.insert(Reader.resolve(file)).inserted { files.append(file) }
        }
        // No PDF found, no password to ask for.
        let password = passwordStdin && !files.isEmpty ? Password.read(for: files.count == 1 ? files[0] : "the locked PDFs")
            : self.password
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let picks = try Picks()
        var flagged = 0, failed = missing
        for file in files {
            do {
                switch try reader.read(path: file, pages: nil, workers: workers.map { min($0, Env.workerCount) }, password: password) {
                case .fileFailed(let reason):
                    failed += 1
                    unopenable += 1
                    note(Added(file: file, failed: Output.failure(reason, file: file)))
                case .pages(let docID, let pageCount, let results):
                    let keys = try store.pageKeys(docID: docID)
                    let pages = results.map { Output.Page(index: $0.page, result: $0.result, key: keys[$0.page]) }
                    let flags = Output.flagged(pages, picks: try picks.picks(keys: keys))
                    if flags != nil { flagged += 1 }
                    let title = try store.documentInfo(docID: docID)?.title ?? ""
                    let entry = LibraryEntry(path: Reader.resolve(file), docID: docID, title: title, pageCount: pageCount,
                                             addedAt: Date())
                    outcome.append(Added(file: file, id: entry.shortID, title: entry.displayTitle, pages: pageCount, flagged: flags))
                    if !json {
                        print(
                            "\(entry.shortID) · \(entry.displayTitle) · \(count(pageCount, "page")) · "
                                + (flags.map { "flagged: \($0)" } ?? "ok") + " · \(file)")
                    }
                }
            } catch {
                failed += 1
                if case ReadError.notFound = error {
                    note(Added(file: file, failed: "no such file"))
                } else {
                    unopenable += 1
                    note(Added(file: file, failed: Contract.reason(of: error)))
                }
            }
        }
        let total = files.count + missing
        if json {
            struct Body: Encodable {
                var files: [Added]
                var added: Int
                var flagged: Int
                var failed: Int
            }
            print(Contract.json(Body(files: outcome, added: total - failed, flagged: flagged, failed: failed)))
        } else if total > 1 {
            print("added \(total - failed) of \(count(total, "PDF")) · \(flagged) with flagged pages · \(failed) failed")
        }
        // Every file failed: 3 if one failed to open, 1 if none could even be tried (all missing).
        if failed == total { throw ExitCode(unopenable > 0 ? Contract.fileFailed : Contract.couldNotRun) }
        if failed + flagged > 0 { throw ExitCode(2) }
    }

    /// The PDFs a path names: the file itself, every PDF in a folder and its subfolders, or the
    /// PDFs among the matches of a glob pattern that the shell left unexpanded. A file named
    /// outright is tried whatever its name; in a folder or a pattern, only names ending in
    /// ".pdf" count. A link to a PDF counts; links to folders are not followed, so a loop of
    /// links cannot trap the walk.
    static func pdfs(at path: String, named: Bool = true) -> [String] {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { return named || isPDF(URL(fileURLWithPath: path)) ? [path] : [] }
            let folder = URL(fileURLWithPath: path)
            guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return [] }
            return walk.compactMap { $0 as? URL }.filter(isPDF).map(\.path).sorted()
        }
        guard path.contains(where: { "*?[".contains($0) }) else { return [] }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, GLOB_TILDE, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }
            .flatMap { pdfs(at: $0, named: false) }
    }

    /// A regular file, or a link to one, whose name ends in ".pdf".
    static func isPDF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
        return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

/// Lists the library (FEATURES.md → F11).
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List every PDF in the library, with its ID, title, page count and flagged pages.",
        discussion: """
            Exit codes: 0 done, also when the library is empty; 1 it could not read the library; 64 \
            used wrongly.

            Examples:
              pdf ls
              pdf ls --json
            """
    )

    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding("pdf ls", json: json) { try list() }
    }

    func list() throws {
        let entries = try Library().entries()
        struct Item: Encodable {
            var id: String
            var title: String
            var pages: Int
            var status: String
            var file: String
        }
        var items: [Item] = []
        if !entries.isEmpty {
            let store = try Store()
            let picks = try Picks()
            for entry in entries {
                items.append(
                    Item(
                        id: entry.shortID, title: entry.displayTitle, pages: entry.pageCount,
                        status: try status(of: entry, store: store, picks: picks), file: entry.path))
            }
        }
        if json {
            print(Contract.json(["documents": items]))
        } else if items.isEmpty {
            print("the library is empty · add a PDF with: pdf add <path>")
        } else {
            for item in items {
                print("\(item.id) · \(item.title) · \(count(item.pages, "page")) · \(item.status) · \(item.file)")
            }
        }
    }

    /// What the cache holds for the entry: its flagged pages, how far it is parsed, or why
    /// nothing can be read.
    func status(of entry: LibraryEntry, store: Store, picks: Picks) throws -> String {
        guard let stat = FileStat(path: entry.path) else {
            return FileStat.isGone(path: entry.path) ? "file missing" : "out of reach, as on a drive not plugged in"
        }
        guard try store.entry(path: entry.path, stat: stat) != nil else {
            // An entry the file still matches, from an older pdf, is no change of the file.
            return try store.hasEntry(path: entry.path, stat: stat) ? "pdf was updated, read it again" : "changed since it was read"
        }
        let keys = try store.pageKeys(docID: entry.docID)
        guard !keys.isEmpty else { return "not parsed" }
        // Judging needs no page's text, so a library of thousands of files lists without
        // decoding one.
        let results = try store.verdicts(keys: keys)
        let parsed = keys.indices.filter { results[keys[$0]] != nil }
        let pages = parsed.map { Output.Page(index: $0, result: results[keys[$0]]!, key: keys[$0]) }
        let flags = Output.flagged(pages, picks: try picks.picks(keys: keys)).map { "flagged: \($0)" }
        if parsed.count < keys.count {
            return "parsed \(parsed.count) of \(keys.count) pages" + (flags.map { " · \($0)" } ?? "")
        }
        return flags ?? "ok"
    }
}

/// Removes one PDF from the library and its results from the cache (FEATURES.md → F11).
struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a PDF from the library, and its results from the cache.",
        discussion: """
            Picks stay, so a PDF added again shows them again. --dry-run says what would go and what would stay (the \
            picks, and the results another copy of the file still uses), and removes nothing.

            Exit codes: 0 removed (with --dry-run, what would be); 1 it could not run (a file or ID \
            not in the library); 64 used wrongly.

            Examples:
              pdf rm paper.pdf
              pdf rm 1f9472ae
              pdf rm paper.pdf --json
              pdf rm paper.pdf --dry-run
            """
    )

    @Argument(help: "The PDF's path, or its ID as pdf ls shows it.") var target: String
    @Flag(help: "Say what would be removed and what would stay, and change nothing.") var dryRun = false
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding(target, json: json) { try remove() }
    }

    func remove() throws {
        // A dry run opens only the databases that exist, and the library read only: with none, it
        // finds what the real run finds in the new empty ones, nothing.
        let library: Library? = dryRun && !Library.exists() ? nil : try Library(readOnly: dryRun)
        let store: Store? = dryRun && !Store.exists() ? nil : try Store(readOnly: dryRun)
        let entries = try library?.entries() ?? []
        let path = Reader.resolve(target)
        var paths: [String]
        var shownID: String?
        var shownTitle: String
        if let entry = entries.first(where: { Reader.systemAliasless($0.path) == path }) {
            paths = Array(Set([entry.path, path])).sorted()
            shownID = entry.shortID
            shownTitle = entry.displayTitle
        } else if try store?.knows(path: path) ?? false {
            // A file the cache knows that never joined the library, as one read by a hidden
            // command.
            paths = [path]
            shownTitle = URL(fileURLWithPath: path).lastPathComponent
        } else {
            let id = target.lowercased()
            let documents = Set(entries.map(\.docID).filter { id.count >= 4 && $0.hasPrefix(id) })
            guard documents.count == 1, let docID = documents.first else {
                throw Contract.fail(
                    target,
                    documents.isEmpty
                        ? "not in the library"
                        : "matches \(documents.count) PDFs; give more of the ID or the path", json: json)
            }
            let listed = entries.filter { $0.docID == docID }
            paths = Array(Set(listed.map(\.path) + (try store?.paths(docID: docID) ?? []))).sorted()
            shownID = listed[0].shortID
            shownTitle = listed[0].displayTitle
        }
        let shown = shownID.map { "\($0) · \(shownTitle)" } ?? shownTitle
        // The documents these files carry, for what a dry run says stays.
        var docIDs = Set(entries.filter { paths.contains($0.path) }.map(\.docID))
        if dryRun, let store { docIDs.formUnion(try store.docIDs(paths: paths)) }
        var kept = (picks: 0, transcripts: 0, shared: [String]())
        if dryRun, let store {
            let keys = try docIDs.flatMap { try store.pageKeys(docID: $0) }
            if Library.exists() {
                kept.picks = try Picks(readOnly: true).picks(keys: keys).values.reduce(0) { $0 + $1.count }
                kept.transcripts = try Transcripts(readOnly: true).transcripts(keys: keys).values.reduce(0) { $0 + $1.count }
            }
            kept.shared = Set(try docIDs.flatMap { try store.paths(docID: $0) }).subtracting(paths).sorted()
        }
        let removed = try dryRun ? store?.wouldRemove(paths: paths) ?? Store.Removed() : store?.remove(paths: paths) ?? Store.Removed()
        let unlisted = dryRun ? entries.filter { paths.contains($0.path) }.count : try library?.remove(paths: paths) ?? 0
        guard removed.files + unlisted > 0 else {
            throw Contract.fail(target, "not in the library", json: json)
        }
        if json {
            struct Body: Encodable {
                var id: String?
                var title: String
                var files: [String]
                var cachedPages: Int
                var dryRun: Bool?
                var picksKept: Int?
                var transcriptsKept: Int?
                var sharedWith: [String]?
            }
            print(
                Contract.json(
                    Body(
                        id: shownID, title: shownTitle, files: paths, cachedPages: removed.pages, dryRun: dryRun ? true : nil,
                        picksKept: dryRun ? kept.picks : nil, transcriptsKept: dryRun ? kept.transcripts : nil,
                        sharedWith: dryRun ? kept.shared : nil)))
        } else if dryRun {
            let picks: String = count(kept.picks, "pick")
            let transcripts: String = count(kept.transcripts, "transcript")
            var stays: [String] = ["\(picks) and \(transcripts) stay"]
            if !kept.shared.isEmpty { stays.append("the results another copy uses stay: " + kept.shared.joined(separator: ", ")) }
            let pages: String = count(removed.pages, "cached page")
            let gone: String = paths.joined(separator: ", ")
            print("dry run: would remove \(shown) · \(pages) · \(gone); " + stays.joined(separator: "; ") + "; nothing was removed")
        } else {
            print("removed \(shown) · \(count(removed.pages, "cached page")) · " + paths.joined(separator: ", "))
        }
    }
}

/// "1 file", "2 files".
func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
    "\(number) \(number == 1 ? one : many ?? one + "s")"
}
