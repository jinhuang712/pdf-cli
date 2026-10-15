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

    public init(store: Store) {
        self.store = store
    }

    /// Returns the pages, counted from 0, once each one is cached. Nil means every page.
    public func read(path rawPath: String, pages wanted: [Int]?) throws -> ReadOutcome {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
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
                runner = try Processes.spawn(Env.executablePath, ["__runner", path],
                                             detached: true, captureOutput: false).pid
                spawns += 1
                lastSpawn = Date()
            }
            if let current = runner, Processes.reap(current) != nil { runner = nil }
            Thread.sleep(forTimeInterval: pause)
            pause = min(pause * 1.5, 0.05)
        }
    }
}
