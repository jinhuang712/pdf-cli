import ArgumentParser
import Foundation
import PDFCore

/// A cheap first look at a PDF (FEATURES.md → F2). It answers once the file is indexed and its
/// first page parsed; what comes from the text covers the pages parsed so far, and says so.
struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Give a first look at a PDF: its title, size, sections, flagged pages, comments, attachments and scripts.",
        discussion: """
            Examples:
              pdf info paper.pdf
              pdf info paper.pdf --json
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding(path, json: json) { try info() }
    }

    func info() throws {
        let store = try Store()
        switch try Reader(store: store, library: try Library()).read(path: path, pages: [0]) {
        case .fileFailed(let reason):
            throw Contract.fail(file: path, reason: reason, json: json)
        case .pages(let docID, let pageCount, _):
            let info = try Self.info(path: path, docID: docID, pageCount: pageCount, store: store)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
                print(String(decoding: try encoder.encode(info), as: UTF8.self))
            } else {
                print(info.render(), terminator: "")
            }
        }
    }

    /// The first look, from the file's facts and every page cached so far.
    static func info(path: String, docID: String, pageCount: Int, store: Store) throws -> Info {
        let resolved = Reader.resolve(path)
        let facts = try FileStat(path: resolved).flatMap { try store.facts(path: resolved, stat: $0) }
        let keys = try store.pageKeys(docID: docID)
        return Info(file: path, pageCount: pageCount, pages: try cachedPages(docID: docID, store: store), facts: facts,
                    metadataTitle: try store.documentInfo(docID: docID)?.title ?? "",
                    picks: try Picks().picks(keys: keys), savedByPDFKit: try store.savedByPDFKit(docID: docID))
    }

    /// Every page of the document cached so far, in order.
    static func cachedPages(docID: String, store: Store) throws -> [Output.Page] {
        let keys = try store.pageKeys(docID: docID)
        let cached = try store.cachedKeys(keys)
        let results = try store.results(keys: keys.filter { cached.contains($0) })
        return keys.indices.compactMap { index in
            results[keys[index]].map { Output.Page(index: index, result: $0, key: keys[index]) }
        }
    }
}
