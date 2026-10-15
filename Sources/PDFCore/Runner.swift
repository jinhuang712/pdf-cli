import Darwin
import Foundation

/// Parses one file in the background, then exits (DESIGNS.md → Decision: a worker process
/// per job over a background service).
///
/// A command starts a runner and returns as soon as the pages it needs are cached. The
/// runner never opens PDF content itself. It starts workers, stops any worker that takes too
/// long or holds too much memory, and writes what the workers report to the cache, so a
/// worker that hangs or crashes costs one page, not the document.
///
/// A result is saved only while the file still has the stat it had when it was indexed.
/// Results are keyed by page content and never replaced, so a result read from a changed
/// file would stay wrong for every copy of the document.
public final class Runner: @unchecked Sendable {
    let path: String
    let store: Store
    static let batchSize = 8

    private let mutex = NSLock()
    private var inbox: [(worker: Int, event: WorkerEvent?)] = []
    private let wake = DispatchSemaphore(value: 0)
    private var heldLocks: [String] = []
    private var stopped = false
    private var lostLock = false
    private var nextWorkerID = 0

    public init(path: String, store: Store) {
        self.path = path
        self.store = store
    }

    public func run() -> Int32 {
        let pathLock = "path:" + path
        guard (try? store.acquireLock(pathLock)) == true else { return 0 }
        hold(pathLock)
        startHeartbeat()
        defer {
            mutex.locked { stopped = true }
            for key in mutex.locked({ heldLocks }) { try? store.releaseLock(key) }
        }
        for _ in 0..<3 {
            guard case .document(let docID, let stat) = index() else { return 0 }
            let docLock = "doc:" + docID
            // Another runner already parses the same document from another copy of the file.
            guard (try? store.acquireLock(docLock)) == true else { return 0 }
            hold(docLock)
            switch parse(docID: docID, stat: stat) {
            case .done:
                try? store.clearRequests(docID: docID)
                return 0
            case .aborted:
                return 0
            case .fileChanged:
                // Forget the lock before releasing it, so the heartbeat never mistakes the
                // release for a takeover.
                mutex.locked { heldLocks.removeAll { $0 == docLock } }
                try? store.releaseLock(docLock)
            }
        }
        return 0
    }

    // MARK: Index

    enum IndexOutcome {
        /// The file's document, and the stat its keys belong to.
        case document(id: String, stat: FileStat)
        /// The file cannot be read. Its failure is cached.
        case failed
        /// The file is gone, or the machine could not run a worker. Nothing is cached, so the
        /// next command tries again.
        case unavailable
    }

    /// Finds the document for the file, reading every page's key if the file is new or
    /// changed.
    func index() -> IndexOutcome {
        for _ in 0..<3 {
            guard let cachedStat = FileStat(path: path) else { return .unavailable }
            if let entry = try? store.entry(path: path, stat: cachedStat) {
                if case .document(let id) = entry { return .document(id: id, stat: cachedStat) }
                return .failed
            }
            downloadIfInCloud()
            guard let before = FileStat(path: path) else { return .unavailable }
            var pageCount: Int?
            var keys: [Int: String] = [:]
            var checks: [Int: FontCheck] = [:]
            var agreement: Double?
            var failedPages: [Int: String] = [:]
            var fileFailure: String?
            var retried: Set<Int> = []
            var start = 0
            var stops = 0
            // The sample check runs in a worker of its own, beside the index.
            let sampler = startWorker(["sample", path], pages: [])
            let handle = { (_: Supervised, event: WorkerEvent) in
                switch event.kind {
                case .opened: pageCount = event.pageCount
                case .openFailed: fileFailure = event.reason ?? OpenFailure.damaged
                case .key:
                    guard let page = event.page, let key = event.key else { break }
                    keys[page] = key
                    checks[page] = FontCheck(gaps: event.gaps ?? 0, risky: event.risky ?? 0)
                case .sample: agreement = event.agreement
                default: break
                }
            }
            while fileFailure == nil {
                guard let worker = startWorker(["index", path, "--from", String(start)], pages: []) else {
                    if let sampler { stop(sampler, reason: "the index could not start", kind: .runner) }
                    return .unavailable
                }
                while !worker.finished { step([worker] + [sampler].compactMap { $0 }, handle: handle) }
                if fileFailure != nil || worker.endedCleanly { break }
                guard let count = pageCount else {
                    stops += 1
                    if stops > 2 { fileFailure = "damaged: the reader stopped while opening it (\(worker.endReason))" }
                    continue
                }
                if let page = worker.blamedPage {
                    // A crash or a memory limit may come from the machine or from memory built
                    // up on earlier pages, so the page gets a fresh worker once. A hang fails
                    // at once: it would hang again.
                    if worker.stopKind == .pageTime || retried.contains(page) {
                        failedPages[page] = worker.endReason
                        start = page + 1
                    } else {
                        retried.insert(page)
                        start = page
                    }
                } else {
                    stops += 1
                    if stops > 2 {
                        fileFailure = "damaged: the reader kept stopping (\(worker.endReason))"
                        break
                    }
                    start = max(start, (keys.keys.max() ?? -1) + 1)
                }
                if start >= count { break }
            }
            var unchecked = false
            if let sampler {
                // A file that cannot be read needs no verdict on its text layer.
                if fileFailure != nil { stop(sampler, reason: "the file cannot be read", kind: .runner) }
                while !sampler.finished { step([sampler], handle: handle) }
                // A sample check that crashed or ran out of time, as on a busy machine, gets a
                // second try. If that fails too, the text layer stays unchecked, and OCR reads
                // every page: an unverified layer is not trusted.
                if fileFailure == nil, agreement == nil, !sampler.endedCleanly {
                    if let again = startWorker(["sample", path], pages: []) {
                        while !again.finished { step([again], handle: handle) }
                        unchecked = agreement == nil && !again.endedCleanly
                    } else {
                        unchecked = true
                    }
                }
            }
            guard FileStat(path: path) == before else { continue }
            if let fileFailure {
                try? store.saveFailure(path: path, stat: before, reason: fileFailure)
                return .failed
            }
            guard let count = pageCount else { return .unavailable }
            if !failedPages.isEmpty {
                let digest = fileDigest()
                for (page, reason) in failedPages {
                    let key = PageKeys.unreadable(fileDigest: digest, page: page)
                    keys[page] = key
                    try? store.saveResult(key: key, .failed(reason))
                }
            }
            // A text layer that fails the sample check is not read at all, so its fonts no longer
            // matter: OCR reads every page.
            let needsOCR = unchecked || (agreement.map { $0 < OCR.sampleThreshold } ?? false)
            let atRisk = !needsOCR && FontCheck.atRisk(gaps: checks.values.reduce(0) { $0 + $1.gaps },
                                                       risky: checks.values.reduce(0) { $0 + $1.risky })
            let ordered = (0..<count).map { page -> String in
                let key = keys[page] ?? PageKeys.missing
                return needsOCR ? PageKeys.ocr(key) : atRisk ? PageKeys.repaired(key) : key
            }
            guard let id = try? store.saveIndex(path: path, stat: before, pageKeys: ordered, spacesAtRisk: atRisk,
                                                needsOCR: needsOCR) else {
                return .unavailable
            }
            return .document(id: id, stat: before)
        }
        return .unavailable
    }

    /// Reading a file kept in iCloud makes macOS download it first. The runner reads the
    /// bytes, without parsing them, so a slow download does not count against a worker's
    /// time limit.
    func downloadIfInCloud() {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        while !handle.readData(ofLength: 1 << 20).isEmpty {}
    }

    func fileDigest() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return "unhashable"
        }
        return Hashing.hex(of: data)
    }

    // MARK: Parse

    enum ParseOutcome { case done, fileChanged, aborted }

    /// Parses every page that has no cached result yet. Pages that a command asked for go
    /// first. Pages that share a key, such as blank pages, are parsed once.
    func parse(docID: String, stat: FileStat) -> ParseOutcome {
        guard let keys = try? store.pageKeys(docID: docID), !keys.isEmpty else { return .done }
        let cached = (try? store.results(keys: keys)) ?? [:]
        var firstIndex: [String: Int] = [:]
        var pending: [Int] = []
        for (index, key) in keys.enumerated() where firstIndex[key] == nil {
            firstIndex[key] = index
            if cached[key] == nil { pending.append(index) }
        }
        var alone: [Int] = []
        var triedAlone: Set<Int> = []
        var attempts: [Int: Int] = [:]
        var workers: [Supervised] = []
        var changed = false
        var failedSpawns = 0
        let capacity = max(1, Env.workerCount)
        let readAllByOCR = (try? store.needsOCR(docID: docID)) ?? false
        let repair = !readAllByOCR && ((try? store.spacesAtRisk(docID: docID)) ?? false)
        let parseArguments = readAllByOCR ? ["--read-all-by-ocr"] : repair ? ["--repair-spaces"] : []
        // A page through OCR takes about 0.7 s, so batches shrink once pages turn out slow, as
        // in a scan: a page a command asks for waits for one batch at most.
        var slow = readAllByOCR || repair
        var batchSize: Int { slow ? 2 : Runner.batchSize }

        func unchanged() -> Bool { FileStat(path: path) == stat }

        func save(_ page: Int, _ result: PageResult) {
            guard !changed else { return }
            guard unchanged() else {
                changed = true
                return
            }
            try? store.saveResult(key: keys[page], result)
        }

        /// A crash may come from the machine, not the page, so a page gets a second try.
        func retryOrFail(_ page: Int, _ reason: String) {
            attempts[page, default: 0] += 1
            if attempts[page]! <= 1 { pending.insert(page, at: 0) } else { save(page, .failed(reason)) }
        }

        while !changed && (!pending.isEmpty || !alone.isEmpty || !workers.isEmpty) {
            if mutex.locked({ lostLock }) {
                // Another runner took over this file. It finishes the work.
                workers.forEach { stop($0, reason: "another runner took over", kind: .runner) }
                while workers.contains(where: { !$0.finished }) { step(workers) { _, _ in } }
                return .aborted
            }

            while workers.count < capacity, !(pending.isEmpty && alone.isEmpty) {
                let batch = alone.isEmpty
                    ? nextBatch(&pending, docID: docID, keys: keys, firstIndex: firstIndex, size: batchSize)
                    : [alone.removeFirst()]
                let list = batch.map(String.init).joined(separator: ",")
                guard let worker = startWorker(["parse", path, "--pages", list] + parseArguments, pages: batch) else {
                    // A full process table or a binary being replaced passes. Nothing is cached.
                    if batch.count == 1 && triedAlone.contains(batch[0]) {
                        alone.insert(batch[0], at: 0)
                    } else {
                        pending.insert(contentsOf: batch, at: 0)
                    }
                    failedSpawns += 1
                    break
                }
                failedSpawns = 0
                workers.append(worker)
            }
            if workers.isEmpty {
                if failedSpawns >= 3 { return .aborted }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            step(workers) { worker, event in
                switch event.kind {
                case .openFailed:
                    worker.openFailure = event.reason ?? OpenFailure.damaged
                case .result:
                    guard let page = event.page, keys.indices.contains(page) else { return }
                    if (event.millis ?? 0) > 300 { slow = true }
                    if let reason = event.reason {
                        save(page, .failed(reason))
                    } else {
                        save(page, PageResult(status: .ok, method: event.method ?? "pdfkit", text: event.text ?? "",
                                              reason: "", parseMillis: event.millis ?? 0, data: event.data ?? ""))
                    }
                default:
                    break
                }
            }

            for worker in workers where worker.finished && !changed {
                var unreported = worker.pages.filter { !worker.reported.contains($0) }
                if let failure = worker.openFailure {
                    // The file opened when it was indexed, so a failure now usually means it
                    // moved or changed. `save` checks that before it caches anything.
                    unreported.forEach { save($0, .failed(failure)) }
                    continue
                }
                if worker.endedCleanly {
                    unreported.forEach { retryOrFail($0, "the reader skipped this page") }
                    continue
                }
                let reason = worker.endReason
                if let page = worker.blamedPage, unreported.contains(page) {
                    unreported.removeAll { $0 == page }
                    switch worker.stopKind {
                    case .pageTime:
                        save(page, .failed(reason))
                    case .memory:
                        // Memory builds up across a batch, so the page that crossed the limit
                        // may not be the cause. It gets a worker of its own once.
                        if triedAlone.insert(page).inserted { alone.append(page) } else { save(page, .failed(reason)) }
                    default:
                        retryOrFail(page, reason)
                    }
                    pending.insert(contentsOf: unreported, at: 0)
                } else {
                    // The worker stopped while opening the file or between pages, so no page
                    // is to blame. Each page goes back in line, once.
                    let suffix = worker.sawEvent ? "" : " while opening the file"
                    unreported.reversed().forEach { retryOrFail($0, reason + suffix) }
                }
            }
            workers.removeAll { $0.finished }
        }

        if changed {
            workers.forEach { stop($0, reason: "the file changed", kind: .runner) }
            while workers.contains(where: { !$0.finished }) { step(workers) { _, _ in } }
            return .fileChanged
        }
        return .done
    }

    /// The next pages for a worker: pages a command asked for, else the next pages in order.
    func nextBatch(_ pending: inout [Int], docID: String, keys: [String], firstIndex: [String: Int],
                   size: Int = Runner.batchSize) -> [Int] {
        let requested = ((try? store.requestedPages(docID: docID)) ?? [])
            .compactMap { keys.indices.contains($0) ? firstIndex[keys[$0]] : nil }
        let waiting = Set(pending)
        var batch: [Int] = []
        for page in requested where waiting.contains(page) && !batch.contains(page) && batch.count < size {
            batch.append(page)
        }
        if batch.isEmpty { batch = Array(pending.prefix(size)) }
        let taken = Set(batch)
        pending.removeAll { taken.contains($0) }
        return batch
    }

    // MARK: Workers

    enum StopKind { case pageTime, silence, memory, runner }

    final class Supervised {
        let id: Int
        let pid: pid_t
        let pages: [Int]
        var lastEventAt = Date()
        var sawEvent = false
        var current: Int?
        var currentStartedAt: Date?
        var reported: Set<Int> = []
        var openFailure: String?
        var stopReason: String?
        var stopKind: StopKind?
        /// The page in progress when the runner stopped the worker. The worker may report it
        /// and start the next page before the kill lands, so `current` alone could blame the
        /// wrong page.
        var stoppedPage: Int?
        var outputEnded = false
        var exitStatus: Int32?

        init(id: Int, pid: pid_t, pages: [Int]) {
            self.id = id
            self.pid = pid
            self.pages = pages
        }

        var finished: Bool { outputEnded && exitStatus != nil }
        var endedCleanly: Bool { stopReason == nil && exitStatus == 0 }
        /// The page to blame for how the worker ended, if any.
        var blamedPage: Int? { stopKind == nil ? current : stoppedPage }
        var endReason: String {
            if let stopReason { return stopReason }
            guard let exitStatus else { return "the reader is still running" }
            return "the reader crashed: \(Processes.describe(status: exitStatus))"
        }
    }

    func startWorker(_ arguments: [String], pages: [Int]) -> Supervised? {
        guard let (pid, output) = try? Processes.spawn(Env.executablePath, ["__worker"] + arguments,
                                                        detached: false, captureOutput: true),
              let output else { return nil }
        Env.log("runner \(getpid()) started worker \(pid): \(arguments.joined(separator: " "))")
        let id = mutex.locked { () -> Int in
            nextWorkerID += 1
            return nextWorkerID
        }
        let reader = LineReader(descriptor: output, onLine: { [weak self] line in
            // A line that does not decode is dropped: a worker reads hostile files.
            guard let event = try? JSONDecoder().decode(WorkerEvent.self, from: line) else { return }
            self?.post(id, event)
        }, onEnd: { [weak self] in
            self?.post(id, nil)
        })
        reader.start()
        return Supervised(id: id, pid: pid, pages: pages)
    }

    /// Runs until every worker in `workers` has finished.
    func run(_ workers: [Supervised], handle: (Supervised, WorkerEvent) -> Void) {
        while workers.contains(where: { !$0.finished }) { step(workers, handle: handle) }
    }

    /// Waits briefly for news, hands each event to `handle`, enforces the limits and collects
    /// workers that exited.
    func step(_ workers: [Supervised], handle: (Supervised, WorkerEvent) -> Void) {
        _ = wake.wait(timeout: .now() + .milliseconds(20))
        let events = mutex.locked { () -> [(worker: Int, event: WorkerEvent?)] in
            defer { inbox.removeAll() }
            return inbox
        }
        for (id, event) in events {
            guard let worker = workers.first(where: { $0.id == id }) else { continue }
            guard let event else {
                worker.outputEnded = true
                continue
            }
            worker.lastEventAt = Date()
            worker.sawEvent = true
            switch event.kind {
            case .start:
                worker.current = event.page
                worker.currentStartedAt = Date()
            case .key, .result:
                if let page = event.page {
                    worker.reported.insert(page)
                    if worker.current == page {
                        worker.current = nil
                        worker.currentStartedAt = nil
                    }
                }
            default:
                break
            }
            handle(worker, event)
        }
        let limit = Env.pageTimeLimit
        let now = Date()
        for worker in workers where worker.exitStatus == nil && worker.stopReason == nil {
            if let started = worker.currentStartedAt, now.timeIntervalSince(started) > limit {
                stop(worker, reason: "time limit: the page took more than \(Int(limit)) s", kind: .pageTime)
            } else if worker.current == nil, now.timeIntervalSince(worker.lastEventAt) > limit {
                stop(worker, reason: "time limit: the reader was silent for more than \(Int(limit)) s", kind: .silence)
            } else if let footprint = Processes.footprint(of: worker.pid), footprint > Env.memoryLimitBytes {
                stop(worker, reason: "memory limit: the reader used more than \(Env.memoryLimitBytes >> 20) MB",
                     kind: .memory)
            }
        }
        for worker in workers where worker.exitStatus == nil {
            worker.exitStatus = Processes.reap(worker.pid)
        }
    }

    func stop(_ worker: Supervised, reason: String, kind: StopKind) {
        guard worker.exitStatus == nil, worker.stopReason == nil else { return }
        worker.stopReason = reason
        worker.stopKind = kind
        worker.stoppedPage = worker.current
        kill(worker.pid, SIGKILL)
    }

    func post(_ worker: Int, _ event: WorkerEvent?) {
        mutex.locked { inbox.append((worker, event)) }
        wake.signal()
    }

    // MARK: Locks

    func hold(_ key: String) {
        mutex.locked { heldLocks.append(key) }
    }

    /// Keeps the runner's locks fresh, so commands know it is still alive. If the machine
    /// slept long enough for another runner to take a lock over, this runner learns it here
    /// and stops.
    func startHeartbeat() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                let (done, keys) = self.mutex.locked { (self.stopped, self.heldLocks) }
                if done { return }
                guard let held = try? self.store.heartbeat(keys) else { continue }
                self.mutex.locked {
                    if self.heldLocks.contains(where: { keys.contains($0) && !held.contains($0) }) {
                        self.lostLock = true
                    }
                }
            }
        }
        thread.start()
    }
}
