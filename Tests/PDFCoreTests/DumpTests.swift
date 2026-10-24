import Foundation
import Testing
@testable import PDFCore

@Suite struct DumpTests {
    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-dump-\(UUID())")
    }

    /// A name from the PDF never picks the folder a file lands in, and never hides it or clashes.
    @Test func hostileNamesStayInsideTheFolder() {
        var taken = Set<String>()
        #expect(Dump.safeName("../../etc/passwd", fallback: "attachment", taken: &taken) == "passwd")
        #expect(Dump.safeName("..\\..\\win.ini", fallback: "attachment", taken: &taken) == "win.ini")
        #expect(Dump.safeName(".bashrc", fallback: "attachment", taken: &taken) == "bashrc")
        #expect(Dump.safeName("a\u{0}b\nc.txt", fallback: "attachment", taken: &taken) == "abc.txt")
        #expect(Dump.safeName("/", fallback: "attachment", taken: &taken) == "attachment")
        #expect(Dump.safeName("passwd", fallback: "attachment", taken: &taken) == "passwd-2")
        #expect(Dump.safeName("PASSWD", fallback: "attachment", taken: &taken) == "PASSWD-3")
        #expect(Dump.safeName(String(repeating: "x", count: 300) + ".pdf", fallback: "a", taken: &taken).utf8.count <= 200)
    }

    /// Attachments and scripts are written as inert files: no execute bit, scripts as text with
    /// a header, and a file already there is never overwritten.
    @Test func payloadsAreSavedInertAndNeverOverwrite() throws {
        let out = folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let items = try Dump.payloads(path: repoRoot.appendingPathComponent("testdata/safety/carries-attachments.pdf").path,
                                      folder: out, attachments: true, scripts: true)
        #expect(items.map(\.kind) == ["attachment", "attachment"])
        for item in items {
            let attributes = try FileManager.default.attributesOfItem(atPath: try #require(item.path))
            #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o111 == 0)
        }
        let scripts = try Dump.payloads(path: repoRoot.appendingPathComponent("testdata/safety/carries-scripts.pdf").path,
                                        folder: out, attachments: false, scripts: true)
        // Two scripts, and the program launch the file names, written as a note and never started.
        #expect(scripts.count == 3)
        let text = try String(contentsOfFile: try #require(scripts[0].path), encoding: .utf8)
        #expect(text.hasPrefix("// JavaScript on document open") && text.contains("app.alert"))
        #expect(scripts.last.flatMap { try? String(contentsOfFile: $0.path ?? "", encoding: .utf8) }?.contains("It was not started.") == true)
        // A second dump into the same folder writes beside the first files, never over them.
        let again = try Dump.payloads(path: repoRoot.appendingPathComponent("testdata/safety/carries-scripts.pdf").path,
                                      folder: out, attachments: false, scripts: true)
        #expect(again.count == 3 && Set(again.compactMap(\.path)).isDisjoint(with: scripts.compactMap(\.path)))
        #expect(try String(contentsOfFile: try #require(scripts[0].path), encoding: .utf8) == text)
    }

    /// An attachment is not saved when its flag is off.
    @Test func onlyWhatIsAskedForIsWritten() throws {
        let out = folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let items = try Dump.payloads(path: repoRoot.appendingPathComponent("testdata/safety/carries-attachments.pdf").path,
                                      folder: out, attachments: false, scripts: true)
        #expect(items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("attachments").path))
    }

    /// Names that are alike to the file system get numbers, whitespace in front of a dot does not
    /// hide a file, and a name never outgrows what the file system takes.
    @Test func namesAreFittedToTheFileSystem() {
        var taken = Set<String>()
        #expect(Dump.safeName(" .hidden", fallback: "a", taken: &taken) == "hidden")
        #expect(Dump.safeName("\u{3000}.bashrc", fallback: "a", taken: &taken) == "bashrc")
        #expect(Dump.safeName("\u{202E}gpj.exe", fallback: "a", taken: &taken) == "gpj.exe")
        #expect(Dump.safeName("liſt.txt", fallback: "a", taken: &taken) == "liſt.txt")
        #expect(Dump.safeName("LIST.TXT", fallback: "a", taken: &taken) == "LIST.TXT")
        let accents = "a" + String(repeating: "\u{0301}", count: 300) + ".txt"
        #expect(Dump.safeName(accents, fallback: "a", taken: &taken).utf8.count <= 200)
    }

    /// A link in the way of the output folder is refused, not followed.
    @Test func aLinkInTheWayIsRefused() throws {
        let out = folder()
        let target = folder()
        defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("attachments"), withDestinationURL: target)
        #expect(throws: DumpError.self) { try Dump.write(Data("x".utf8), as: "evil.txt", in: out, sub: "attachments") }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).isEmpty)
    }

    /// A taken name gets a number and the first file stays as it was.
    @Test func aTakenNameGetsANumber() throws {
        let out = folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let first = try Dump.write(Data("one".utf8), as: "a.txt", in: out)
        let second = try Dump.write(Data("two".utf8), as: "a.txt", in: out)
        #expect(first.lastPathComponent == "a.txt" && second.lastPathComponent == "a-2.txt")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
    }
}
