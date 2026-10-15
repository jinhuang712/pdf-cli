import Foundation
import Testing
@testable import PDFCore

@Suite struct LibraryTests {
    func makeLibrary() throws -> Library {
        try Library(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-library-\(UUID())"))
    }

    @Test func aFileReadAgainStaysOneEntry() throws {
        let library = try makeLibrary()
        try library.register(path: "/a.pdf", docID: "abcdef0123", title: "", pageCount: 3)
        try library.register(path: "/a.pdf", docID: "abcdef0123", title: "", pageCount: 3)
        let entries = try library.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.shortID == "abcdef01")
        #expect(entries.first?.displayTitle == "a")
    }

    @Test func aChangedFilePointsAtItsNewDocument() throws {
        let library = try makeLibrary()
        try library.register(path: "/a.pdf", docID: "old", title: "Draft", pageCount: 3)
        let added = try #require(try library.entries().first?.addedAt)
        try library.register(path: "/a.pdf", docID: "new", title: "Final", pageCount: 4)
        let entry = try #require(try library.entries().first)
        #expect(entry.docID == "new")
        #expect(entry.displayTitle == "Final")
        #expect(entry.pageCount == 4)
        #expect(entry.addedAt == added)
    }

    @Test func removingAnEntryLeavesTheOthers() throws {
        let library = try makeLibrary()
        try library.register(path: "/a.pdf", docID: "a", title: "", pageCount: 1)
        try library.register(path: "/b.pdf", docID: "b", title: "", pageCount: 1)
        #expect(try library.remove(paths: ["/a.pdf", "/missing.pdf"]) == 1)
        #expect(try library.entries().map(\.path) == ["/b.pdf"])
    }
}
