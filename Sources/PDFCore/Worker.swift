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
        /// The sample check's result, from an index job: how far the text layer of `page`
        /// agrees with OCR.
        case sample
    }

    var kind: Kind
    var page: Int?
    var pageCount: Int?
    var key: String?
    var text: String?
    var reason: String?
    var millis: Double?
    /// The page's text layer, as JSON.
    var data: String?
    /// The step that produced the page, such as `pdfkit` or `pdfkit+ocr-spaces`.
    var method: String?
    /// From the font check: the page's body-font word gaps, and the ones PDFKit would drop.
    var gaps: Int?
    var risky: Int?
    /// From the sample check: the share of characters the text layer and OCR agree on.
    var agreement: Double?
}

/// The only kind of process that opens PDF content (DESIGNS.md → Principles → Safety).
/// A runner starts it, watches its time and memory, and writes what it reports to the cache.
public enum Worker {
    /// Reports the key of every page from `start` on, with the page's font check.
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
            guard let page = document.page(at: index + 1) else {
                emit(WorkerEvent(kind: .key, page: index, key: PageKeys.missing))
                continue
            }
            let check = FontCheck(page: page)
            emit(WorkerEvent(kind: .key, page: index, key: keyer.key(for: page), gaps: check.gaps, risky: check.risky))
        }
        return 0
    }

    /// Reports the file's sample check. The runner runs it in a worker of its own, beside the
    /// index, so a new file waits for the slower of the two, not for both.
    public static func sample(path: String) async -> Int32 {
        watchParent()
        plantedFault(at: 0, phase: "sample-")
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else { return 0 }
        if document.isLocked { _ = document.unlock(withPassword: "") }
        guard !document.isLocked else { return 0 }
        let started = DispatchTime.now().uptimeNanoseconds
        if let sample = await OCR.sampleAgreement(document) {
            emit(WorkerEvent(kind: .sample, page: sample.page, agreement: sample.agreement))
        }
        Env.log("sample check took \((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) ms")
        return 0
    }

    /// Reports the text layer of each page in `pages`, in that order, with the page's key.
    /// A page with no usable text layer is read by OCR, and so is every page with `readAllByOCR`.
    /// With `repairSpaces`, each page's word breaks come from Apple OCR.
    public static func parse(path: String, pages: [Int], repairSpaces: Bool = false,
                             readAllByOCR: Bool = false) async -> Int32 {
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
            let check = FontCheck(page: reference)
            let layer: PageText
            let method: String
            if readAllByOCR || OCR.needed(text: page.string ?? "", images: check.images) {
                let textLayer = TextLayer.read(page)
                if var read = await OCR.pageText(page), !OCR.lostText(ocr: read, layer: textLayer) {
                    let replaced = (page.string ?? "").split(whereSeparator: \.isNewline)
                        .map { TextCleanup.line(String($0)) }.filter { !$0.isEmpty }.joined(separator: "\n")
                    if !replaced.isEmpty { read.replacedText = replaced }
                    layer = read
                    method = "ocr"
                } else if textLayer.words > 0 {
                    // OCR could not read the page, or read far less than its text layer holds:
                    // the layer serves, marked so the quality checks can flag it.
                    layer = textLayer
                    method = "pdfkit+ocr-failed"
                } else {
                    emit(WorkerEvent(kind: .result, page: index, key: key,
                                     reason: "Apple OCR could not read this page", millis: 0))
                    continue
                }
            } else {
                let repair = repairSpaces || check.pageAtRisk
                let spaces = repair ? await SpaceRepair.spacesBefore(page) : []
                layer = TextLayer.read(page, spacesBefore: spaces)
                method = repair ? "pdfkit+ocr-spaces" : "pdfkit"
            }
            let data = (try? JSONEncoder().encode(layer)).map { String(decoding: $0, as: UTF8.self) }
            let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            emit(WorkerEvent(kind: .result, page: index, key: key, text: layer.text, millis: millis,
                             data: data, method: method))
        }
        return 0
    }

    /// Puts the worker in macOS's background state, which runs it at the lowest priority on the
    /// efficiency cores, until the runner sends SIGUSR1: a command now waits on one of its pages.
    /// Only a process can move itself into that state or out of it.
    public static func startInBackground() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler {
            setpriority(PRIO_DARWIN_PROCESS, 0, 0)
            Env.log("worker \(getpid()) left the background")
        }
        source.resume()
        promotion = source
        setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
    }

    nonisolated(unsafe) static var promotion: DispatchSourceSignal?

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
    /// named with the prefix "index-", such as "index-hang:3", happens while keys are read, and
    /// one with "sample-", such as "sample-crash:0", in the sample check.
    static func plantedFault(at index: Int, phase: String) {
        guard let fault = Env.testFault, fault.page == index, fault.kind.hasPrefix(phase) else { return }
        let kind = fault.kind.dropFirst(phase.count)
        if phase.isEmpty && (fault.kind.hasPrefix("index-") || fault.kind.hasPrefix("sample-")) { return }
        switch kind {
        case "hang":
            while true { sleep(60) }
        case "background-hang":
            // Hangs only in the background state, as a throttled worker can seem to.
            while getpriority(PRIO_DARWIN_PROCESS, 0) == 1 { sleep(1) }
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

    /// The key of a page in a file that the font check put at risk. Its result comes from the
    /// space repair, so it is cached apart from the same page read in a file that is not at
    /// risk: a cached page never depends on which file was read first.
    static func repaired(_ key: String) -> String {
        key == missing || key.hasPrefix("unreadable-") ? key : key + "+spaces"
    }

    /// The key of a page in a file whose text layer failed the sample check. OCR reads it, so
    /// its result is cached apart too.
    static func ocr(_ key: String) -> String {
        key == missing || key.hasPrefix("unreadable-") ? key : key + "+ocr"
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
