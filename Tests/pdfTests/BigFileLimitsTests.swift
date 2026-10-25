import Foundation
import Testing

@testable import pdf

/// The limits on big files (ROADMAP.md → M2.21): `pdf crop --figure` stops at a time limit and says
/// how far it looked, and `pdf reparse` replaces its pages in chunks. Each runs the built `pdf`
/// with a fresh home and small limits, as an agent would meet them on a big file.
@Suite(.serialized) struct BigFileLimitsTests {
    static let paper = ReparseTests.paper

    static func pdf(_ arguments: [String], home: URL, environment: [String: String] = [:]) throws -> OutputContractTests.Run {
        try ReparseTests.pdf(arguments, home: home, environment: environment)
    }

    /// Table 22 of the paper is on its last page, 18. With batches of 3 pages and no time to
    /// spare, the command stops after the first batch, says how many pages it searched and how to go
    /// on, in the one failure shape; run again without the limit, it finds the table. Before M2.21 it
    /// parsed the whole file and found it at once, whatever the time.
    @Test func cropStopsAtTheTimeLimitAndSaysHowFarItLooked() throws {
        let home = try OutputContractTests.freshHome()
        let limits = ["PDF_CLI_LOOK_BATCH": "3", "PDF_CLI_LOOK_TIME_LIMIT": "0"]
        let stopped = try Self.pdf(["crop", Self.paper, "--table", "22"], home: home, environment: limits)
        #expect(stopped.status == 1, "\(stopped.output)\(stopped.errors)")
        let text = stopped.output + stopped.errors
        #expect(text.contains("\(Self.paper): failed: no table 22 found yet: stopped at the time limit of 0 s with "), "\(text)")
        #expect(text.contains(" of 18 pages searched; run the command again to look further"), "\(text)")
        let json = try Self.pdf(["crop", Self.paper, "--table", "22", "--json"], home: home, environment: limits)
        #expect(json.status == 1)
        #expect((json.output + json.errors).contains("\"failed\":\"no table 22 found yet: stopped at the time limit"))
        let found = try Self.pdf(["crop", Self.paper, "--table", "22"], home: home)
        #expect(found.status == 0, "\(found.output)\(found.errors)")
        #expect(found.output.contains("p.18 · caption: Unified adaptation prompt structure."))
    }

    /// A number on page 4 is found by the first batch of 4 pages, though no time is left for a second.
    @Test func cropFindsAnEarlyFigureInTheFirstBatch() throws {
        let home = try OutputContractTests.freshHome()
        let limits = ["PDF_CLI_LOOK_BATCH": "4", "PDF_CLI_LOOK_TIME_LIMIT": "0"]
        let found = try Self.pdf(["crop", Self.paper, "--figure", "2"], home: home, environment: limits)
        #expect(found.status == 0, "\(found.output)\(found.errors)")
        #expect(found.output.contains("p.4 · caption: CTRL Framework Overview."))
    }

    // MARK: Reparse in chunks

    /// With chunks of 5 pages and no time to spare, a reparse of 11 pages replaces the first chunk,
    /// says it stopped at the time limit, ends 2, and prints the command for the 6 pages left; that
    /// command reads them. `--json` gives `remaining` and `next`. Before M2.21 the whole run was one
    /// transaction and had no limit.
    @Test func aReparseStopsAtTheTimeLimitAndNamesTheRest() throws {
        let home = try OutputContractTests.freshHome()
        let file = try ReparseTests.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--budget", "all"], home: home)
        let limits = ["PDF_CLI_REPARSE_CHUNK": "5", "PDF_CLI_REPARSE_TIME_LIMIT": "0"]
        let stopped = try Self.pdf(["reparse", file, "--page", "2-12"], home: home, environment: limits)
        #expect(stopped.status == 2, "\(stopped.output)")
        #expect(stopped.output.contains("reparsed 5 pages of 18"), "\(stopped.output)")
        #expect(stopped.output.contains("stopped at the time limit of 0 s with 6 pages not read"), "\(stopped.output)")
        #expect(stopped.output.contains("pdf reparse \(file) --page 7-12"), "\(stopped.output)")
        #expect(stopped.errors.contains("reparsed 5 of 11 pages"), "\(stopped.errors)")
        let json = try Self.pdf(["reparse", file, "--page", "2-12", "--json"], home: home, environment: limits)
        #expect(json.status == 2)
        #expect(json.json?["remaining"] as? [Int] == [7, 8, 9, 10, 11, 12], "\(json.output)")
        #expect((json.json?["next"] as? String)?.hasSuffix("--page 7-12") == true)
        #expect((json.json?["pages"] as? [Int]) == [2, 3, 4, 5, 6])
        let rest = try Self.pdf(["reparse", file, "--page", "7-12"], home: home, environment: ["PDF_CLI_REPARSE_CHUNK": "5"])
        #expect([0, 2].contains(rest.status), "\(rest.output)")
        #expect(rest.output.contains("reparsed 6 pages of 18"), "\(rest.output)")
        #expect(!rest.output.contains("stopped at the time limit"))
        #expect(!ReparseTests.running(file))
    }

    /// A chunked run kills at its second chunk (page 5's worker hangs): the first chunk stays
    /// replaced, the rest keep their old results, and nothing is left parsing. Before M2.21 the one
    /// transaction left all 18 old results.
    @Test func aKilledReparseKeepsTheChunksItFinished() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try ReparseTests.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--budget", "all"], home: home)
        try await DryRunTests.settle(home)
        try ReparseTests.cache(home, "UPDATE page_result SET reason = 'planted'")
        let planted = Int(try ReparseTests.cache(home, "SELECT count(*) FROM page_result WHERE reason = 'planted'")) ?? 0
        #expect(planted >= 18)
        let process = Process()
        process.executableURL = try #require(OutputContractTests.binary)
        process.arguments = ["reparse", file]
        var environment = ProcessInfo.processInfo.environment
        environment["PDF_CLI_HOME"] = home.path
        environment["PDF_CLI_TEST_FAULT"] = "hang:5"
        environment["PDF_CLI_PAGE_TIME_LIMIT"] = "300"
        environment["PDF_CLI_REPARSE_CHUNK"] = "5"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(nanoseconds: 8_000_000_000)
        #expect(process.isRunning, "the reparse should be waiting on page 5, in its second chunk")
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        var alive = true
        for _ in 0..<40 where alive {
            try await Task.sleep(nanoseconds: 500_000_000)
            alive = ReparseTests.running(file)
        }
        #expect(!alive, "a runner is still parsing after its command was killed")
        let left = Int(try ReparseTests.cache(home, "SELECT count(*) FROM page_result WHERE reason = 'planted'")) ?? 0
        #expect(left == planted - 5, "the first chunk of 5 pages should be replaced: \(planted) planted before, \(left) after")
    }

    /// Chunks of 5 pages replace the same results as one chunk of all.
    @Test func chunksReplaceTheSameResultsAsOneRun() throws {
        let whole = try OutputContractTests.freshHome(), chunked = try OutputContractTests.freshHome()
        var results: [String] = []
        for (home, chunk) in [(whole, "50"), (chunked, "5")] {
            let file = try ReparseTests.copy(Self.paper, to: home)
            _ = try Self.pdf(["read", file, "--budget", "all"], home: home)
            let run = try Self.pdf(["reparse", file], home: home, environment: ["PDF_CLI_REPARSE_CHUNK": chunk])
            #expect([0, 2].contains(run.status), "\(run.output)")
            results.append(try ReparseTests.cache(home, "SELECT group_concat(page_key || status || method || length(text), ',') FROM (SELECT * FROM page_result ORDER BY page_key)"))
        }
        #expect(results[0] == results[1])
        #expect(!results[0].isEmpty)
    }
}
