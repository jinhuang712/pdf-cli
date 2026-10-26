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
        #expect(first.output.contains("(crops all 3 linked parts)"), "\(first.output)")
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
                !read.output.contains("continues on") && !read.output.contains("continued from") && !read.output.contains("linked parts"),
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
}
