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

    public var description: String {
        switch self {
        case .notFound(let path): return "no such file: \(path)"
        case .pageOutOfRange(let page, let count): return "page \(page + 1) is out of range: the file has \(count) pages"
        case .runnerFailed: return "the parser stopped before it finished; run the command again"
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

    /// The path the cache knows a file by: absolute, with symbolic links resolved.
    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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
        var retriedLocked = false
        defer { if let runner { _ = Processes.reap(runner) } }

        while true {
            guard let stat = FileStat(path: path) else { throw ReadError.notFound(rawPath) }
            var locks = ["path:" + path]
            switch try store.entry(path: path, stat: stat) {
            case .failed(let reason)? where password != nil && reason.hasPrefix(OpenFailure.locked) && !retriedLocked:
                // A password may open a file the cache knows as locked: it is indexed again.
                try store.forgetEntry(path: path)
                retriedLocked = true
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
                runner = try Processes.spawn(Env.executablePath,
                                             ["__runner", path, "--pages=" + pages] + (workers.map { ["--workers=\($0)"] } ?? []),
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
}
