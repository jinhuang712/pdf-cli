import ArgumentParser
import Foundation
import PDFCore

/// Looks one footnote or endnote up (FEATURES.md → F14). It reads the whole document first, is not
/// paged and not held to the budget. A note that is not there, or named twice, is a failure in
/// the contract's shape (exit 1) that lists the ids that exist.
struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Show one footnote or endnote whole, with the places that refer to it.",
        discussion: """
            The id is the note's marker, as 7, or 3.7 where numbering restarts in each chapter. The whole \
            document is parsed first, so the output says provisional while pages are still to parse. \
            The notes of the pages you read come with pdf read.

            Examples:
              pdf note paper.pdf 7
              pdf note book.pdf 3.7 --json
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Argument(help: ArgumentHelp("The note's id, such as 7, 3.7 or '*'.", valueName: "id")) var id: String
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if id.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("note takes a note's id, such as 7, 3.7 or '*'")
        }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try lookup() }
    }

    /// One footnote or endnote by its id, with the places that refer to it, from the whole
    /// document: every page is parsed first, as a section's end needs.
    func lookup() throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let docID: String
        let pageCount: Int
        switch try reader.read(path: path, pages: [0]) {
        case .fileFailed(let reason):
            throw Contract.fail(file: path, reason: reason, json: json)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }
        _ = try reader.read(path: path, pages: nil)
        let keys = try store.pageKeys(docID: docID)
        // Pages alike share a key, so the pages parsed are counted by page, as a read counts them.
        let cached = try store.cachedKeys(keys)
        let parsed = keys.filter { cached.contains($0) }.count
        var index = NoteIndex()
        let outcome = try index.lookup(id, keys: keys, store: store)
        let provisional = parsed < pageCount ? " · provisional: \(parsed) of \(pageCount) pages parsed" : ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        switch outcome {
        case .found(var note):
            if json {
                if parsed < pageCount { note.provisional = true }
                print(String(decoding: try encoder.encode(note), as: UTF8.self))
                return
            }
            var lines = ["\(path) · \(note.kind) \(note.id) · p.\(note.page)\(provisional)", "[^\(note.id)] \(note.text)"]
            if note.references.isEmpty {
                lines.append("referenced: no raised marker of this number was found in the text")
            } else {
                lines.append("referenced:")
                lines += note.references.map { "  p.\($0.page) ¶\($0.block): \($0.excerpt)" }
            }
            print(lines.joined(separator: "\n\n").replacingOccurrences(of: "\n\nreferenced:\n\n", with: "\n\nreferenced:\n"))
        case .missing(let ids):
            throw Contract.fail(
                path,
                "no footnote or endnote is \(id)"
                    + (ids.isEmpty
                        ? "; the file has none"
                        : "; it has " + ids.prefix(12).joined(separator: ", ") + (ids.count > 12 ? ", and \(ids.count - 12) more" : "")),
                json: json)
        case .ambiguous(let ids):
            throw Contract.fail(
                path, "\(id) names notes in several series of numbering; use one of " + ids.joined(separator: ", "), json: json)
        }
    }
}

/// Looks one entry of the reference list up (FEATURES.md → F15), as `NoteCommand` does a note.
struct RefCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ref",
        abstract: "Show one entry of the reference list whole, with its DOI and the places that cite it.",
        discussion: """
            The id is the entry's number or key, as 12, BK06 or Smith2020. The whole document is parsed \
            first, so the output says provisional while pages are still to parse. The entries a read cites come with pdf read.

            Examples:
              pdf ref paper.pdf 12
              pdf ref paper.pdf Smith2020 --json
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Argument(help: ArgumentHelp("The entry's id, such as 12, BK06 or Smith2020.", valueName: "id")) var id: String
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if id.trimmingCharacters(in: CharacterSet(charactersIn: " []")).isEmpty {
            throw ValidationError("ref takes an entry's id, such as 12, BK06 or Smith2020")
        }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try lookup() }
    }

    /// One entry of the list of references by its id, with its DOI and the places that cite it,
    /// from the whole document: every page is parsed first, as for a note.
    func lookup() throws {
        let store = try Store()
        let reader = Reader(store: store, library: try Library())
        let docID: String
        let pageCount: Int
        switch try reader.read(path: path, pages: [0]) {
        case .fileFailed(let reason):
            throw Contract.fail(file: path, reason: reason, json: json)
        case .pages(let id, let count, _):
            docID = id
            pageCount = count
        }
        _ = try reader.read(path: path, pages: nil)
        let keys = try store.pageKeys(docID: docID)
        let cached = try store.cachedKeys(keys)
        let parsed = keys.filter { cached.contains($0) }.count
        let resolved = Reader.resolve(path)
        let facts = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }
        var notes = NoteIndex()
        let judged = try notes.resolve(pages: Array(0..<pageCount), keys: keys, store: store)
        var index = ReferenceIndex(outline: facts?.outline ?? [])
        try index.refresh(keys: keys, store: store)
        let outcome = try index.lookup(id, notes: judged, keys: keys, store: store, links: facts?.annotations ?? [])
        let provisional = parsed < pageCount ? " · provisional: \(parsed) of \(pageCount) pages parsed" : ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        switch outcome {
        case .found(var entry):
            if json {
                if parsed < pageCount { entry.provisional = true }
                print(String(decoding: try encoder.encode(entry), as: UTF8.self))
                return
            }
            var lines = ["\(path) · reference \(entry.id) · p.\(entry.page)\(provisional)", "[\(entry.id)] \(entry.text)"]
            if let doi = entry.doi { lines.append("doi: \(doi)") }
            if entry.citations.isEmpty {
                lines.append("cited: no citation of it was found in the text")
            } else {
                lines.append("cited:\n" + entry.citations.map { "  p.\($0.page) ¶\($0.block): \($0.excerpt)" }.joined(separator: "\n"))
            }
            print(lines.joined(separator: "\n\n"))
        case .missing(let ids):
            throw Contract.fail(
                path,
                "no entry of the reference list is \(id)"
                    + (ids.isEmpty
                        ? "; the file has no list of references found so far"
                        : "; it has " + ids.prefix(12).joined(separator: ", ") + (ids.count > 12 ? ", and \(ids.count - 12) more" : "")),
                json: json)
        case .ambiguous(let ids):
            throw Contract.fail(path, "\(id) names several entries; use one of " + ids.prefix(20).joined(separator: ", "), json: json)
        }
    }
}
