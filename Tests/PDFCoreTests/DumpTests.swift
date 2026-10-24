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
        #expect(Dump.safeName(String(repeating: "x", count: 300) + ".pdf", fallback: "a", taken: &taken).count <= 105)
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
        #expect(scripts.count == 2)
        let text = try String(contentsOfFile: try #require(scripts[0].path), encoding: .utf8)
        #expect(text.hasPrefix("// JavaScript on document open") && text.contains("app.alert"))
        #expect(throws: (any Error).self) {
            try Dump.payloads(path: repoRoot.appendingPathComponent("testdata/safety/carries-scripts.pdf").path,
                              folder: out, attachments: false, scripts: true)
        }
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
}
