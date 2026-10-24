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
        /// The file's facts, from a facts job.
        case facts
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
    /// From an index job: the file's producer, such as "pdfTeX-1.40.25", and its title.
    var producer: String?
    var title: String?
    /// From a facts job.
    var facts: FileFacts?
}

/// The only kind of process that opens PDF content (DESIGNS.md → Principles → Safety).
/// A runner starts it, watches its time and memory, and writes what it reports to the cache.
public enum Worker {
    /// Reports the key of every page from `start` on, with the page's font check.
    public static func index(path: String, from start: Int) -> Int32 {
        watchParent()
        plantedFault(at: 0, phase: "open-")
        let url = URL(fileURLWithPath: path)
        guard let document = CGPDFDocument(url as CFURL) else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.classify(url: url)))
            return 0
        }
        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("") || document.unlockWithPassword(Env.password)
        }
        guard document.isUnlocked else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.lockedReason))
            return 0
        }
        let count = document.numberOfPages
        func info(_ key: String) -> String? {
            var value: CGPDFStringRef?
            guard let dictionary = document.info, CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
            return CGPDFStringCopyTextString(value) as String?
        }
        emit(WorkerEvent(kind: .opened, pageCount: count, producer: info("Producer"), title: info("Title")))
        var keyer = PageKeyer(catalog: document.catalog)
        // One walk of the page tree, where CGPDF would number its pages alike: asking CGPDF for
        // each page by its number took 17 s on a flat tree of 30,000 pages.
        let tree = PageTree(document)
        for index in max(start, 0)..<max(count, start) {
            emit(WorkerEvent(kind: .start, page: index))
            plantedFault(at: index, phase: "index-")
            if let dictionary = tree?.pages[index], let key = keyer.key(forDictionary: dictionary),
               let check = FontCheck(pageDictionary: dictionary) {
                emit(WorkerEvent(kind: .key, page: index, key: key, gaps: check.gaps, risky: check.risky))
                continue
            }
            guard let page = document.page(at: index + 1) else {
                emit(WorkerEvent(kind: .key, page: index, key: PageKeys.missing))
                continue
            }
            let check = FontCheck(page: page)
            emit(WorkerEvent(kind: .key, page: index, key: keyer.key(for: page), gaps: check.gaps, risky: check.risky))
        }
        return 0
    }

    /// Draws page `index`, counted from 0, or a region of it, into a PNG at `out`, and reports the
    /// image's size, or why it could not be drawn.
    public static func crop(path: String, page index: Int, bbox: String?, grid: Bool, out: String) -> Int32 {
        watchParent()
        plantedFault(at: index, phase: "crop-")
        let url = URL(fileURLWithPath: path)
        func fail(_ reason: String) -> Int32 {
            emit(WorkerEvent(kind: .result, page: index, reason: reason))
            return 0
        }
        // A region that does not parse fails: drawing the whole page in its place would pass off
        // the page as the region.
        let region = bbox.map(Box.parse) ?? Box(x: 0, y: 0, width: 1, height: 1)
        guard let region else { return fail("the region lies outside the page") }
        guard let document = PDFDocument(url: url) else { return fail(OpenFailure.classify(url: url)) }
        guard OpenFailure.unlock(document) else { return fail(OpenFailure.lockedReason) }
        guard let page = document.page(at: index) else { return fail("PDFKit could not read this page") }
        guard let image = Crop.render(page, region: region, grid: grid) else { return fail("the region is too small to draw") }
        let target = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard Crop.writePNG(image, to: target) else { return fail("the image could not be written") }
        emit(WorkerEvent(kind: .result, page: index, text: "\(image.width)x\(image.height)"))
        return 0
    }

    /// Reports the file's facts. The runner runs it in a worker of its own, so facts that take
    /// too long or crash the reader cost the facts alone, never a page.
    public static func facts(path: String) -> Int32 {
        watchParent()
        plantedFault(at: 0, phase: "facts-")
        let url = URL(fileURLWithPath: path)
        guard let document = CGPDFDocument(url as CFURL) else { return 0 }
        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("") || document.unlockWithPassword(Env.password)
        }
        guard document.isUnlocked else { return 0 }
        emit(WorkerEvent(kind: .facts, facts: FactReader.read(document, url: url)))
        return 0
    }

    /// Saves the file's attachments and scripts into `out` and reports the items written. The
    /// dump runs it in a worker so that a stream that decodes into too much memory costs the worker.
    public static func dump(path: String, out: String, attachments: Bool, scripts: Bool) -> Int32 {
        watchParent()
        do {
            let items = try Dump.payloads(path: path, folder: URL(fileURLWithPath: out), attachments: attachments, scripts: scripts)
            emit(WorkerEvent(kind: .result, text: String(decoding: try JSONEncoder().encode(items), as: UTF8.self)))
        } catch {
            emit(WorkerEvent(kind: .result, reason: "\((error as? DumpError)?.description ?? "\(error)")"))
        }
        return 0
    }

    /// Reports the file's sample check. The runner runs it in a worker of its own, beside the
    /// index, so a new file waits for the slower of the two, not for both.
    public static func sample(path: String) async -> Int32 {
        watchParent()
        plantedFault(at: 0, phase: "sample-")
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url), OpenFailure.unlock(document) else { return 0 }
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
        guard OpenFailure.unlock(document) else {
            emit(WorkerEvent(kind: .openFailed, reason: OpenFailure.lockedReason))
            return 0
        }
        var keyer = PageKeyer(catalog: document.documentRef?.catalog)
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
            var layer: PageText
            var method: String
            if readAllByOCR || OCR.needed(text: page.string ?? "", images: check.images) {
                let textLayer = TextLayer.read(page, visibility: Visibility(page: page))
                if var read = await OCR.pageText(page, check: true), !OCR.lostText(ocr: read, layer: textLayer) {
                    // The replaced layer, which `--show raw` shows, as a reader would see it: what it
                    // hides stays out.
                    let replaced = textLayer.blocks.map(\.visibleText).filter { !$0.isEmpty }.joined(separator: "\n")
                    if !replaced.isEmpty { read.replacedText = replaced }
                    // Its images and drawings stay: a scan's own image is none of them.
                    read.pictures = textLayer.pictures
                    layer = read
                    method = "ocr"
                } else if textLayer.words > 0 {
                    // OCR could not read the page, or read far less than its text layer holds:
                    // the layer serves, with its score, so the quality check flags it.
                    var served = textLayer
                    served.layerScore = OCR.layerScore(page.string ?? "")
                    layer = served
                    method = "pdfkit+ocr-failed"
                } else {
                    emit(WorkerEvent(kind: .result, page: index, key: key,
                                     reason: "Apple OCR could not read this page", millis: 0))
                    continue
                }
            } else {
                (layer, method) = await readTextLayer(page, atRisk: repairSpaces || check.pageAtRisk)
                // A page whose drawn text PDFKit mostly left out of the page's text, as one set in
                // Type 3 fonts with no text map, is read by OCR, as a page with no usable text
                // layer is; the layer stays for `--show raw`. Only where OCR reads clearly more than the
                // layer holds: where it does not, the layer was whole and its places a mistake, as
                // OCR read a page of Arabic letters worse. Otherwise the layer serves, flagged.
                if let share = layer.unreadShare, share >= OCR.unreadShare, var read = await OCR.pageText(page, check: true),
                   OCR.readsMore(ocr: read, layer: layer) {
                    let replaced = layer.blocks.map(\.visibleText).filter { !$0.isEmpty }.joined(separator: "\n")
                    if !replaced.isEmpty { read.replacedText = replaced }
                    read.pictures = layer.pictures
                    layer = read
                    method = "ocr"
                }
            }
            if let label = page.label, !label.isEmpty, label != String(index + 1) { layer.label = label }
            if check.damaged { layer.damaged = true }
            // Words still run together, which OCR could not break either, get a second reading
            // split into common words, or a span that tells the agent to look at the image.
            if layer.runTogether > 0 {
                let existing = layer.unsure ?? []
                let splits = SpaceRepair.splitSpans(layer, besides: existing)
                if !splits.isEmpty { layer.unsure = (existing + splits).sorted { ($0.block, $0.offset) < ($1.block, $1.offset) } }
            }
            let data = (try? JSONEncoder().encode(layer)).map { String(decoding: $0, as: UTF8.self) }
            let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            emit(WorkerEvent(kind: .result, page: index, key: key, text: layer.text, millis: millis,
                             data: data, method: method))
        }
        return 0
    }

    /// Reads a page from its text layer. A page at risk of lost spaces, or one whose words turn
    /// out to run together, gets OCR's word breaks, and the words that OCR breaks with less
    /// certainty become unsure spans for the agent to pick from. When OCR cannot read the page,
    /// the layer serves as it is, and its run-together words get their spans from the word
    /// lists alone (see `SpaceRepair.splitSpans`).
    static func readTextLayer(_ page: PDFPage, atRisk: Bool) async -> (PageText, String) {
        let glyphs = Glyphs(page, (page.string ?? "") as NSString)
        // Drawn once, for every reading of the page: the text a reader cannot see.
        let visibility = Visibility(page: page)
        let plain = atRisk ? nil : TextLayer.read(page, glyphs: glyphs, visibility: visibility)
        if let plain, plain.runTogether == 0 { return (plain, "pdfkit") }
        guard let breaks = await SpaceRepair.breaks(page) else {
            var served = plain ?? TextLayer.read(page, glyphs: glyphs, visibility: visibility)
            // A page whose fonts hide spaces loses them all over, so the page is in doubt.
            if atRisk { served.spacesLost = true }
            return (served, "pdfkit+ocr-failed")
        }
        var repaired = TextLayer.read(page, spacesBefore: breaks.spaces, glyphs: glyphs, visibility: visibility)
        if !breaks.unsure.isEmpty {
            let relaxed = TextLayer.read(page, spacesBefore: breaks.spaces.union(breaks.unsure), glyphs: glyphs,
                                         visibility: visibility)
            let spans = SpaceRepair.unsureSpans(strict: repaired, relaxed: relaxed)
            if !spans.isEmpty { repaired.unsure = spans }
        }
        return (repaired, "pdfkit+ocr-spaces")
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
    /// one with "sample-", such as "sample-crash:0", in the sample check, and "open-hang:0" or
    /// "open-slow:0", a 4 s wait, while the index opens the file.
    static func plantedFault(at index: Int, phase: String) {
        guard let fault = Env.testFault, fault.page == index, fault.kind.hasPrefix(phase) else { return }
        let kind = fault.kind.dropFirst(phase.count)
        if phase.isEmpty && ["index-", "sample-", "facts-", "crop-", "open-"].contains(where: fault.kind.hasPrefix) { return }
        switch kind {
        case "hang":
            while true { sleep(60) }
        case "slow":
            // Slower than a page may take, quicker than the open limit a test sets.
            sleep(4)
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
        case "crash-once":
            // Crashes the first worker of a runner only, as a busy machine might stop one.
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-fault-\(getppid())")
            if !FileManager.default.fileExists(atPath: marker.path) {
                FileManager.default.createFile(atPath: marker.path, contents: nil)
                abort()
            }
            try? FileManager.default.removeItem(at: marker)
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
public enum OpenFailure {
    static let notPDF = "not a PDF"
    public static let locked = "locked by a password"
    static let damaged = "damaged: PDFKit could not open it"
    /// A file that took too long to open: cached for the command that tried, and tried again by
    /// the next one.
    static let slow = "slow to open"

    /// Why a locked file stays locked: no password was given, or the one given does not open it.
    static var lockedReason: String {
        Env.password.isEmpty ? locked : locked + ", and the password given does not open it"
    }

    /// Opens a locked file with an empty password, as a file locked only against changes
    /// opens, or with the password the agent gave. True when the file is open.
    static func unlock(_ document: PDFDocument) -> Bool {
        if document.isLocked { _ = document.unlock(withPassword: "") || document.unlock(withPassword: Env.password) }
        return !document.isLocked
    }

    static func classify(url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return damaged }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1024)
        return head.range(of: Data("%PDF-".utf8)) == nil ? notPDF : damaged
    }
}
