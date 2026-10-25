import Foundation

extension NSLock {
    /// `NSLock.withLock` needs macOS 14, and the tool supports macOS 11.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

public enum ReadError: Error, CustomStringConvertible {
    case notFound(String)
    case pageOutOfRange(page: Int, pageCount: Int)
    case runnerFailed
    case reparseBusy

    public var description: String {
        switch self {
        case .notFound(let path): return "no such file: \(path)"
        case .pageOutOfRange(let page, let count): return "page \(page + 1) is out of range: the file has \(count) pages"
        case .runnerFailed: return "the parser stopped before it finished; run the command again"
        case .reparseBusy: return "another reparse of this file is still running; run the command again when it has ended"
        }
    }
}

/// What a command gets back for a file.
public enum ReadOutcome: Sendable {
    /// The file could not be opened at all, with the reason.
    case fileFailed(reason: String)
    /// The requested pages, in the order asked, counted from 0.
    case pages(docID: String, pageCount: Int, results: [(page: Int, result: PageResult)])
}

/// What `pdf reparse` did to a file (ROADMAP.md → M2.10).
public struct Reparsed: Sendable {
    public var docID: String
    public var pageCount: Int
    /// The pages read again, counted from 0, in order.
    public var pages: [Int]
    /// Each page's result before and after, by page; a page with no cached result before is absent
    /// from `before`.
    public var before: [Int: PageResult]
    public var after: [Int: PageResult]
    /// Pages whose new reading failed, so that their old result stayed, with the reason.
    public var kept: [Int: String]
    /// The cache had never seen the file.
    public var neverRead: Bool
    /// The file changed since it was read, or while it was read again: this is its current version.
    public var changedSinceRead: Bool
    /// The cache held this version of the file, indexed by an older `pdf`, which indexed it again.
    public var toolUpdated: Bool
}

public enum ReparseOutcome: Sendable {
    case fileFailed(reason: String)
    case done(Reparsed)
}

/// The command side of the cache. It never opens PDF content: it reads the cache, and starts
/// a runner when pages are missing (DESIGNS.md → Principles → Safety).
public final class Reader: Sendable {
    let store: Store
    let library: Library?

    /// With a `library`, every file read joins the library list (FEATURES.md → F1).
    public init(store: Store, library: Library? = nil) {
        self.store = store
        self.library = library
    }

    /// Why a dry run found nothing for a file or page.
    public enum Uncached: Sendable {
        /// The cache has no entry for the file.
        case neverRead
        /// The cache knows the path, but not this version of the file or of the index checks.
        case changed
        /// The file is indexed, the page not parsed yet.
        case pageMissing
    }

    public enum Peek: Sendable {
        case found(ReadOutcome)
        case uncached(Uncached)
    }

    /// What the cache already holds for these pages, counted from 0, and nothing else: no parse,
    /// no runner, no library entry, no write. A dry run reads this way (ROADMAP.md → M2.18).
    public func peek(path rawPath: String, pages wanted: [Int]) throws -> Peek {
        let path = Reader.resolve(rawPath)
        guard let stat = FileStat(path: path) else { throw ReadError.notFound(rawPath) }
        switch try store.entry(path: path, stat: stat) {
        case .failed(let reason)?:
            return .found(.fileFailed(reason: reason))
        case .document(let id)?:
            let keys = try store.pageKeys(docID: id)
            if let bad = wanted.first(where: { !keys.indices.contains($0) }) {
                throw ReadError.pageOutOfRange(page: bad, pageCount: keys.count)
            }
            let results = try store.results(keys: wanted.map { keys[$0] })
            guard wanted.allSatisfy({ results[keys[$0]] != nil }) else { return .uncached(.pageMissing) }
            return .found(.pages(docID: id, pageCount: keys.count, results: wanted.map { ($0, results[keys[$0]]!) }))
        case nil:
            return .uncached(try store.knows(path: path) ? .changed : .neverRead)
        }
    }

    /// The path the cache knows a file by: absolute, with symbolic links resolved.
    ///
    /// macOS's three folder aliases, `/tmp`, `/var` and `/etc`, are always written without
    /// `/private`, whether or not the file exists: Foundation strips it only from a path that
    /// exists, so `/private/tmp/x.pdf` and `/tmp/x.pdf` named one file while it was there and two
    /// once it was gone.
    public static func resolve(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return systemAliasless(resolved)
    }

    /// `/private/tmp/x` as `/tmp/x`, and likewise for `/var` and `/etc`; any other path as it is.
    public static func systemAliasless(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Returns the pages, counted from 0, once each one is cached. Nil means every page.
    /// `workers` and `password` come from `pdf add`, for the runner this read starts.
    public func read(path rawPath: String, pages wanted: [Int]?, workers: Int? = nil,
                     password: String? = nil) throws -> ReadOutcome {
        let path = Reader.resolve(rawPath)
        var requested = false
        var lastSpawn: Date?
        var spawns = 0
        var pause = 0.005
        var runner: pid_t?
        defer { if let runner { _ = Processes.reap(runner) } }

        while true {
            guard let stat = FileStat(path: path) else { throw ReadError.notFound(rawPath) }
            var locks = ["path:" + path]
            switch try store.entry(path: path, stat: stat) {
            case .failed(let reason)? where password != nil && reason.hasPrefix(OpenFailure.locked) && spawns == 0:
                // A password may open a file the cache knows as locked: it is indexed again, once
                // no runner without the password still works on it. The verdict of the runner
                // this read starts, with the password, stands.
                if try store.isLockAlive("path:" + path) {
                    Thread.sleep(forTimeInterval: 0.05)
                } else {
                    try store.forgetEntry(path: path)
                }
                continue
            case .failed(let reason)?:
                return .fileFailed(reason: reason)
            case .document(let id)?:
                let keys = try store.pageKeys(docID: id)
                let pages = wanted ?? Array(keys.indices)
                if let bad = pages.first(where: { !keys.indices.contains($0) }) {
                    throw ReadError.pageOutOfRange(page: bad, pageCount: keys.count)
                }
                let results = try store.results(keys: pages.map { keys[$0] })
                let missing = pages.filter { results[keys[$0]] == nil }
                if missing.isEmpty {
                    if let library {
                        let title = try store.documentInfo(docID: id)?.title ?? ""
                        try library.register(path: path, docID: id, title: title, pageCount: keys.count)
                    }
                    return .pages(docID: id, pageCount: keys.count,
                                  results: pages.map { ($0, results[keys[$0]]!) })
                }
                if !requested {
                    try store.request(docID: id, pages: missing)
                    requested = true
                }
                locks.append("doc:" + id)
            case nil:
                break
            }

            // Start a runner when none is alive. A new runner gets two seconds to take its
            // lock before the command decides it died.
            let alive = try locks.contains { try store.isLockAlive($0) }
            if !alive, lastSpawn.map({ Date().timeIntervalSince($0) > 2 }) ?? true {
                guard spawns < 3 else { throw ReadError.runnerFailed }
                if let runner { _ = Processes.reap(runner) }
                // The runner learns the pages this command waits on at once: a request saved
                // only after the index could reach it after its first batch had started.
                let pages = wanted.map { $0.map(String.init).joined(separator: ",") } ?? "all"
                // Attached with "=", so a list that starts with a negative page is not read as a flag.
                // An empty list, as `pdf crop` asks for when it needs only the index, is left out:
                // the parser reads "--pages=" as a flag missing its value.
                runner = try Processes.spawn(Env.executablePath,
                                             ["__runner", path] + (pages.isEmpty ? [] : ["--pages=" + pages])
                                                + (workers.map { ["--workers=\($0)"] } ?? []),
                                             detached: true, captureOutput: false,
                                             environment: password.map { [Env.passwordVariable: $0] } ?? [:]).pid
                spawns += 1
                lastSpawn = Date()
            }
            if let current = runner, Processes.reap(current) != nil { runner = nil }
            Thread.sleep(forTimeInterval: pause)
            pause = min(pause * 1.5, 0.05)
        }
    }

    // MARK: Reparse

    /// Reads pages again and replaces their cached results (nil: every page; `ocr`: with Apple's
    /// OCR instead of the usual method). The file is indexed first if the cache has no current entry
    /// for it. A file that failed to open is tried again. The reading runs in a runner of its own
    /// that stops with this command, and leaves nothing behind that parses other pages.
    public func reparse(
        path rawPath: String, pages wanted: [Int]?, ocr: Bool, workers: Int? = nil,
        password: String? = nil
    ) throws -> ReparseOutcome {
        let path = Reader.resolve(rawPath)
        guard let first = FileStat(path: path) else { throw ReadError.notFound(rawPath) }
        let before = try store.entry(path: path, stat: first)
        let known = try store.knows(path: path)
        let neverRead = before == nil && !known
        let sameVersion = before == nil && known ? try store.hasEntry(path: path, stat: first) : false
        var changedSinceRead = before == nil && known && !sameVersion
        let toolUpdated = sameVersion
        var lastDocument: String?
        var busyWaits = 0
        var retriedFailure = false
        var failures = 0
        while failures < 3 {
            guard let stat = FileStat(path: path) else { throw ReadError.notFound(rawPath) }
            let docID: String
            switch try store.entry(path: path, stat: stat) {
            case .failed(let reason)?:
                // A failure the cache holds is tried again once, as the command asks to read the file
                // again; a locked file without its password cannot be.
                if retriedFailure || (reason.hasPrefix(OpenFailure.locked) && password == nil) {
                    return .fileFailed(reason: reason)
                }
                retriedFailure = true
                if try store.isLockAlive("path:" + path) { Thread.sleep(forTimeInterval: 0.05) } else { try store.forgetEntry(path: path) }
                continue
            case nil:
                try index(path: path, password: password)
                if case .failed(let reason)? = try FileStat(path: path).flatMap({ try store.entry(path: path, stat: $0) }) {
                    return .fileFailed(reason: reason)
                }
                continue
            case .document(let id)?:
                docID = id
            }
            // The file changed while it was read again: another document, and the first is gone.
            if let lastDocument, lastDocument != docID { changedSinceRead = true }
            lastDocument = docID
            let keys = try store.pageKeys(docID: docID)
            let pages = Array(Set(wanted ?? Array(keys.indices))).sorted()
            if let bad = pages.first(where: { !keys.indices.contains($0) }) {
                throw ReadError.pageOutOfRange(page: bad, pageCount: keys.count)
            }
            let old = try store.results(keys: pages.map { keys[$0] })
            let run = try runReparse(path: path, pages: wanted == nil ? nil : pages, ocr: ocr, workers: workers, password: password)
            switch run.status {
            case 0:
                let new = try store.results(keys: pages.map { keys[$0] })
                if let library {
                    try library.register(
                        path: path, docID: docID, title: try store.documentInfo(docID: docID)?.title ?? "",
                        pageCount: keys.count)
                }
                var kept: [Int: String] = [:]
                for line in run.output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3, parts[0] == "kept", let page = Int(parts[1]) { kept[page] = String(parts[2]) }
                }
                return .done(
                    Reparsed(
                        docID: docID, pageCount: keys.count, pages: pages,
                        before: Dictionary(uniqueKeysWithValues: pages.compactMap { page in old[keys[page]].map { (page, $0) } }),
                        after: Dictionary(uniqueKeysWithValues: pages.compactMap { page in new[keys[page]].map { (page, $0) } }),
                        kept: kept, neverRead: neverRead, changedSinceRead: changedSinceRead, toolUpdated: toolUpdated))
            case Runner.exitLocked:
                // The file's results stay as they were: a password that does not open it is no verdict on it.
                return .fileFailed(reason: OpenFailure.lockedReason)
            case Runner.exitBusy:
                // Another reparse of this file runs: it goes first, for up to ten minutes and five turns.
                busyWaits += 1
                guard busyWaits <= 5 else { throw ReadError.reparseBusy }
                let limit = Date().addingTimeInterval(600)
                while try store.isLockAlive("reparse:" + path) {
                    guard Date() < limit else { throw ReadError.reparseBusy }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            default:
                // The file changed, or the runner stopped: the entry is looked at again.
                failures += 1
            }
        }
        throw ReadError.runnerFailed
    }

    /// Starts a runner that indexes the file and stops, and waits for it. Another runner that holds
    /// the file's lock is waited for instead, until the file has an entry.
    private func index(path: String, password: String?) throws {
        var spawns = 0
        while true {
            guard let stat = FileStat(path: path) else { throw ReadError.notFound(path) }
            if try store.entry(path: path, stat: stat) != nil { return }
            if try store.isLockAlive("path:" + path) {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard spawns < 3 else { throw ReadError.runnerFailed }
            spawns += 1
            _ = try Reader.run(["__runner", path, "--index-only"], password: password)
        }
    }

    private func runReparse(
        path: String, pages: [Int]?, ocr: Bool, workers: Int?,
        password: String?
    ) throws -> (status: Int32, output: String) {
        let list = pages.map { $0.map(String.init).joined(separator: ",") } ?? "all"
        return try Reader.run(
            ["__runner", path, "--reparse=" + list] + (ocr ? ["--ocr"] : [])
                + (workers.map { ["--workers=\($0)"] } ?? []), password: password)
    }

    /// Runs `pdf` with these arguments in this command's process group, so Ctrl-C stops it, and
    /// waits for it. Returns its exit code (128 and the signal when a signal ended it) and what it
    /// printed.
    private static func run(_ arguments: [String], password: String?) throws -> (status: Int32, output: String) {
        let (pid, output) = try Processes.spawn(
            Env.executablePath, arguments, detached: false, captureOutput: true,
            environment: password.map { [Env.passwordVariable: $0] } ?? [:])
        var data = Data()
        if let output { data = FileHandle(fileDescriptor: output, closeOnDealloc: true).readDataToEndOfFile() }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (code, String(decoding: data, as: UTF8.self))
    }
}
