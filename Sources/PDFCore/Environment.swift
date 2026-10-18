import Darwin
import Foundation

/// Settings that every process reads the same way: the CLI, the runner and the workers.
///
/// The `PDF_CLI_*` environment variables exist for tests, apart from the password that `pdf add`
/// hands to its runner. None is a user setting.
public enum Env {
    /// Part of every cache key. Raise it when a change alters what a parse produces, so each
    /// page is parsed again on its next read (DESIGNS.md → Decision: macOS updates leave the
    /// cache alone).
    public static let parserVersion = 17

    static var variables: [String: String] { ProcessInfo.processInfo.environment }

    /// A folder that holds both data folders, for tests. Unset in normal use.
    static var home: URL? {
        variables["PDF_CLI_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// What the tool can rebuild from the PDFs: the cache and the crop images
    /// (DESIGNS.md → Decision: macOS's Library folders, with no size limit).
    public static var cacheDirectory: URL {
        if let home { return home.appendingPathComponent("Caches", isDirectory: true) }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("pdf-cli", isDirectory: true)
    }

    /// The agent's own work: the library list, picks and memos.
    public static var supportDirectory: URL {
        if let home { return home.appendingPathComponent("Support", isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("pdf-cli", isDirectory: true)
    }

    /// How long one page may take before its worker is stopped and the page fails.
    public static var pageTimeLimit: TimeInterval {
        variables["PDF_CLI_PAGE_TIME_LIMIT"].flatMap(Double.init) ?? 30
    }

    /// How long an index or page worker may stay silent while it opens the file, before its first
    /// event: a large file, or one on a slow disk or network volume, can take far longer to open
    /// than a page takes to read. Under the 120 s an agent's command commonly gets.
    public static var openTimeLimit: TimeInterval {
        variables["PDF_CLI_OPEN_TIME_LIMIT"].flatMap(Double.init) ?? 90
    }

    /// How long a file's "slow to open" verdict stands before a command tries the file again.
    /// Commands in between get the verdict at once, rather than waiting out the open limit again.
    public static var slowOpenRetry: TimeInterval {
        variables["PDF_CLI_SLOW_OPEN_RETRY"].flatMap(Double.init) ?? 600
    }

    /// How much memory one worker may hold before it is stopped and its page fails.
    public static var memoryLimitBytes: UInt64 {
        let megabytes = variables["PDF_CLI_MEMORY_LIMIT_MB"].flatMap(UInt64.init) ?? 2048
        return megabytes << 20
    }

    /// The password that `pdf add --password` gives for a locked file. It reaches the runner
    /// and its workers in their environment, which other users cannot read, unlike a command
    /// line.
    public static var password: String { variables[passwordVariable] ?? "" }
    public static let passwordVariable = "PDF_CLI_PASSWORD"

    /// How many workers run at once on this Mac, across every parse: half the performance
    /// cores, and at least 2, so the user's own work stays responsive (see `WorkerPool`).
    public static var workerCount: Int {
        if let count = variables["PDF_CLI_WORKERS"].flatMap(Int.init), count > 0 { return count }
        let cores = sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 4
        return max(2, cores / 2)
    }

    /// The macOS build that parsed a page, such as "25E246". Each page records it.
    public static var macOSBuild: String {
        sysctlString("kern.osversion") ?? ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// The `pdf` binary that the CLI starts again as a runner or a worker.
    public static var executablePath: String {
        if let path = variables["PDF_CLI_EXECUTABLE"] { return path }
        let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return url.resolvingSymlinksInPath().path
    }

    /// A fault that a test plants in a worker, such as "hang:3", "alloc:3", "crash:3" or
    /// "background-hang:3", where 3 is a page index counted from 0. The prefix "index-" moves
    /// it to the index.
    static var testFault: (kind: String, page: Int)? {
        guard let value = variables["PDF_CLI_TEST_FAULT"] else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let page = Int(parts[1]) else { return nil }
        return (String(parts[0]), page)
    }

    /// Appends a line to the file named by `PDF_CLI_LOG`, so a test can count parse jobs.
    static func log(_ line: String) {
        guard let path = variables["PDF_CLI_LOG"],
              let handle = FileHandle(forWritingAtPath: path) ?? {
                  FileManager.default.createFile(atPath: path, contents: nil)
                  return FileHandle(forWritingAtPath: path)
              }() else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
