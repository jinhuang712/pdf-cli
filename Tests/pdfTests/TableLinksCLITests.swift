import Foundation
import Testing

/// M3.2: `pdf read`, `pdf info` and `pdf crop` link the parts of a table that runs over page
/// breaks. The files are in testdata/tables (scripts/make-hidden-fixture.swift).
@Suite(.serialized) struct TableLinksCLITests {
    static let folder = OutputContractTests.root.appendingPathComponent("testdata/tables")
    static func file(_ name: String) -> String { folder.appendingPathComponent(name).path }

    static func pdf(_ arguments: [String], home: URL) throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home)
    }

    @Test func aTableOverThreePagesIsLinkedInReadInfoAndCrop() throws {
        let home = try OutputContractTests.freshHome()
        let path = Self.file("continued.pdf")
        // A read of the first page alone parses the page after it, and links.
        let first = try Self.pdf(["read", path, "--page", "1"], home: home)
        #expect(first.output.contains("continues on p.2; linked parts: p.1, p.2, p.3"), "\(first.output)")
        // A read of the middle page names both neighbours.
        let middle = try Self.pdf(["read", path, "--page", "2"], home: home)
        #expect(middle.output.contains("continued from p.1, continues on p.3"), "\(middle.output)")
        let last = try Self.pdf(["read", path, "--page", "3"], home: home)
        #expect(last.output.contains("continued from p.2; linked parts"), "\(last.output)")
        #expect(!last.output.contains("continues on"), "\(last.output)")

        let json = try #require(try Self.pdf(["read", path, "--json", "--page", "1-3"], home: home).json)
        let blocks = (json["blocks"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "table" }
        #expect(blocks.count == 3, "\(blocks)")
        let ids = Set(blocks.compactMap { ($0["table"] as? [String: Any])?["id"] as? String })
        #expect(ids == ["table-1-p1"], "\(ids)")
        #expect((blocks.last?["table"] as? [String: Any])?["part"] as? Int == 3)

        let info = try Self.pdf(["info", path], home: home)
        #expect(info.output.contains("· continues on p.2") && info.output.contains("· continued from p.1 · continues on p.3"), "\(info.output)")

        let crop = try Self.pdf(["crop", path, "--table", "1"], home: home)
        #expect(crop.status == 0, "\(crop.output)")
        #expect(crop.output.components(separatedBy: ".png").count - 1 == 3, "\(crop.output)")
        #expect(crop.output.contains("linked over p.1, p.2, p.3"), "\(crop.output)")
        let cropJSON = try #require(try Self.pdf(["crop", path, "--table", "1", "--page", "2", "--json"], home: home).json)
        let parts = try #require(cropJSON["parts"] as? [[String: Any]])
        #expect(parts.compactMap { $0["page"] as? Int } == [1, 2, 3])
        #expect(Set(parts.compactMap { $0["image"] as? String }).count == 3)
    }

    @Test func similarButSeparateTablesAreNotLinked() throws {
        let home = try OutputContractTests.freshHome()
        for name in ["separate.pdf", "narrow.pdf"] {
            let path = Self.file(name)
            let read = try Self.pdf(["read", path, "--full"], home: home)
            #expect(read.output.contains("[table"), "\(name): the tables are still found\n\(read.output)")
            #expect(
                !read.output.contains("continues on") && !read.output.contains("continued from p.") && !read.output.contains("linked parts"),
                "\(name)\n\(read.output)")
            let info = try Self.pdf(["info", path], home: home)
            #expect(!info.output.contains("continues on") && !info.output.contains("continued from"), "\(name)\n\(info.output)")
        }
    }

    @Test func aCaptionRepeatedInFullIsAContinuation() throws {
        let home = try OutputContractTests.freshHome()
        let read = try Self.pdf(["read", Self.file("repeated.pdf"), "--full"], home: home)
        #expect(read.output.contains("continues on p.2") && read.output.contains("continued from p.1"), "\(read.output)")
    }

    @Test func aHiddenContinuedLinksNothingAndShowsNothing() throws {
        let home = try OutputContractTests.freshHome()
        let path = Self.file("hidden-continued.pdf")
        let read = try Self.pdf(["read", path, "--full"], home: home)
        #expect(!read.output.contains("continues on") && !read.output.contains("linked parts") && !read.output.contains("PLANTED"), "\(read.output)")
        let shown = try Self.pdf(["read", path, "--full", "--show", "hidden"], home: home)
        #expect(shown.output.contains("PLANTED continued") && !shown.output.contains("linked parts"), "\(shown.output)")
    }

    @Test func aCaptionWithControlInItIsNoContinuation() throws {
        let home = try OutputContractTests.freshHome()
        let read = try Self.pdf(["read", Self.file("control.pdf"), "--full"], home: home)
        #expect(read.output.contains("[table 1]") && !read.output.contains("continues on") && !read.output.contains("linked parts"), "\(read.output)")
    }

    @Test func gapsInAChainAreNamed() throws {
        let home = try OutputContractTests.freshHome()
        let path = Self.file("gap.pdf")
        let read = try Self.pdf(["read", path, "--full"], home: home)
        #expect(read.output.contains("continued from p.1, may go on past p.2, not linked"), "\(read.output)")
        #expect(read.output.contains("continues on p.4, continued from an earlier page, not linked; linked parts: p.3, p.4"), "\(read.output)")
        let json = try #require(try Self.pdf(["read", path, "--json", "--full"], home: home).json)
        let tables = (json["blocks"] as? [[String: Any]] ?? []).compactMap { $0["table"] as? [String: Any] }
        #expect(tables.compactMap { $0["openAfter"] as? Bool } == [false, true, false, false], "\(tables)")
        #expect(tables.compactMap { $0["openBefore"] as? Bool } == [false, false, true, false], "\(tables)")
    }

    /// The walk along a chain parses the page past its end, which may hold the same number again: the
    /// check for two tables of one number runs after it.
    @Test func cropLooksAgainAfterTheWalkParsedMore() throws {
        let home = try OutputContractTests.freshHome()
        let path = Self.file("gap.pdf")
        _ = try Self.pdf(["read", path, "--page", "1"], home: home)
        let crop = try Self.pdf(["crop", path, "--table", "1"], home: home)
        #expect(crop.status == 1 && crop.output.contains("add --page"), "\(crop.status) \(crop.output)")
        let page = try Self.pdf(["crop", path, "--table", "1", "--page", "1"], home: home)
        #expect(page.status == 0 && page.output.components(separatedBy: ".png").count - 1 == 2, "\(page.output)")
    }

    @Test func aKeptReadingBelongsToTheWholeTable() throws {
        let home = try OutputContractTests.freshHome()
        let path = Self.file("continued.pdf")
        let kept = try OutputContractTests.pdf(
            ["transcribe", path, "--page", "2", "--table", "1"], home: home, stdin: "| a | b |\n|---|---|\n| 1 | 2 |\n")
        #expect(kept.status == 0, "\(kept.output)")
        let read = try Self.pdf(["read", path, "--full"], home: home)
        #expect(read.output.components(separatedBy: "| 1 | 2 |").count - 1 == 1, "\(read.output)")
        #expect(read.output.components(separatedBy: "reading of this table is shown at p.1").count - 1 == 2, "\(read.output)")
        let crop = try Self.pdf(["crop", path, "--table", "1", "--page", "3"], home: home)
        #expect(crop.output.contains("| 1 | 2 |"), "\(crop.output)")
    }
}
