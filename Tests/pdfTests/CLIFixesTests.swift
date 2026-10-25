import Foundation
import PDFCore
import PDFKit
import Testing

@testable import pdf

/// The small command-layer fixes of M2.20: exit codes and hints for a locked file, the order of
/// `pdf transcribe`'s checks, the JSON of `rm` and `agent-guide --install`, and the folder aliases
/// `/tmp`, `/var` and `/etc`. Each runs the built `pdf` with a fresh home, as an agent would.
@Suite(.serialized) struct CLIFixesTests {
    static let small = ReparseTests.small

    static func pdf(_ arguments: [String], home: URL, stdin: String = "") throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home, stdin: stdin)
    }

    /// A password-locked copy of a small fixture, added to the library with its password.
    static func addedLockedFile(home: URL) throws -> String {
        let locked = home.appendingPathComponent("locked.pdf")
        let source = try #require(PDFDocument(url: URL(fileURLWithPath: small)))
        #expect(source.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        let added = try pdf(["add", locked.path, "--password-stdin"], home: home, stdin: "pw\n")
        #expect(added.status == 0, "\(added.output)")
        return locked.path
    }

    /// L1: a locked file read from the cache ends 3 on `crop` without the password, as on `read`.
    @Test func cropOfACachedLockedFileEndsThreeWithTheHint() throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.addedLockedFile(home: home)
        for json in [false, true] {
            let run = try Self.pdf(["crop", file, "--page", "1"] + (json ? ["--json"] : []), home: home)
            #expect(run.status == 3, "\(run.output)")
            #expect(run.output.contains("locked by a password") && run.output.contains("--password-stdin"), "\(run.output)")
        }
        let opened = try Self.pdf(["crop", file, "--page", "1", "--password-stdin"], home: home, stdin: "pw\n")
        #expect(opened.status == 0, "\(opened.output)")
    }

    /// L2: `dump` of a locked file that was added gives the hint, ends 3 and writes nothing.
    @Test func dumpOfACachedLockedFileHintsThePasswordFlag() throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.addedLockedFile(home: home)
        let folder = home.appendingPathComponent("out").path
        let run = try Self.pdf(["dump", file, "--markdown", "-o", folder], home: home)
        #expect(run.status == 3, "\(run.output)")
        #expect(run.output.contains("--password-stdin") && run.output.contains("pdf dump"), "\(run.output)")
        #expect(!FileManager.default.fileExists(atPath: folder + "/document.md"))
        let opened = try Self.pdf(["dump", file, "--markdown", "-o", folder, "--password-stdin"], home: home, stdin: "pw\n")
        #expect(opened.status == 0 || opened.status == 2, "\(opened.output)")
    }

    /// L3: the file is checked before standard input is read.
    @Test func transcribeReportsAMissingFileBeforeReadingInput() throws {
        let home = try OutputContractTests.freshHome()
        let missing = home.appendingPathComponent("gone.pdf").path
        for dry in [false, true] {
            let run = try Self.pdf(["transcribe", missing, "--page", "1", "--equation", "1"] + (dry ? ["--dry-run"] : []), home: home)
            #expect(run.status == 1, "\(run.output)")
            #expect(run.output == "\(missing): failed: no such file\n", "\(run.output)")
        }
    }

    /// L6: `rm --json` gives `id` and `title`; `agent-guide --install --json` keeps the text's detail.
    @Test func rmAndAgentGuideJSONKeepWhatTheTextSays() throws {
        let home = try OutputContractTests.freshHome()
        _ = try Self.pdf(["add", Self.small], home: home)
        let rm = try Self.pdf(["rm", Self.small, "--json"], home: home)
        #expect(rm.status == 0, "\(rm.output)")
        let id = try #require(rm.json?["id"] as? String, "\(rm.output)")
        #expect(id.count == 8 && rm.json?["removed"] == nil)
        #expect((rm.json?["title"] as? String)?.isEmpty == false && !(rm.json?["title"] as? String ?? "").contains(" · "))

        let config = home.appendingPathComponent("config")
        func install(_ json: Bool) throws -> OutputContractTests.Run {
            try ReparseTests.pdf(
                ["agent-guide", "--install", "claude-code"] + (json ? ["--json"] : []), home: home,
                environment: ["CLAUDE_CONFIG_DIR": config.path, "PATH": "/usr/bin:/bin"])
        }
        let first = try install(true)
        let hint = try #require(first.json?["hint"] as? String, "\(first.output)")
        #expect(hint.contains("/reload-skills"))
        let warning = try #require((first.json?["warnings"] as? [String])?.first, "\(first.output)")
        #expect(warning.contains("no pdf on the PATH") && warning.contains("; this one is "), Comment(rawValue: warning))
        // Installed again, unchanged: no hint, as in the text.
        let again = try install(true)
        #expect(again.json?["hint"] == nil && again.json?["installed"] as? String == "unchanged", "\(again.output)")
    }

    /// L7: `/tmp` and `/private/tmp` name one file whether or not it exists.
    @Test func systemFolderAliasesResolveAlikeWithOrWithoutTheFile() throws {
        #expect(Reader.resolve("/private/tmp/m220-none/x.pdf") == "/tmp/m220-none/x.pdf")
        #expect(Reader.resolve("/tmp/m220-none/x.pdf") == "/tmp/m220-none/x.pdf")
        #expect(Reader.resolve("/private/var/m220-none") == "/var/m220-none")
        #expect(Reader.resolve("/private/etc") == "/etc")
        #expect(Reader.resolve("/private/other/x.pdf") == "/private/other/x.pdf")
        #expect(Reader.resolve("/private/tmpfoo") == "/private/tmpfoo")

        let home = try OutputContractTests.freshHome()
        let folder = "/tmp/pdf-m220-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/x.pdf"
        try FileManager.default.copyItem(atPath: Self.small, toPath: file)
        #expect(try Self.pdf(["add", file], home: home).status == 0)
        try FileManager.default.removeItem(atPath: file)
        let list = try Self.pdf(["ls"], home: home)
        #expect(list.output.contains(" · " + file) && !list.output.contains("/private"), "\(list.output)")
        let dry = try Self.pdf(["rm", "/private" + file, "--dry-run"], home: home)
        #expect(dry.status == 0, "\(dry.output)")
        let rm = try Self.pdf(["rm", "/private" + file], home: home)
        #expect(rm.status == 0 && rm.output.hasPrefix("removed "), "\(rm.output)")
        #expect(try Self.pdf(["ls"], home: home).output.contains("the library is empty"))
    }

    /// L7: `-o /tmp` is the system's alias, not a link the user made; a link elsewhere is still refused.
    @Test func dumpAcceptsSystemAliasesAndRefusesOtherLinks() throws {
        #expect(DumpCommand.canonical(URL(fileURLWithPath: "/tmp", isDirectory: true)).path == "/private/tmp")
        #expect(DumpCommand.canonical(URL(fileURLWithPath: "/tmp/", isDirectory: true)).path == "/private/tmp")
        #expect(DumpCommand.canonical(URL(fileURLWithPath: "/tmp/m220-new", isDirectory: true)).path == "/private/tmp/m220-new")

        let home = try OutputContractTests.freshHome()
        let real = home.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let refused = try Self.pdf(["dump", Self.small, "--text", "-o", link.path], home: home)
        #expect(refused.status == 1 && refused.output.contains("is a link"), "\(refused.output)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)

        let alias = "/tmp/pdf-m220-dump-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: alias) }
        let written = try Self.pdf(["dump", Self.small, "--text", "-o", alias], home: home)
        #expect(written.status == 0 || written.status == 2, "\(written.output)")
        #expect(FileManager.default.fileExists(atPath: alias + "/document.txt"))
    }
}
