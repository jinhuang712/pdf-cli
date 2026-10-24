import ArgumentParser
import Foundation
import PDFCore

/// Writes a PDF's content to files and prints their paths (FEATURES.md → F6). Attachments and
/// scripts are saved as bytes and text, never opened or run.
struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Write a PDF's text, figures, tables, notes, references, attachments and scripts to files, and print their paths.",
        discussion: """
            Give at least one of the flags under "What to write". -o names the folder; by default it is a folder named after \
            the PDF, in the current folder. A file already there is never overwritten: run again with another -o. \
            Attachments are saved as they are, with no execute permission, and scripts as text; neither is \
            ever opened or run.

            What to write, at least one of: --markdown, --text, --figures, --tables, --notes, --refs, \
            --attachments, --scripts.
            Where: -o. Only some pages, for --markdown and --text alone: --page.
            Locked PDFs and output: --password-stdin, --json.

            Examples:
              pdf dump paper.pdf --markdown --figures
              pdf dump paper.pdf --text --page 2-5 -o paper-text
              pdf dump paper.pdf --tables --notes --refs --json
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Flag(help: "The document as Markdown, as pdf read gives it, to document.md.") var markdown = false
    @Flag(help: "The document as plain text, to document.txt.") var text = false
    @Flag(help: "Every figure as a PNG, vector charts included.") var figures = false
    @Flag(help: "Every table as a PNG.") var tables = false
    @Flag(help: "Footnotes, endnotes and other notes, as notes.json.") var notes = false
    @Flag(help: "The reference list, as references.json.") var refs = false
    @Flag(help: "The files attached to the PDF, saved without being opened.") var attachments = false
    @Flag(help: "The PDF's scripts, as text files that never run.") var scripts = false
    @Option(name: .customLong("page"), help: ArgumentHelp("Only these pages for --markdown and --text, such as 3 or 2-5.", valueName: "pages"))
    var pages: String?
    @Option(name: .short, help: ArgumentHelp("The output folder.", valueName: "folder")) var output: String?
    @Flag(help: "Read the password of a locked PDF from standard input.") var passwordStdin = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if ![markdown, text, figures, tables, notes, refs, attachments, scripts].contains(true) {
            throw ValidationError("give at least one of --markdown, --text, --figures, --tables, --notes, --refs, --attachments, --scripts")
        }
        if pages != nil, !markdown, !text { throw ValidationError("--page limits --markdown and --text only") }
        if let pages, ReadCommand.pages(pages) == nil { throw ValidationError("--page takes page numbers, such as 3 or 2-5") }
    }

    struct Written: Encodable {
        var kind: String
        var path: String?
        var page: Int?
        var note: String?
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try dump() }
    }

    func dump() throws {
        let password = passwordStdin ? Password.read(for: path) : nil
        let folder = Self.canonical(URL(fileURLWithPath: output ?? defaultFolder(), isDirectory: true))
        var written: [Written] = []
        var notices: [String] = []

        // The file opens first, so a locked, broken or missing file writes nothing.
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let docID: String
        let pageCount: Int
        switch try reader.read(path: path, pages: markdown || text || figures || tables || notes || refs ? nil : [0], password: password) {
        case .fileFailed(let reason):
            throw Contract.fail(file: path, reason: reason, json: json)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }

        for (wanted, format, name) in [(markdown, "md", "document.md"), (text, "text", "document.txt")] where wanted {
            var arguments = ["--format", format, "--budget", "all"]
            arguments += pages.map { ["--page", $0] } ?? ["--full"]
            arguments += ["--", path]
            let (target, handle) = try Self.create(name, in: folder, file: path, json: json)
            do {
                let exit = try Self.capture(arguments, into: handle)
                if exit == 3 || exit == 1 || exit == 64 {
                    try? FileManager.default.removeItem(at: target)
                    notices.append("\(name) was not written: pdf read exited \(exit)")
                    continue
                }
                written.append(Written(kind: format == "md" ? "markdown" : "text", path: target.path, page: nil,
                                       note: exit == 2 ? "some pages are flagged; the file's first line says which" : nil))
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }

        if figures || tables || notes || refs {
            if figures || tables {
                let info = try InfoCommand.info(path: path, docID: docID, pageCount: pageCount, store: store)
                var names = Set<String>()
                if figures, !info.figures.contains(where: { $0.kind == "figure" }) { notices.append("no figure was found") }
                if tables, !info.figures.contains(where: { $0.kind == "table" }) { notices.append("no table was found") }
                for found in info.figures where (found.kind == "figure" ? figures : tables) {
                    let kind: Region.Kind = found.kind == "figure" ? .figure : .table
                    do {
                        let region = try CropCommand.locate((kind, found.number), page: found.page, path: path, password: password,
                                                            docID: docID, store: store, reader: reader)
                        let made = try Crop.make(path: path, page: found.page, region: region.region.box.outward, grid: false, password: password)
                        let file = Dump.safeName("\(found.kind)-\(found.number).png", fallback: "\(found.kind).png", taken: &names)
                        let target = try Dump.write(try Data(contentsOf: made.url), as: file, in: folder.appendingPathComponent(found.kind + "s"))
                        written.append(Written(kind: found.kind, path: target.path, page: found.page, note: nil))
                    } catch {
                        notices.append("\(found.kind) \(found.number) (p.\(found.page)) was not written: \((error as? CropCommand.NotFound)?.description ?? "\(error)")")
                    }
                }
            }
            if notes || refs {
                let keys = try store.pageKeys(docID: docID)
                let resolved = Reader.resolve(path)
                let facts = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }
                var noteIndex = NoteIndex()
                let judged = try noteIndex.resolve(pages: Array(0..<pageCount), keys: keys, store: store)
                if notes {
                    struct Note: Encodable {
                        var page: Int
                        var kind: String
                        var id: String?
                        var blocks: [Int]
                        var text: String?
                    }
                    var list: [Note] = []
                    for page in judged.keys.sorted() {
                        let layer = try store.results(keys: [keys[page]])[keys[page]]?.pageText
                        for entry in judged[page]!.entries {
                            list.append(Note(page: page + 1, kind: entry.author ? "author note" : entry.kind.rawValue, id: entry.id,
                                             blocks: entry.blocks.map { $0 + 1 }, text: layer.map { Notes.text(of: entry, in: $0) }))
                        }
                    }
                    let target = try Self.writeJSON(list, as: "notes.json", in: folder)
                    written.append(Written(kind: "notes", path: target.path, page: nil, note: "\(list.count) note\(list.count == 1 ? "" : "s")"))
                }
                if refs {
                    var index = ReferenceIndex(outline: facts?.outline ?? [])
                    try index.refresh(keys: keys, store: store)
                    struct Entry: Encodable {
                        var id: String
                        var page: Int
                        var text: String
                        var doi: String?
                    }
                    let list = index.allEntries(notes: judged).map { Entry(id: $0.id, page: $0.page + 1, text: $0.text, doi: $0.doi) }
                    let target = try Self.writeJSON(list, as: "references.json", in: folder)
                    written.append(Written(kind: "references", path: target.path, page: nil, note: "\(list.count) entr\(list.count == 1 ? "y" : "ies"), cited or not, in the list's order"))
                }
            }
        }

        if attachments || scripts {
            let items: [Dump.Item]
            do {
                items = try Dump.supervised(path: path, folder: folder, attachments: attachments, scripts: scripts, password: password)
            } catch let error as DumpError {
                throw error.fileFailed
                    ? Contract.fail(file: path, reason: error.description, json: json)
                    : Contract.fail(path, error.description, json: json)
            }
            for item in items {
                if let skipped = item.skipped {
                    notices.append("\(item.kind) \(item.detail) was not saved: \(skipped)")
                } else {
                    written.append(Written(kind: item.kind, path: item.path, page: item.page.map { $0 + 1 }, note: item.detail))
                }
            }
            if attachments, !items.contains(where: { $0.kind == "attachment" || $0.kind == "dump" }) { notices.append("the file carries no attachment") }
            if scripts, !items.contains(where: { $0.kind == "script" || $0.kind == "dump" }) { notices.append("the file carries no script") }
        }

        if json {
            struct Body: Encodable {
                var file: String
                var folder: String
                var written: [Written]
                var notices: [String]
            }
            print(Contract.json(Body(file: path, folder: folder.path, written: written, notices: notices)))
        } else {
            for item in written {
                print((item.path ?? "") + "  (" + item.kind + (item.page.map { ", p.\($0)" } ?? "") + (item.note.map { ": " + $0 } ?? "") + ")")
            }
            for notice in notices { print("note: \(notice)") }
        }
    }

    /// The folder with every link above it resolved, so that all paths a dump prints, in text and
    /// in JSON, are in one form (`/private/tmp/…`, never `/tmp/…`). The folder itself is left as
    /// given: a link there is refused, not followed.
    static func canonical(_ folder: URL) -> URL {
        let url = folder.standardizedFileURL
        var parent = url.deletingLastPathComponent()
        var rest: [String] = []
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            rest.insert(parent.lastPathComponent, at: 0)
            parent = parent.deletingLastPathComponent()
        }
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(parent.path, &buffer) != nil else { return url }
        var resolved = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        for part in rest { resolved.appendPathComponent(part, isDirectory: true) }
        return resolved.appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted]
        return encoder
    }

    static func writeJSON<T: Encodable>(_ value: T, as name: String, in folder: URL) throws -> URL {
        try Dump.write(try encoder.encode(value), as: name, in: folder)
    }

    func defaultFolder() -> String {
        var stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        stem = String(stem.drop { $0 == "." })
        let folder = FileManager.default.currentDirectoryPath + "/" + (stem.isEmpty ? "dump" : stem)
        return folder == URL(fileURLWithPath: path).standardizedFileURL.path ? folder + "-dump" : folder
    }

    static func create(_ name: String, in folder: URL, file: String, json: Bool) throws -> (url: URL, handle: FileHandle) {
        do {
            return try Dump.create(name, in: folder)
        } catch let error as DumpError {
            throw Contract.fail(file, error.description, json: json)
        }
    }

    /// Runs `pdf read` with these arguments and writes what it prints to `handle`, which the caller
    /// made. Returns the exit code `pdf read` ended with.
    static func capture(_ arguments: [String], into handle: FileHandle) throws -> Int32 {
        var command = try ReadCommand.parse(arguments)
        fflush(stdout)
        let saved = dup(1)
        guard saved >= 0 else { throw DumpError(description: "standard output could not be saved") }
        dup2(handle.fileDescriptor, 1)
        defer {
            fflush(stdout)
            dup2(saved, 1)
            close(saved)
            try? handle.close()
        }
        do {
            try command.run()
        } catch let code as ExitCode {
            return code.rawValue
        }
        return 0
    }
}
