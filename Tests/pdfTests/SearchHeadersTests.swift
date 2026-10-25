import Foundation
import Testing

/// M2.22: `pdf search` leaves out the hits on running headers, footers and page numbers, counts
/// them, and brings them back with `--show headers`. The file is testdata/notes/running-headers.pdf:
/// six pages, each with a header "Annual Ledger Report", a footer "Ledger confidential" and its
/// page number, whose words are real words in the body of pages 3, 4, 5 and 2.
@Suite(.serialized) struct SearchHeadersTests {
    static let notes = OutputContractTests.root.appendingPathComponent("testdata/notes")
    static let file = notes.appendingPathComponent("running-headers.pdf").path
    static let margin = notes.appendingPathComponent("margin-notes.pdf").path
    static let footnotes = notes.appendingPathComponent("restart-per-page.pdf").path

    static func search(_ arguments: [String], home: URL) throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(["search"] + arguments, home: home)
    }

    /// A fresh home with the fixtures parsed in the foreground, so a loaded machine cannot leave
    /// a search waiting for the background parse.
    static func home() throws -> URL {
        let home = try OutputContractTests.freshHome()
        let added = try OutputContractTests.pdf(["add", file, margin, footnotes], home: home)
        #expect(added.status == 0 || added.status == 2, "\(added.output)")
        return home
    }

    @Test func theRealHitsStayAndTheHeadersAreCountedWithTheFlagThatShowsThem() throws {
        let home = try Self.home()
        let run = try Self.search([Self.file, "ledger"], home: home)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains(" · 2 hits · all 6 pages searched"), "\(run.output)")
        #expect(run.output.contains("running headers and footers: 12 hits left out (show: --show headers)"), "\(run.output)")
        #expect(run.output.contains("p.3 ¶2") && run.output.contains("p.4 ¶2"), "\(run.output)")
        #expect(!run.output.contains("¶1 ·") && !run.output.contains("¶4 ·"), "\(run.output)")

        let shown = try Self.search([Self.file, "ledger", "--show", "headers"], home: home)
        #expect(shown.output.contains(" · 14 hits ·") && !shown.output.contains("left out"), "\(shown.output)")
        #expect(shown.output.contains("p.1 ¶1 · [header]") && shown.output.contains("p.6 ¶4 · [footer]"), "\(shown.output)")
        #expect(shown.output.contains("p.3 ¶2 · The"), "\(shown.output)")
    }

    @Test func pageNumbersAreLeftOutAndTheSameDigitInABodyStays() throws {
        let home = try Self.home()
        let run = try Self.search([Self.file, "2"], home: home)
        #expect(run.output.contains(" · 2 hits ·"), "\(run.output)")
        #expect(run.output.contains("p.2 ¶2 · Section **2**"), "\(run.output)")
        #expect(run.output.contains("1 hit left out"), "\(run.output)")
    }

    @Test func jsonCountsWhatIsLeftOutAndLabelsWhatIsShown() throws {
        let home = try Self.home()
        let json = try #require(try Self.search([Self.file, "ledger", "--json"], home: home).json)
        #expect(json["total"] as? Int == 2)
        #expect((json["setAside"] as? [String: Int])?["runningHeaders"] == 12)
        let shown = try #require(try Self.search([Self.file, "ledger", "--show", "headers", "--json"], home: home).json)
        #expect(shown["total"] as? Int == 14)
        #expect((shown["setAside"] as? [String: Int])?["runningHeaders"] == 0)
        let kinds = (shown["hits"] as? [[String: Any]] ?? []).compactMap { $0["runningHeader"] as? String }
        #expect(kinds.filter { $0 == "header" }.count == 6 && kinds.filter { $0 == "footer" }.count == 6)
    }

    @Test func aPatternAndTheLibraryLeaveThemOutToo() throws {
        let home = try Self.home()
        let pattern = try Self.search([Self.file, "--regex", "Ledger"], home: home)
        #expect(pattern.output.contains(" · 1 hit ·") && pattern.output.contains("12 hits left out"), "\(pattern.output)")
        let library = try Self.search(["confidential"], home: home)
        #expect(library.output.contains(" · 1 hit ·") && library.output.contains("6 hits left out"), "\(library.output)")
        #expect(library.output.contains("p.5 ¶2"), "\(library.output)")
    }

    @Test func showTakesHeadersOnly() throws {
        let home = try OutputContractTests.freshHome()
        let run = try Self.search([Self.file, "ledger", "--show", "raw"], home: home)
        #expect(run.status == 64, "\(run.output)")
    }

    /// The command that goes on keeps `--show headers`: without it the next hits are the ones
    /// the first leg left out of its count (M2.22 review, 1).
    @Test func theNextCommandKeepsShowHeaders() throws {
        let home = try Self.home()
        for extra in [[], ["--json"]] {
            let first = try Self.search([Self.file, "ledger", "--show", "headers", "--budget", "200"] + extra, home: home)
            let next =
                (first.json?["next"] as? String)
                ?? first.output.components(separatedBy: "\n").first { $0.hasPrefix("next: ") }.map { String($0.dropFirst(6)) }
            let command = try #require(next, "\(first.output)")
            #expect(command.contains("--show headers"), "\(command)")
            let words = command.split(separator: " ").dropFirst(2).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            let second = try Self.search(words, home: home)
            #expect(second.output.contains("header") && !second.output.contains("no hits from"), "\(second.output)")
        }
    }

    /// `read a hit:` points at a block a read shows, not at a header it sets aside.
    @Test func readAHitSkipsTheHeaders() throws {
        let home = try Self.home()
        let shown = try Self.search([Self.file, "ledger", "--show", "headers"], home: home)
        #expect(shown.output.contains("read a hit: pdf read") && shown.output.contains("--from p3.2"), "\(shown.output)")
        let onlyHeaders = try Self.search([Self.file, "ledger", "confidential", "--show", "headers"], home: home)
        #expect(!onlyHeaders.output.contains("read a hit:"), "\(onlyHeaders.output)")
    }

    /// Every block that holds all the words is a footer: no hit, and not "some of the words",
    /// which would say no paragraph holds them all (M2.22 review, 2).
    @Test func headersAloneHoldingEveryWordAreNoReasonToLooseTheSearch() throws {
        let home = try Self.home()
        let run = try Self.search([Self.file, "ledger", "confidential"], home: home)
        #expect(run.output.contains(" · 0 hits ·") && run.output.contains("6 hits left out"), "\(run.output)")
        #expect(!run.output.contains("hold some of them"), "\(run.output)")
        // No block holds every word: the fallback to some of them stays.
        let loose = try Self.search([Self.file, "ledger", "agreement"], home: home)
        #expect(loose.output.contains("hold some of them"), "\(loose.output)")
    }

    /// A footnote that every page repeats ("^{2}Second note of page N, about the board.") and a
    /// margin note that repeats are the text's (M2.22 review, 3).
    @Test func footnotesAndMarginNotesAreHits() throws {
        let home = try Self.home()
        let notes = try Self.search([Self.footnotes, "board"], home: home)
        #expect(!notes.output.contains("left out"), "\(notes.output)")
        let margin = try Self.search([Self.margin, "scrlttr2"], home: home)
        #expect(margin.output.contains(" · 6 hits ·") && !margin.output.contains("left out"), "\(margin.output)")
    }
}
