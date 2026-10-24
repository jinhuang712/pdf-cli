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

            Examples:
              pdf add paper.pdf
              pdf add ~/papers
              pdf add "papers/*.pdf" -j 2
              pdf add paper.pdf --json
            """
    )

    @Argument(help: "PDF files, folders or glob patterns.") var paths: [String]
    @Option(name: .customShort("j"),
            help: ArgumentHelp("Parse with up to N workers at once. By default, every parse on the Mac shares half the performance cores.",
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
                switch try reader.read(path: file, pages: nil, workers: workers, password: password) {
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
        guard try store.entry(path: entry.path, stat: stat) != nil else { return "changed since it was read" }
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
            Picks stay, so a PDF added again shows them again.

            Examples:
              pdf rm paper.pdf
              pdf rm 1f9472ae
              pdf rm paper.pdf --json
            """
    )

    @Argument(help: "The PDF's path, or its ID as pdf ls shows it.") var target: String
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding(target, json: json) { try remove() }
    }

    func remove() throws {
        let library = try Library()
        let store = try Store()
        let entries = try library.entries()
        let path = Reader.resolve(target)
        var paths: [String]
        var shown: String
        if let entry = entries.first(where: { $0.path == path }) {
            paths = [path]
            shown = "\(entry.shortID) · \(entry.displayTitle)"
        } else if try store.knows(path: path) {
            // A file the cache knows that never joined the library, as one read by a hidden
            // command.
            paths = [path]
            shown = URL(fileURLWithPath: path).lastPathComponent
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
            paths = Array(Set(listed.map(\.path) + (try store.paths(docID: docID)))).sorted()
            shown = "\(listed[0].shortID) · \(listed[0].displayTitle)"
        }
        let removed = try store.remove(paths: paths)
        let unlisted = try library.remove(paths: paths)
        guard removed.files + unlisted > 0 else {
            throw Contract.fail(target, "not in the library", json: json)
        }
        if json {
            struct Body: Encodable {
                var removed: String
                var files: [String]
                var cachedPages: Int
            }
            print(Contract.json(Body(removed: shown, files: paths, cachedPages: removed.pages)))
        } else {
            print("removed \(shown) · \(count(removed.pages, "cached page")) · " + paths.joined(separator: ", "))
        }
    }
}

/// Removes cached results that no read can use any more (FEATURES.md → F11).
struct GCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Remove cached results for files that no longer exist, and for old parser versions.",
        discussion: """
            Examples:
              pdf gc
              pdf gc --json
            """
    )

    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding("pdf gc", json: json) { try collect() }
    }

    func collect() throws {
        let store = try Store()
        let before = store.size
        let removed = try store.collectGarbage()
        let library = try Library()
        let gone = try library.entries().filter { FileStat.isGone(path: $0.path) }.map(\.path)
        try library.remove(paths: gone)
        let compacted = store.compact()
        let crops = Crop.removeOld()
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        bytes.allowsNonnumericFormatting = false
        // The size is what compacting the cache gave back, which includes the space that results
        // removed earlier left behind, and the write-ahead log; the counts are only what this run removed.
        let freed = compacted ? max(0, before - store.size) : 0
        if json {
            struct Body: Encodable {
                var removed: [String: Int]
                var freedBytes: Int64
                var compacted: Bool
            }
            print(
                Contract.json(
                    Body(
                        removed: [
                            "files": removed.files, "documents": removed.documents, "pages": removed.pages,
                            "libraryEntries": gone.count, "crops": crops,
                        ],
                        freedBytes: freed, compacted: compacted)))
            return
        }
        let counts = [
            count(removed.files, "file") + " gone or changed", count(removed.documents, "document"),
            count(removed.pages, "page result"),
            count(gone.count, "library entry", "library entries")
                + " for files gone", count(crops, "crop") + " older than 7 days",
        ]
        print(
            "removed " + counts.joined(separator: ", ")
                + (compacted
                    ? " · compacted the cache, freed \(bytes.string(fromByteCount: freed))"
                    : ""))
        if !compacted { print("a parse is running, so the space returns after the next pdf gc") }
    }
}

/// "1 file", "2 files".
func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
    "\(number) \(number == 1 ? one : many ?? one + "s")"
}
