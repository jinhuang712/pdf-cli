import ArgumentParser
import Foundation
import PDFCore

/// Removes what no read can use (FEATURES.md → F12). It was `pdf doctor --clean`, which took over
/// `pdf gc`; M3.7 made it its own command, since a command that only shows should not also delete
/// (plan/decisions/060-one-command-one-job-clean-split-from-doctor.md → Decision: one command, one job; clean split from doctor).
struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove what no read can use any more, and say how much space that gave back.",
        discussion: """
            Removes cached results for files that no longer exist or changed and for old parser versions, the \
            library entries of files that no longer exist, leftover runner locks and crops older than 7 days, then \
            gives the cache's free space back. A file on a drive not plugged in keeps all of it. Picks, \
            transcripts and the settings are never removed, by clean or by pdf rm.

            pdf doctor shows what a clean would remove, without removing it; --dry-run here says the same \
            in full, opens both databases read-only, parses nothing and changes nothing.

            The summary line counts what went: files gone or changed, documents, page results, library entries, \
            runner locks and old crops, then the space freed. If a parse is running, compacting waits and the \
            rest of the space returns at the next pdf clean. With --json the object holds the doctor report and a \
            "clean" key with the counts.

            Exit codes: 0 done (or, with --dry-run, nothing changed); 1 it could not run, as when the cache is \
            damaged or locked; 64 used wrongly. It takes no PDF.

            Examples:
              pdf clean --dry-run
              pdf clean
              pdf clean --json
            """
    )

    @Flag(help: "Say what would be removed, and change nothing.") var dryRun = false
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding("pdf clean", json: json) { try clean() }
    }

    func clean() throws {
        let cleaned = try Doctor.clean(dryRun: dryRun)
        let report = Doctor.inspect()
        if json {
            struct Body: Encodable {
                var report: DoctorReport
                var clean: CleanReport
                func encode(to encoder: Encoder) throws {
                    try report.encode(to: encoder)
                    var container = encoder.container(keyedBy: Key.self)
                    try container.encode(clean, forKey: Key("clean"))
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
            return
        }
        print(DoctorCommand.cleanLine(cleaned))
        for note in report.notes { print("note: \(note)") }
        let left = dryRun ? report.problems.filter { !report.fixedByClean.contains($0) } : report.problems
        for problem in left { print("problem: \(problem)") }
    }
}

