import ArgumentParser
import Foundation
import PDFCore

/// The runner that a command starts in the background. Hidden: only `pdf` itself calls it.
struct RunnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__runner",
        abstract: "Parse one file in the background. Started by other commands.",
        shouldDisplay: false
    )

    @Argument var path: String

    func run() throws {
        let store = try Store()
        throw ExitCode(Runner(path: path, store: store).run())
    }
}

/// A worker that a runner starts. Hidden: only the runner calls it.
struct WorkerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__worker",
        abstract: "Read one file's pages for a runner. Started by the runner.",
        shouldDisplay: false
    )

    enum Mode: String, ExpressibleByArgument { case index, parse }

    @Argument var mode: Mode
    @Argument var path: String
    @Option var from: Int = 0
    @Option(transform: { $0.split(separator: ",").compactMap { Int($0) } }) var pages: [Int] = []

    func run() throws {
        switch mode {
        case .index: throw ExitCode(Worker.index(path: path, from: from))
        case .parse: throw ExitCode(Worker.parse(path: path, pages: pages))
        }
    }
}

/// Reads pages through the cache and prints what came back. A check for milestone M1's
/// cache, until `pdf read` replaces it. Hidden from `pdf --help`.
struct DebugPages: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-pages",
        abstract: "Read pages through the cache and print their status.",
        shouldDisplay: false
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(name: .customLong("page"), help: "A page number, counted from 1. Repeat for more.")
    var pageNumbers: [Int] = []
    @Flag(help: "Print each page's text.") var text = false

    func run() throws {
        let started = Date()
        let reader = Reader(store: try Store())
        let wanted = pageNumbers.isEmpty ? nil : pageNumbers.map { $0 - 1 }
        switch try reader.read(path: path, pages: wanted) {
        case .fileFailed(let reason):
            print("failed: \(reason)")
            throw ExitCode(3)
        case .pages(let docID, let pageCount, let results):
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            print("doc \(docID.prefix(12)) · \(pageCount) pages · \(results.count) read in \(millis) ms")
            for (page, result) in results {
                let detail = result.status == .ok
                    ? "\(result.method) · \(result.text.count) chars · parsed in \(Int(result.parseMillis)) ms"
                    : result.reason
                print("p.\(page + 1) \(result.status.rawValue): \(detail)")
                if text && result.status == .ok { print(result.text) }
            }
            if results.contains(where: { $0.result.status == .failed }) { throw ExitCode(2) }
        }
    }
}
