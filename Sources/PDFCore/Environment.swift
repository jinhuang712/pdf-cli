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
    public static let parserVersion = 21

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

    /// How many pages `pdf crop --figure` (and `--table`, `--equation`) parses at a time while it
    /// looks for a number the parsed pages do not hold, and how long it looks before it stops and
    /// says how far it got (M2.21).
    public static var lookBatch: Int { max(1, variables["PDF_CLI_LOOK_BATCH"].flatMap(Int.init) ?? 40) }
    public static var lookTimeLimit: TimeInterval { finite(variables["PDF_CLI_LOOK_TIME_LIMIT"], 60) }

    /// How many pages `pdf reparse` replaces in one transaction, and how long it goes on starting
    /// new ones, under the 120 s many agents give a command (M2.21).
    public static var reparseChunk: Int { max(1, variables["PDF_CLI_REPARSE_CHUNK"].flatMap(Int.init) ?? 50) }
    public static var reparseTimeLimit: TimeInterval { finite(variables["PDF_CLI_REPARSE_TIME_LIMIT"], 90) }

    /// A time limit from a variable: its value when it is a finite number of seconds, 0 or more, else the default.
    static func finite(_ text: String?, _ fallback: TimeInterval) -> TimeInterval {
        guard let value = text.flatMap(Double.init), value.isFinite, value >= 0 else { return fallback }
        return value
    }

    /// Seconds for a message: whole ones, or one decimal under 1 s, so 0.5 does not read as 0.
    public static func secondsText(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.1f s", seconds) : "\(Int(min(seconds, 1e9))) s"
    }

    /// How long a file's "slow to open" verdict stands before a command tries the file again.
    /// Commands in between get the verdict at once, rather than waiting out the open limit again.
    public static var slowOpenRetry: TimeInterval {
        variables["PDF_CLI_SLOW_OPEN_RETRY"].flatMap(Double.init) ?? 600
    }

    /// How much memory one worker may hold before it is stopped and its page fails.
    public static var memoryLimitBytes: UInt64 { UInt64(min(max(parsing.workerLimitMB, 1), Settings.maximumMB)) << 20 }

    /// The password that `pdf add --password` gives for a locked file. It reaches the runner
    /// and its workers in their environment, which other users cannot read, unlike a command
    /// line.
    public static var password: String { variables[passwordVariable] ?? "" }
    public static let passwordVariable = "PDF_CLI_PASSWORD"

    /// How many workers run at once on this Mac, across every parse (see `WorkerPool`): what
    /// the user's memory budget allows, else half the performance cores and at least 2, so the
    /// user's own work stays responsive.
    public static var workerCount: Int { parsing.workers }

    /// The performance cores, or all the cores where the Mac has one kind.
    public static var performanceCores: Int {
        sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 4
    }

    /// Where a parsing setting comes from, as `pdf doctor` says it.
    public enum Source: String, Sendable {
        case environment, setup, `default`
    }

    /// The parsing settings in force, with where each comes from. Read once for the process.
    public struct Parsing: Sendable {
        public var memoryBudgetMB: Int?
        public var memorySource: Source
        public var workers: Int
        public var workersSource: Source
        public var workerLimitMB: Int
        public var workerLimitSource: Source
        /// Why the settings file was not used, when it was not.
        public var problem: String?
    }

    public static let parsing: Parsing = resolveParsing(supportDirectory: supportDirectory, variables: variables)

    static func resolveParsing(supportDirectory: URL, variables: [String: String]) -> Parsing {
        let (stored, problem) = Settings.load(from: supportDirectory)
        let plan = Settings.plan(budgetMB: stored.memoryMB, performanceCores: performanceCores)
        let fromSetup: Source = stored.memoryMB == nil ? .default : .setup
        var parsing = Parsing(
            memoryBudgetMB: stored.memoryMB, memorySource: fromSetup, workers: plan.workers,
            workersSource: fromSetup, workerLimitMB: plan.workerLimitMB,
            workerLimitSource: fromSetup, problem: problem)
        if let count = variables["PDF_CLI_WORKERS"].flatMap(Int.init), count > 0 {
            parsing.workers = count
            parsing.workersSource = .environment
        }
        if let megabytes = variables["PDF_CLI_MEMORY_LIMIT_MB"].flatMap(Int.init), megabytes > 0 {
            parsing.workerLimitMB = megabytes
            parsing.workerLimitSource = .environment
        }
        return parsing
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
