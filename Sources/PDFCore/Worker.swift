import CoreGraphics
import Foundation
import PDFKit

/// One line of a worker's report to its runner, sent as JSON on standard output.
struct WorkerEvent: Codable, Equatable {
    enum Kind: String, Codable {
        /// The file opened, with this many pages.
        case opened
        /// The file could not be opened, for `reason`.
        case openFailed
        /// The worker began a page. If the page takes too long, the runner knows which one.
        case start
        /// A page's key, from an index job.
        case key
        /// A page's result, from a parse job. A `reason` means the page failed.
        case result
    }

    var kind: Kind
    var page: Int?
    var pageCount: Int?
    var key: String?
    var text: String?
    var reason: String?
    var millis: Double?
}

/// The only kind of process that opens PDF content (DESIGNS.md → Principles → Safety).
/// A runner starts it, watches its time and memory, and writes what it reports to the cache.
public enum Worker {
    /// Reports the key of every page from `start` on.
    public static func index(path: String, from start: Int) -> Int32 {
        watchParent()
        let url = URL(fileURLWithPath: path)
        guard let document = CGPDFDocument(url as CFURL) else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.classify(url: url)))
            return 0
        }
        if document.isEncrypted && !document.isUnlocked { _ = document.unlockWithPassword("") }
        guard document.isUnlocked else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.locked))
            return 0
        }
        let count = document.numberOfPages
        emit(WorkerEvent(kind: .opened, pageCount: count))
        var keyer = PageKeyer()
        for index in max(start, 0)..<max(count, start) {
            emit(WorkerEvent(kind: .start, page: index))
            plantedFault(at: index, phase: "index-")
            let key = document.page(at: index + 1).map { keyer.key(for: $0) } ?? PageKeys.missing
            emit(WorkerEvent(kind: .key, page: index, key: key))
        }
        return 0
    }

    /// Reports the text of each page in `pages`, in that order, with the page's key.
    public static func parse(path: String, pages: [Int]) -> Int32 {
        watchParent()
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.classify(url: url)))
            return 0
        }
        if document.isLocked { _ = document.unlock(withPassword: "") }
        guard !document.isLocked else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.locked))
            return 0
        }
        var keyer = PageKeyer()
        for index in pages {
            emit(WorkerEvent(kind: .start, page: index))
            plantedFault(at: index, phase: "")
            let started = DispatchTime.now().uptimeNanoseconds
            guard let page = document.page(at: index), let reference = page.pageRef else {
                emit(WorkerEvent(kind: .result, page: index, key: PageKeys.missing,
                                 reason: "PDFKit could not read this page", millis: 0))
                continue
            }
            let key = keyer.key(for: reference)
            let text = page.string ?? ""
            let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            emit(WorkerEvent(kind: .result, page: index, key: key, text: text, millis: millis))
        }
        return 0
    }

    /// Exits when the runner dies. No one would enforce this worker's limits any more, and a
    /// worker stuck inside a page would never write again, so it would never learn otherwise.
    static func watchParent() {
        let parent = getppid()
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                if getppid() != parent { _exit(1) }
            }
        }
        thread.start()
    }

    static func emit(_ event: WorkerEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }

    /// Makes a test's planted fault happen: a hang, a runaway allocation or a crash. A fault
    /// named with the prefix "index-", such as "index-hang:3", happens while keys are read.
    static func plantedFault(at index: Int, phase: String) {
        guard let fault = Env.testFault, fault.page == index, fault.kind.hasPrefix(phase) else { return }
        let kind = fault.kind.dropFirst(phase.count)
        if phase.isEmpty && fault.kind.hasPrefix("index-") { return }
        switch kind {
        case "hang":
            while true { sleep(60) }
        case "alloc":
            var blocks: [UnsafeMutableRawPointer] = []
            while true {
                guard let block = malloc(64 << 20) else { break }
                memset(block, 1, 64 << 20)
                blocks.append(block)
            }
        case "crash":
            abort()
        default:
            break
        }
    }
}

enum PageKeys {
    /// The key of a page that the PDF engine could not find. Its cached result is a failure.
    static let missing = "missing-page"

    /// The key of a page whose worker hit a limit while reading its structure. It includes the
    /// file's hash, so the failure stays with this file.
    static func unreadable(fileDigest: String, page: Int) -> String {
        "unreadable-\(fileDigest.prefix(16))-\(page)"
    }
}

/// Why a file could not be opened, in words the agent can act on
/// (DESIGNS.md → Decision: a loud failure for a file PDFKit cannot open).
enum OpenFailure {
    static let notPDF = "not a PDF"
    static let locked = "locked by a password"
    static let damaged = "damaged: PDFKit could not open it"

    static func classify(url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return damaged }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1024)
        return head.range(of: Data("%PDF-".utf8)) == nil ? notPDF : damaged
    }
}
