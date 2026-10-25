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
}
