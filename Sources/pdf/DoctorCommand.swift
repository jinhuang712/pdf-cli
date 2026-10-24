import ArgumentParser
import Foundation
import PDFCore

/// Shows what works on this Mac and what is wrong, and with `--clean` removes what no read can use
/// (FEATURES.md → F12; it took over `pdf gc`).
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Show what works on this Mac and what is wrong; --clean removes what no read can use.",
        discussion: """
            Shows the macOS version and what a newer one unlocks, the parser version, the models installed, the size \
            and counts of the cache and the library, the parsing settings in force and where each comes from, what \
            runs now, and the problems found. Ends 2 when it found a problem. Without --clean it changes nothing.

            --clean removes cached results for files that no longer exist or changed and for old parser versions, \
            the library entries of files that no longer exist, leftover runner locks and crops older than 7 days, \
            then gives the cache's free space back. A file on a drive not plugged in keeps all of it. --dry-run \
            says what --clean would remove, and removes nothing.

            Examples:
              pdf doctor
              pdf doctor --json
              pdf doctor --clean --dry-run
              pdf doctor --clean
            """
    )

    @Flag(help: "Remove what no read can use any more, and say how much space that gave back.") var clean = false
    @Flag(help: "With --clean: say what would be removed, and change nothing.") var dryRun = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if dryRun && !clean { throw ValidationError("--dry-run goes with --clean: pdf doctor --clean --dry-run") }
    }

    func run() throws {
        try Contract.guarding("pdf doctor", json: json) { try diagnose() }
    }

    func diagnose() throws {
        let cleaned = clean ? try Doctor.clean(dryRun: dryRun) : nil
        let report = Doctor.inspect()
        if json {
            struct Body: Encodable {
                var report: DoctorReport
                var clean: CleanReport?
                func encode(to encoder: Encoder) throws {
                    try report.encode(to: encoder)
                    var container = encoder.container(keyedBy: Key.self)
                    try container.encodeIfPresent(clean, forKey: Key("clean"))
                }
                struct Key: CodingKey {
                    var stringValue: String
                    var intValue: Int? { nil }
                    init(_ name: String) { stringValue = name }
                    init?(stringValue: String) { self.stringValue = stringValue }
                    init?(intValue: Int) { nil }
                }
            }
            print(Contract.json(Body(report: report, clean: cleaned)))
        } else if let cleaned {
            print(Self.cleanLine(cleaned))
            let left = dryRun ? report.problems.filter { !report.fixedByClean.contains($0) } : report.problems
            for problem in left { print("problem: \(problem)") }
        } else {
            print(Self.render(report))
        }
        // With --clean, the problems it fixes are not left to report: a dry run ends as the real run.
        let left = clean ? report.problems.filter { !report.fixedByClean.contains($0) } : report.problems
        if !left.isEmpty { throw ExitCode(2) }
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// The summary line of a clean, in the words `pdf gc` used.
    static func cleanLine(_ clean: CleanReport) -> String {
        let removed = clean.removed
        let counts = [
            count(removed["files"] ?? 0, "file") + " gone or changed", count(removed["documents"] ?? 0, "document"),
            count(removed["pages"] ?? 0, "page result"),
            count(removed["libraryEntries"] ?? 0, "library entry", "library entries") + " for files gone",
            count(removed["runnerLocks"] ?? 0, "runner lock") + " left over",
            count(removed["crops"] ?? 0, "crop") + " older than 7 days",
        ].joined(separator: ", ")
        if clean.dryRun == true {
            return "dry run: would remove \(counts) · compacting would give back at least \(size(clean.freedBytes)), more once the rows are gone"
                + (clean.compacted ? "" : "; a parse is running, so it would wait") + "; nothing was removed"
        }
        return "removed \(counts)"
            + (clean.compacted
                ? " · compacted the cache, freed \(size(clean.freedBytes))"
                : (clean.freedBytes > 0 ? " · freed \(size(clean.freedBytes)) of crops" : ""))
            + (clean.compacted ? "" : "\na parse is running, so the rest of the space returns after the next pdf doctor --clean")
    }

    /// Where a setting comes from, in words.
    static func from(_ setting: DoctorReport.Setting) -> String {
        switch setting.source {
        case "setup": return "set by pdf setup"
        case "default": return "the default"
        default:
            return setting.source.replacingOccurrences(of: "environment (", with: "from the environment: ").replacingOccurrences(of: ")", with: "")
        }
    }

    static func render(_ report: DoctorReport) -> String {
        var lines: [String] = []
        let mac = report.macOS
        lines.append("macOS \(mac.version) (\(mac.build)) · pdf parser \(report.parserVersion) · scanned pages read by the \(mac.scanReader)")
        let models = report.models
        lines.append("models: " + (models.installed.isEmpty ? "none installed" : models.installed.joined(separator: ", ")) + " · " + models.note)
        let cache = report.cache
        var cacheLine = "cache: \(cache.state)"
        if cache.state == "ok" {
            cacheLine +=
                " · \(size(cache.bytes)) · \(count(cache.files, "file")) · \(count(cache.documents, "document")) · \(count(cache.pages, "page result"))"
            cacheLine += " · \(count(cache.crops, "crop image")) (\(size(cache.cropBytes)))"
        } else if cache.state != "none yet" {
            cacheLine += " · \(size(cache.bytes))"
        }
        lines.append(cacheLine + " · \(cache.path)")
        let library = report.library
        var libraryLine = "library: \(library.state)"
        if library.state == "ok" {
            libraryLine += " · \(count(library.entries, "PDF")) · \(size(library.bytes))"
            if library.filesMissing > 0 { libraryLine += " · \(library.filesMissing) missing" }
            if library.filesOutOfReach > 0 { libraryLine += " · \(library.filesOutOfReach) out of reach, as on a drive not plugged in" }
        }
        lines.append(libraryLine + " · \(library.path)")
        let parsing = report.parsing
        let budget = parsing.memoryBudgetMB.value.map { size(Int64($0) << 20) + " (" + from(parsing.memoryBudgetMB) + ")" } ?? "not set (the default)"
        var parse = "parsing: memory budget \(budget) · \(count(parsing.workers.value ?? 0, "worker")) at once, \(from(parsing.workers))"
        parse += " · a worker is stopped at \(parsing.workerLimitMB.value ?? 0) MB, \(from(parsing.workerLimitMB))"
        parse += " · \(parsing.performanceCores) performance cores · load \(parsing.load)"
        if parsing.workersNow != parsing.workers.value {
            parse += " (\(parsing.loadReasons.joined(separator: ", ")): \(parsing.workersNow) worker\(parsing.workersNow == 1 ? "" : "s") for now)"
        }
        lines.append(parse)
        let running = report.running
        lines.append(
            "running: " + (running.runners.isEmpty ? "no runner" : running.runners.map { "pid \($0.pid) holds \($0.lock)" }.joined(separator: "; "))
                + " · \(running.slotsInUse) of \(running.slots) worker slots in use")
        for piece in report.missing { lines.append("missing: \(piece.piece) would unlock \(piece.unlocks)") }
        let clean = report.cleanable
        let would = [
            clean.files > 0 ? count(clean.files, "changed or gone file") : nil, clean.documents > 0 ? count(clean.documents, "document") : nil,
            clean.pages > 0 ? count(clean.pages, "page result") : nil,
            clean.libraryEntries > 0 ? count(clean.libraryEntries, "library entry", "library entries") : nil,
            clean.runnerLocks > 0 ? count(clean.runnerLocks, "runner lock") : nil, clean.crops > 0 ? count(clean.crops, "old crop") : nil,
        ].compactMap { $0 }
        if !would.isEmpty {
            lines.append("pdf doctor --clean would remove \(would.joined(separator: ", ")); see first: pdf doctor --clean --dry-run")
        }
        lines.append(report.problems.isEmpty ? "problems: none" : report.problems.map { "problem: \($0)" }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}
