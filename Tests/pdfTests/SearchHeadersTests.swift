import Foundation
import Testing

/// M2.22: `pdf search` leaves out the hits on running headers, footers and page numbers, counts
/// them, and brings them back with `--show headers`. The file is testdata/notes/running-headers.pdf:
/// six pages, each with a header "Annual Ledger Report", a footer "Ledger confidential" and its
/// page number, whose words are real words in the body of pages 3, 4, 5 and 2.
@Suite(.serialized) struct SearchHeadersTests {
    static let file = OutputContractTests.root.appendingPathComponent("testdata/notes/running-headers.pdf").path

    static func search(_ arguments: [String], home: URL) throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(["search"] + arguments, home: home)
    }

    @Test func theRealHitsStayAndTheHeadersAreCountedWithTheFlagThatShowsThem() throws {
        let home = try OutputContractTests.freshHome()
        let run = try Self.search([Self.file, "ledger"], home: home)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("2 hits · all 6 pages searched"), "\(run.output)")
        #expect(run.output.contains("running headers and footers: 12 hits left out (show: --show headers)"), "\(run.output)")
        #expect(run.output.contains("p.3 ¶2") && run.output.contains("p.4 ¶2"), "\(run.output)")
        #expect(!run.output.contains("¶1 ·") && !run.output.contains("¶4 ·"), "\(run.output)")

        let shown = try Self.search([Self.file, "ledger", "--show", "headers"], home: home)
        #expect(shown.output.contains("14 hits") && !shown.output.contains("left out"), "\(shown.output)")
        #expect(shown.output.contains("p.1 ¶1 · [header]") && shown.output.contains("p.6 ¶4 · [footer]"), "\(shown.output)")
        #expect(shown.output.contains("p.3 ¶2 · The"), "\(shown.output)")
    }

    @Test func pageNumbersAreLeftOutAndTheSameDigitInABodyStays() throws {
        let home = try OutputContractTests.freshHome()
        let run = try Self.search([Self.file, "2"], home: home)
        #expect(run.output.contains("1 hit"), "\(run.output)")
        #expect(run.output.contains("p.2 ¶2 · Section **2**"), "\(run.output)")
        #expect(run.output.contains("1 hit left out"), "\(run.output)")
    }

    @Test func jsonCountsWhatIsLeftOutAndLabelsWhatIsShown() throws {
        let home = try OutputContractTests.freshHome()
        let run = try Self.search([Self.file, "ledger", "--json"], home: home)
        let json = try #require(run.json)
        #expect(json["total"] as? Int == 2)
        #expect((json["setAside"] as? [String: Int])?["runningHeaders"] == 12)
        let shown = try #require(try Self.search([Self.file, "ledger", "--show", "headers", "--json"], home: home).json)
        #expect(shown["total"] as? Int == 14)
        #expect((shown["setAside"] as? [String: Int])?["runningHeaders"] == 0)
        let kinds = (shown["hits"] as? [[String: Any]] ?? []).compactMap { $0["runningHeader"] as? String }
        #expect(kinds.filter { $0 == "header" }.count == 6 && kinds.filter { $0 == "footer" }.count == 6)
    }

    @Test func aPatternAndTheLibraryLeaveThemOutToo() throws {
        let home = try OutputContractTests.freshHome()
        let pattern = try Self.search([Self.file, "--regex", "Ledger"], home: home)
        #expect(pattern.output.contains("2 hits") && pattern.output.contains("12 hits left out"), "\(pattern.output)")
        // The library: the file joined it with the first search.
        let library = try Self.search(["confidential"], home: home)
        #expect(library.output.contains("1 hit") && library.output.contains("6 hits left out"), "\(library.output)")
        #expect(library.output.contains("p.5 ¶2"), "\(library.output)")
    }

    @Test func showTakesHeadersOnly() throws {
        let home = try OutputContractTests.freshHome()
        let run = try Self.search([Self.file, "ledger", "--show", "raw"], home: home)
        #expect(run.status == 64, "\(run.output)")
    }
}
