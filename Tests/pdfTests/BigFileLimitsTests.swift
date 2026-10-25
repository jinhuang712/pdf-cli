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
    /// on, in the one failure shape. Before M2.21 it parsed the whole file and found it at once,
    /// whatever the time.
    @Test func cropStopsAtTheTimeLimitAndSaysHowFarItLooked() throws {
        let home = try OutputContractTests.freshHome()
        let limits = ["PDF_CLI_LOOK_BATCH": "3", "PDF_CLI_LOOK_TIME_LIMIT": "0"]
        let stopped = try Self.pdf(["crop", Self.paper, "--table", "22", "--json"], home: home, environment: limits)
        #expect(stopped.status == 1, "\(stopped.output)\(stopped.errors)")
        let text = stopped.output + stopped.errors
        #expect(text.contains("\"failed\":\"no table 22 found yet: stopped at the time limit of 0.0 s with "), "\(text)")
        #expect(text.contains(" of 18 pages searched; run the command again to look further"), "\(text)")
    }

    /// A number on page 4 is found by the first batch of 4 pages, though no time is left for a second.
    /// Pages after it are not parsed yet, and the output says which: another figure 2 there would make
    /// the answer ambiguous (the review of M2.21: the same command gave two answers as the parse went on).
    @Test func cropFindsAnEarlyFigureAndNamesThePagesNotSearched() throws {
        let home = try OutputContractTests.freshHome()
        let limits = ["PDF_CLI_LOOK_BATCH": "4", "PDF_CLI_LOOK_TIME_LIMIT": "0"]
        let found = try Self.pdf(["crop", Self.paper, "--figure", "2"], home: home, environment: limits)
        #expect(found.status == 0, "\(found.output)\(found.errors)")
        #expect(found.output.contains("p.4 · caption: CTRL Framework Overview."))
        #expect(found.output.contains("not searched: "), "\(found.output)")
        #expect(found.output.contains("would make this ambiguous"))
    }

    /// The JSON of the same crop names the pages as numbers.
    @Test func cropJSONNamesThePagesNotSearched() throws {
        let home = try OutputContractTests.freshHome()
        let limits = ["PDF_CLI_LOOK_BATCH": "4", "PDF_CLI_LOOK_TIME_LIMIT": "0"]
        let found = try Self.pdf(["crop", Self.paper, "--figure", "2", "--json"], home: home, environment: limits)
        #expect(found.status == 0, "\(found.output)\(found.errors)")
        let pages = found.json?["notSearched"] as? [Int]
        #expect(pages?.isEmpty == false && pages?.allSatisfy { $0 > 4 } == true, "\(found.output)")
    }

    // MARK: Reparse in chunks

    /// With chunks of 5 pages and no time to spare, a reparse of 11 pages replaces the first chunk,
    /// says it stopped at the time limit, ends 2, and prints the command for the 6 pages left; that
    /// command reads them. `--json` gives `remaining` and `next`, and no progress line comes before the
    /// object. Before M2.21 the whole run was one transaction and had no limit.
    @Test func aReparseStopsAtTheTimeLimitAndNamesTheRest() throws {
        let home = try OutputContractTests.freshHome()
        let file = try ReparseTests.copy(Self.paper, to: home)
        let limits = ["PDF_CLI_REPARSE_CHUNK": "5", "PDF_CLI_REPARSE_TIME_LIMIT": "0"]
        let stopped = try Self.pdf(["reparse", file, "--page", "2-12"], home: home, environment: limits)
        #expect(stopped.status == 2, "\(stopped.output)")
        #expect(stopped.output.contains("reparsed 5 pages of 18"), "\(stopped.output)")
        #expect(stopped.output.contains("stopped at the time limit of 0.0 s with 6 pages not read"), "\(stopped.output)")
        #expect(stopped.output.contains("pdf reparse \(file) --page 7-12"), "\(stopped.output)")
        #expect(stopped.errors.contains("reparsed 5 of 11 pages"), "\(stopped.errors)")
        let json = try Self.pdf(["reparse", file, "--page", "2-12", "--json", "--password", "x"], home: home, environment: limits)
        #expect(json.status == 2)
        #expect(json.errors.isEmpty, "progress under --json: \(json.errors)")
        #expect(json.json?["remaining"] as? [Int] == [7, 8, 9, 10, 11, 12], "\(json.output)")
        #expect((json.json?["next"] as? String)?.hasSuffix("--page 7-12 --password-stdin") == true, "\(json.output)")
        #expect((json.json?["pages"] as? [Int]) == [2, 3, 4, 5, 6])
        let rest = try Self.pdf(["reparse", file, "--page", "7-12"], home: home, environment: ["PDF_CLI_REPARSE_CHUNK": "5"])
        #expect([0, 2].contains(rest.status), "\(rest.output)")
        #expect(rest.output.contains("reparsed 6 pages of 18"), "\(rest.output)")
        #expect(!rest.output.contains("stopped at the time limit"))
        #expect(!ReparseTests.running(file))
    }

    /// A chunked run is killed at its second chunk (page 5's worker hangs): the first chunk stays
    /// replaced, the rest keep their old results, and nothing is left parsing. The test waits for the
    /// first chunk to show in the cache, not for a time. Before M2.21 the one transaction left every
    /// old result.
    @Test func aKilledReparseKeepsTheChunksItFinished() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try ReparseTests.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--page", "1-12", "--budget", "all"], home: home)
        try await DryRunTests.settle(home)
        try ReparseTests.cache(home, "UPDATE page_result SET reason = 'planted'")
        func planted() throws -> Int { Int(try ReparseTests.cache(home, "SELECT count(*) FROM page_result WHERE reason = 'planted'")) ?? -1 }
        let before = try planted()
        #expect(before >= 12)
        let process = Process()
        process.executableURL = try #require(OutputContractTests.binary)
        process.arguments = ["reparse", file, "--page", "1-12"]
        var environment = ProcessInfo.processInfo.environment
        environment["PDF_CLI_HOME"] = home.path
        environment["PDF_CLI_TEST_FAULT"] = "hang:5"
        environment["PDF_CLI_PAGE_TIME_LIMIT"] = "300"
        environment["PDF_CLI_REPARSE_CHUNK"] = "5"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The first chunk is in the cache when five planted rows are gone.
        var left = before
        for _ in 0..<240 where left == before {
            try await Task.sleep(nanoseconds: 250_000_000)
            left = try planted()
        }
        #expect(process.isRunning, "the reparse should be waiting on page 5, in its second chunk")
        kill(process.processIdentifier, SIGKILL)
        // No waitUntilExit: it did not return here, though the command was gone.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var alive = true
        for _ in 0..<40 where alive {
            try await Task.sleep(nanoseconds: 500_000_000)
            alive = ReparseTests.running(file)
        }
        #expect(!alive, "a runner is still parsing after its command was killed")
        let after = try planted()
        #expect(after == before - 5, "the first chunk of 5 pages should be replaced: \(before) planted before, \(after) after")
    }

    /// Chunks of 2 pages replace the same results as one chunk of all.
    @Test func chunksReplaceTheSameResultsAsOneRun() throws {
        let whole = try OutputContractTests.freshHome(), chunked = try OutputContractTests.freshHome()
        var results: [String] = []
        for (home, chunk) in [(whole, "50"), (chunked, "2")] {
            let file = try ReparseTests.copy(Self.paper, to: home)
            // A file never read is parsed only for the pages asked, so nothing parses in the background.
            let run = try Self.pdf(["reparse", file, "--page", "1-6"], home: home, environment: ["PDF_CLI_REPARSE_CHUNK": chunk])
            #expect([0, 2].contains(run.status), "\(run.output)")
            // The results of pages 1 to 6, by the page's position, as the cache holds them.
            results.append(
                try ReparseTests.cache(
                    home,
                    """
                    SELECT group_concat(line, ',') FROM (SELECT d.page_index || r.status || r.method || length(r.text) || r.reason AS line
                    FROM document_page d JOIN page_result r ON r.page_key = d.page_key WHERE d.page_index < 6 ORDER BY d.page_index)
                    """))
        }
        #expect(results[0] == results[1])
        #expect(!results[0].isEmpty)
    }
}
