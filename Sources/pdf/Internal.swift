import ArgumentParser
import Foundation
import PDFCore

/// Measures the OCR checks on a file. A developer's tool, hidden from `pdf --help`: it opens
/// the PDF in this process, outside a worker.
struct DebugOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-ocr",
        abstract: "Print the sample check, or one page read through OCR.",
        shouldDisplay: false
    )

    @Argument(help: "Paths to PDF files.") var paths: [String]
    @Option(help: "Read this page, counted from 1, through OCR instead.") var page: Int?
    @Option(help: "Turn the page by this many degrees first.") var rotation = 0
    @Flag(help: "Print the page's OCR text.") var text = false

    func run() async throws {
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard let page else {
                if let sample = await OCRDiagnostics.sampleAgreement(path: path) {
                    print("\(name): page \(sample.page + 1) agrees \(String(format: "%.3f", sample.agreement))")
                } else {
                    print("\(name): no page to sample")
                }
                continue
            }
            guard let result = await OCRDiagnostics.page(path: path, index: page - 1, rotation: rotation),
                  let ocr = result.ocr else {
                print("\(name): OCR failed")
                continue
            }
            print("\(name) p.\(page): \(ocr.blocks.count) blocks, \(ocr.words) words, confidence "
                  + String(format: "%.2f", ocr.confidence ?? 0))
            if text { print(ocr.text) }
            // How far each OCR block's center lies from the nearest text-layer block's center.
            let centers = result.layer.blocks.map { ($0.box.x + $0.box.width / 2, $0.box.y + $0.box.height / 2) }
            let distances = ocr.blocks.map { block -> Double in
                let x = block.box.x + block.box.width / 2, y = block.box.y + block.box.height / 2
                return centers.map { hypot($0.0 - x, $0.1 - y) }.min() ?? 1
            }.sorted()
            if !distances.isEmpty {
                print("  block centers off by: median \(String(format: "%.3f", distances[distances.count / 2])) of the page")
            }
        }
    }
}

/// The runner that a command starts in the background. Hidden: only `pdf` itself calls it.
struct RunnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__runner",
        abstract: "Parse one file in the background. Started by other commands.",
        shouldDisplay: false
    )

    @Argument var path: String
    @Option(help: "The pages, counted from 0, that the command waits on, or \"all\".") var pages = ""
    @Option(help: "How many workers to run at once, from pdf add -j.") var workers: Int?
    @Flag(name: .customLong("index-only"), help: "Index the file and stop (pdf reparse).") var indexOnly = false
    @Option(help: "Read these pages again, counted from 0, or \"all\", and replace their results (pdf reparse).")
    var reparse: String?
    @Flag(help: "With --reparse: read by OCR.") var ocr = false

    func run() throws {
        let store = try Store()
        if let reparse {
            let pages = reparse == "all" ? nil : reparse.split(separator: ",").compactMap { Int($0) }
            throw ExitCode(Runner(path: path, store: store, workers: workers, job: .reparse(pages: pages, ocr: ocr)).run())
        }
        if indexOnly { throw ExitCode(Runner(path: path, store: store, workers: workers, job: .indexOnly).run()) }
        let waited: Runner.Waited = pages == "all"
            ? .all
            : .pages(pages.split(separator: ",").compactMap { Int($0) })
        throw ExitCode(Runner(path: path, store: store, waited: waited, workers: workers).run())
    }
}

/// A worker that a runner starts. Hidden: only the runner calls it.
struct WorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__worker",
        abstract: "Read one file's pages for a runner. Started by the runner.",
        shouldDisplay: false
    )

    enum Mode: String, ExpressibleByArgument { case index, sample, facts, parse, crop, dump, words }

    @Argument var mode: Mode
    @Argument var path: String
    @Option var from: Int = 0
    @Option(transform: { $0.split(separator: ",").compactMap { Int($0) } }) var pages: [Int] = []
    @Flag var repairSpaces = false
    @Flag var readAllByOCR = false
    @Flag var background = false
    @Option var out: String?
    @Option var bbox: String?
    @Flag var grid = false
    @Flag var attachments = false
    @Flag var scripts = false

    func run() async throws {
        if background { Worker.startInBackground() }
        switch mode {
        case .index:
            throw ExitCode(Worker.index(path: path, from: from))
        case .sample:
            throw ExitCode(await Worker.sample(path: path))
        case .facts:
            throw ExitCode(Worker.facts(path: path))
        case .parse:
            throw ExitCode(await Worker.parse(path: path, pages: pages, repairSpaces: repairSpaces,
                                              readAllByOCR: readAllByOCR))
        case .crop:
            guard let page = pages.first, let out else { throw ExitCode(64) }
            throw ExitCode(Worker.crop(path: path, page: page, bbox: bbox, grid: grid, out: out))
        case .words:
            guard let out else { throw ExitCode(64) }
            throw ExitCode(Worker.words(path: path, input: out))
        case .dump:
            guard let out else { throw ExitCode(64) }
            throw ExitCode(Worker.dump(path: path, out: out, attachments: attachments, scripts: scripts))
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
    @Flag(help: "Print each page's figures, tables and equations.") var regions = false

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
                let layer = result.pageText
                var detail = result.status == .ok
                    ? "\(result.method) · \(layer?.blocks.count ?? 0) blocks · \(layer?.words ?? 0) words · "
                        + "\(layer?.runTogether ?? 0) run together · parsed in \(Int(result.parseMillis)) ms"
                    : result.reason
                if let unsure = layer?.unsure { detail += " · \(unsure.count) unsure" }
                if let agreement = layer?.agreement { detail += " · OCR readings agree \(String(format: "%.2f", agreement))" }
                let judged = Quality.judge(result).status
                if result.status == .ok && judged != .ok { detail += " · judged \(judged.rawValue)" }
                print("p.\(page + 1) \(result.status.rawValue): \(detail)")
                if text && result.status == .ok { print(result.text) }
                if regions, let layer {
                    for picture in layer.pictures ?? [] { print("  picture \(picture.kind) [\(Output.format(picture.box))]") }
                    for region in layer.regions ?? [] {
                        let caption = region.caption.map { layer.blocks[$0].text }.joined(separator: " ")
                        let inside = region.blocks.map { layer.blocks[$0].text }.joined(separator: " | ")
                        print("  \(region.name) [\(Output.format(region.box))] caption: \(caption.prefix(70))")
                        print("    \(region.blocks.count) blocks inside: \(inside.prefix(150))")
                    }
                }
            }
            if results.contains(where: { $0.result.status == .failed }) { throw ExitCode(2) }
        }
    }
}
