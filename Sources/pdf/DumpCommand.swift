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
            Give at least one of the flags below. -o names the folder; by default it is a folder named after \
            the PDF, in the current folder. A file already there is never overwritten: run again with another -o. \
            Attachments are saved as they are, with no execute permission, and scripts as text; neither is \
            ever opened or run.
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
        let password = passwordStdin ? Password.read(for: path) : nil
        let folder = URL(fileURLWithPath: output ?? defaultFolder(), isDirectory: true).standardizedFileURL
        var written: [Written] = []
        var notices: [String] = []

        for (wanted, format, name) in [(markdown, "md", "document.md"), (text, "text", "document.txt")] where wanted {
            do {
                let target = try Dump.write(Data(), as: name, in: folder)
                var arguments = [path, "--full", "--budget", "all", "--format", format]
                if let pages { arguments += ["--page", pages] }
                let flagged = try Self.capture(arguments, into: target)
                written.append(Written(kind: format == "md" ? "markdown" : "text", path: target.path, page: nil, note: flagged ? "some pages are flagged; read the file's summary line" : nil))
            } catch let error as DumpError {
                print("\(path): failed: \(error.description)")
                throw ExitCode(1)
            }
        }

        if figures || tables || notes || refs {
            let store = try Store()
            let reader = Reader(store: store, library: try Library())
            let docID: String
            let pageCount: Int
            switch try reader.read(path: path, pages: nil, password: password) {
            case .fileFailed(let reason):
                print(json ? ReadCommand.failureJSON(path, reason) : "\(path): failed: \(reason)")
                throw ExitCode(3)
            case .pages(let id, let count, _):
                docID = id
                pageCount = count
            }
            if figures || tables {
                let info = try InfoCommand.info(path: path, docID: docID, pageCount: pageCount, store: store)
                var names = Set<String>()
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
                    written.append(Written(kind: "notes", path: target.path, page: nil, note: "\(list.count) notes"))
                }
                if refs {
                    var index = ReferenceIndex(outline: facts?.outline ?? [])
                    try index.refresh(keys: keys, store: store)
                    let cited = index.resolve(pages: Array(0..<pageCount), notes: judged)
                    struct Entry: Encodable {
                        var id: String
                        var page: Int
                        var text: String
                        var doi: String?
                    }
                    var seen = Set<String>()
                    var list: [Entry] = []
                    for page in cited.keys.sorted() {
                        for entry in cited[page]!.entries.values.sorted(by: { $0.id.localizedStandardCompare($1.id) == .orderedAscending })
                        where seen.insert("\(entry.page)/\(entry.id)").inserted {
                            list.append(Entry(id: entry.id, page: entry.page + 1, text: entry.text, doi: entry.doi))
                        }
                    }
                    let target = try Self.writeJSON(list, as: "references.json", in: folder)
                    written.append(Written(kind: "references", path: target.path, page: nil, note: "\(list.count) entries"))
                }
            }
        }

        if attachments || scripts {
            do {
                for item in try Dump.payloads(path: path, folder: folder, attachments: attachments, scripts: scripts, password: password) {
                    if let skipped = item.skipped {
                        notices.append("\(item.kind) \(item.detail) was not saved: \(skipped)")
                    } else {
                        written.append(Written(kind: item.kind, path: item.path, page: item.page.map { $0 + 1 }, note: item.detail))
                    }
                }
            } catch let error as DumpError {
                print(json ? ReadCommand.failureJSON(path, error.description) : "\(path): failed: \(error.description)")
                throw ExitCode(3)
            }
            if attachments, !written.contains(where: { $0.kind == "attachment" }) { notices.append("the file carries no attachment") }
            if scripts, !written.contains(where: { $0.kind == "script" }) { notices.append("the file carries no script") }
        }

        if json {
            struct Body: Encodable {
                var file: String
                var folder: String
                var written: [Written]
                var notices: [String]
            }
            print(String(decoding: try Self.encoder.encode(Body(file: path, folder: folder.path, written: written, notices: notices)), as: UTF8.self))
        } else {
            for item in written {
                print((item.path ?? "") + "  (" + item.kind + (item.page.map { ", p.\($0)" } ?? "") + (item.note.map { ": " + $0 } ?? "") + ")")
            }
            for notice in notices { print("note: \(notice)") }
        }
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
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return FileManager.default.currentDirectoryPath + "/" + (stem.isEmpty ? "dump" : stem)
    }

    /// Runs `pdf read` with these arguments and writes what it prints to `target`. True when it
    /// ended with an exit code that flags pages.
    static func capture(_ arguments: [String], into target: URL) throws -> Bool {
        var command = try ReadCommand.parse(arguments)
        fflush(stdout)
        let saved = dup(1)
        guard saved >= 0, let sink = FileHandle(forWritingAtPath: target.path) else { throw DumpError(description: "\(target.path) could not be opened") }
        dup2(sink.fileDescriptor, 1)
        var flagged = false
        defer {
            fflush(stdout)
            dup2(saved, 1)
            close(saved)
            try? sink.close()
        }
        do {
            try command.run()
        } catch let code as ExitCode {
            flagged = code.rawValue != 0
        }
        return flagged
    }
}
