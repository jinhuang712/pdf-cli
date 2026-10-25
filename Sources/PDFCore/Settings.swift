import Darwin
import Foundation

/// What the user sets with `pdf setup`: how much memory parsing may take (DESIGNS.md → Decision:
/// the user sets parsing's memory, the tool the worker count). It is stored in the agent's own
/// folder, `settings.json` beside the library, so clearing the cache never loses it, and `Env`
/// reads it for every process: the CLI, the runner and the workers.
public enum Settings {
    /// What the file holds. A field that is nil is not set, and the default holds.
    public struct Stored: Codable, Equatable, Sendable {
        /// The memory all of parsing's workers may take together, in megabytes.
        public var memoryMB: Int?
        public init(memoryMB: Int? = nil) { self.memoryMB = memoryMB }
    }

    /// The named budgets of `pdf setup`, as workers of 2 GB each on this Mac: light is one worker,
    /// balanced is what the Mac does when nothing is set (half the performance cores, at least 2),
    /// and fastest is a worker for each performance core (at least 2). So the default is never
    /// above fastest or below balanced, whatever the Mac. The numbers are estimates: a worker's
    /// memory on text and on OCR pages is not measured yet, so they wait for the final wrap-up.
    public enum Preset: String, CaseIterable, Sendable {
        case light, balanced, fastest

        public func workers(performanceCores cores: Int) -> Int {
            switch self {
            case .light: return 1
            case .balanced: return max(2, cores / 2)
            case .fastest: return max(2, cores)
            }
        }

        public func megabytes(performanceCores cores: Int) -> Int {
            workers(performanceCores: cores) * Settings.workerLimitMB
        }

        public var summary: String {
            switch self {
            case .light: return "one worker at a time; the Mac stays free for your own work"
            case .balanced: return "what the Mac does when nothing is set"
            case .fastest: return "a worker for each performance core"
            }
        }
    }

    /// The least a budget may be: a worker below this fails pages that need more.
    public static let minimumMB = 512
    /// The most: 1 TB, far above any Mac's memory, so no size can overflow a calculation.
    public static let maximumMB = 1024 * 1024
    /// What one worker may hold, at most, and what it holds when nothing is set.
    public static let workerLimitMB = 2048

    public static func file(in directory: URL = Env.supportDirectory) -> URL {
        directory.appendingPathComponent("settings.json")
    }

    /// The stored settings, and why the file could not be read, when it could not: a file that
    /// is not valid reads as nothing set, and `pdf doctor` names it.
    public static func load(from directory: URL = Env.supportDirectory) -> (stored: Stored, problem: String?) {
        let url = file(in: directory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Only a file that is not there means nothing is set.
            return (Stored(), nil)
        } catch {
            return (Stored(), "\(url.path) cannot be read (\(error.localizedDescription)); the defaults hold")
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return (Stored(), "\(url.path) is not valid; the defaults hold until `pdf setup` writes it again")
        }
        if let memory = stored.memoryMB, memory < minimumMB || memory > maximumMB {
            return (Stored(), "\(url.path) sets \(memory) MB, outside \(format(minimumMB)) to \(format(maximumMB)); the defaults hold")
        }
        return (stored, nil)
    }

    /// Writes the settings. Nothing set removes the file, except a link: that is written through
    /// as an empty object, so the link and the file it names both stay (the way
    /// `pdf agent-guide --install` treats a link).
    public static func save(_ stored: Stored, to directory: URL = Env.supportDirectory) throws {
        let url = file(in: directory)
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        if stored == Stored(), !isLink {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = isLink ? try AgentGuide.destination(of: url) : url
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(stored).write(to: target, options: .atomic)
    }

    /// A size for people, in binary units: "4 GB", "512 MB", "1 TB". Doctor and setup both use it.
    public static func format(_ megabytes: Int) -> String {
        if megabytes >= 1024 * 1024, megabytes % (1024 * 1024) == 0 { return "\(megabytes / (1024 * 1024)) TB" }
        if megabytes >= 1024, megabytes % 1024 == 0 { return "\(megabytes / 1024) GB" }
        if megabytes >= 1024 { return String(format: "%.1f GB", Double(megabytes) / 1024) }
        return "\(megabytes) MB"
    }

    /// A memory size as a person writes it: `4GB`, `4096MB`, `2.5gb`, or a bare number of
    /// megabytes, as `PDF_CLI_MEMORY_LIMIT_MB` is. Returns megabytes, or why not.
    public static func parseMemory(_ text: String) -> Result<Int, MemoryError> {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        // Digits with an optional fraction and an optional unit: no sign, no exponent, no hex.
        guard let match = lowered.range(of: #"^[0-9]+(\.[0-9]+)?\s*(tb|t|gb|g|mb|m)?$"#, options: .regularExpression),
            match == lowered.startIndex..<lowered.endIndex
        else { return .failure(.notANumber(text)) }
        var number = lowered
        var factor = 1.0
        var unit = false
        for (suffix, value) in [("tb", 1_048_576.0), ("t", 1_048_576.0), ("gb", 1024.0), ("g", 1024.0), ("mb", 1.0), ("m", 1.0)]
        where lowered.hasSuffix(suffix) {
            number = String(lowered.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            factor = value
            unit = true
            break
        }
        guard let value = Double(number), value.isFinite, value > 0 else { return .failure(.notANumber(text)) }
        let size = value * factor
        guard size <= Double(maximumMB) else { return .failure(.tooLarge) }
        let megabytes = Int(size.rounded())
        // "--memory 4" most likely means 4 GB; a bare number that small would be a budget no worker fits.
        if !unit, megabytes < 64 { return .failure(.ambiguous(text)) }
        guard megabytes >= minimumMB else { return .failure(.tooSmall(megabytes)) }
        return .success(megabytes)
    }

    public enum MemoryError: Error, Equatable, CustomStringConvertible {
        case notANumber(String)
        case ambiguous(String)
        case tooSmall(Int)
        case tooLarge

        public var description: String {
            switch self {
            case .notANumber(let text):
                return "\"\(text)\" is not a memory size: give light, balanced, fastest, default, or a size such as 4GB, 3072MB or 1TB"
            case .ambiguous(let text):
                return "\"\(text)\" with no unit reads as megabytes, far too little: write \(text)GB or \(text)MB"
            case .tooLarge:
                return "that is more than 1 TB, the most a budget may be"
            case .tooSmall(let megabytes):
                return "\(megabytes) MB is under the least of \(minimumMB) MB a worker needs"
            }
        }
    }

    /// What a choice turns into: how many workers, and how much one may hold before it is stopped.
    public struct Plan: Equatable, Sendable {
        public var workers: Int
        public var workerLimitMB: Int
    }

    /// The worker count and each worker's limit for a memory budget on a Mac with `performanceCores`.
    /// The limits of the workers add up to at most the budget. With no budget the default holds:
    /// half the performance cores, at least 2, each with 2 GB.
    public static func plan(budgetMB: Int?, performanceCores: Int) -> Plan {
        guard let budgetMB else {
            return Plan(workers: max(2, performanceCores / 2), workerLimitMB: workerLimitMB)
        }
        let workers = min(max(2, performanceCores), max(1, budgetMB / workerLimitMB))
        return Plan(workers: workers, workerLimitMB: min(workerLimitMB, max(256, budgetMB / workers)))
    }

    /// The named budget a number is, if any, on a Mac with `performanceCores`.
    public static func preset(forMB megabytes: Int, performanceCores: Int = Env.performanceCores) -> Preset? {
        Preset.allCases.first { $0.megabytes(performanceCores: performanceCores) == megabytes }
    }
}

/// How much load the Mac is under, and so how many workers may run (DESIGNS.md → Decision: the
/// user sets parsing's memory, the tool the worker count): fewer under memory pressure, heat or
/// Low Power Mode. It reads macOS's own reports and decides nothing about them.
public enum Pressure {
    public enum Level: Int, Sendable { case normal, high, critical }

    public struct Reading: Equatable, Sendable {
        public var level: Level
        /// What macOS reports, empty when it reports nothing unusual.
        public var reasons: [String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, reading: Reading)?

    /// The reading now, kept for 2 s, since a runner asks on every pass of its loop.
    public static var current: Reading {
        if let forced = Env.variables["PDF_CLI_PRESSURE"] {
            switch forced {
            case "high": return Reading(level: .high, reasons: ["PDF_CLI_PRESSURE"])
            case "critical": return Reading(level: .critical, reasons: ["PDF_CLI_PRESSURE"])
            default: return Reading(level: .normal, reasons: [])
            }
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 2 { return cached.reading }
        let reading = read()
        cached = (Date(), reading)
        return reading
    }

    static func read() -> Reading {
        var level = Level.normal
        var reasons: [String] = []
        func note(_ new: Level, _ reason: String) {
            reasons.append(reason)
            level = Level(rawValue: max(level.rawValue, new.rawValue)) ?? level
        }
        // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
        switch Env.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4...: note(.critical, "memory pressure is critical")
        case 2...: note(.high, "memory pressure is high")
        default: break
        }
        switch ProcessInfo.processInfo.thermalState {
        case .critical: note(.critical, "the Mac is critically hot")
        case .serious: note(.high, "the Mac is hot")
        default: break
        }
        // Low Power Mode is read from macOS 12 on; macOS 11 has none to report.
        if #available(macOS 12, *), ProcessInfo.processInfo.isLowPowerModeEnabled { note(.high, "Low Power Mode is on") }
        return Reading(level: level, reasons: reasons)
    }

    /// The workers that may run when `workers` would at rest: half under pressure or heat, one
    /// when it is critical; never fewer than one.
    public static func reduced(_ workers: Int, _ level: Level = current.level) -> Int {
        switch level {
        case .normal: return workers
        case .high: return max(1, workers / 2)
        case .critical: return 1
        }
    }

    /// The workers that may run on a file read by OCR, whose pages weigh more: half as many as
    /// a text file's, but never fewer than two where the pool has two, so a scan keeps a worker
    /// beside the one a command waits on.
    public static func ocrWeighted(_ workers: Int) -> Int {
        max(min(2, workers), workers / 2)
    }
}
