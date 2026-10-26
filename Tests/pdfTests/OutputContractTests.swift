import Foundation
import Testing

@testable import pdf

/// Every command against the output contract (FEATURES.md → F7 and F8; DESIGNS.md → Decision: one
/// output contract for every command): each takes `--json` and prints JSON; a failure has one
/// shape; the exit codes are 1 for a file that is not there, 3 for one that is no PDF, 64 for a
/// wrong flag. The tests run the built `pdf`, as an agent would, each with a fresh home.
@Suite(.serialized) struct OutputContractTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixture = root.appendingPathComponent("testdata/safety/carries-comments.pdf").path
    static let notAPDF = root.appendingPathComponent("testdata/safety/broken-not-a-pdf.pdf").path
    static let missing = "/nonexistent/m2-15-missing.pdf"

    /// The built `pdf`; `swift test` builds it beside the tests.
    static var binary: URL? {
        ["debug", "release"].map { root.appendingPathComponent(".build/\($0)/pdf") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    struct Run {
        var status: Int32
        var output: String
        var errors = ""
        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        }
    }

    /// Runs `pdf` with these arguments, a fresh `PDF_CLI_HOME`, and `stdin` on standard input.
    static func pdf(_ arguments: [String], home: URL, stdin: String = "", config: URL? = nil) throws -> Run {
        let process = Process()
        process.executableURL = try #require(binary, "build the pdf product first: swift build")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PDF_CLI_HOME"] = home.path
        if let config { environment["CLAUDE_CONFIG_DIR"] = config.path }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
            errors: String(decoding: errorData, as: UTF8.self))
    }

    static func freshHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// The commands that take a path, each as its arguments after `pdf <name>` with the file in
    /// place of `$`, and what it reads from standard input.
    static let withPath: [(name: String, arguments: [String], stdin: String)] = [
        ("info", ["$"], ""), ("read", ["$"], ""), ("search", ["$", "word"], ""), ("crop", ["$", "--page", "1"], ""),
        ("dump", ["$", "--text"], ""), ("pick", ["$", "p1.1", "a"], ""),
        ("transcribe", ["$", "--page", "1", "--equation", "1"], "x\n"), ("add", ["$"], ""),
        ("note", ["$", "1"], ""), ("ref", ["$", "1"], ""), ("reparse", ["$"], ""),
    ]

    @Test func everyCommandPrintsJSONUnderDashDashJSON() throws {
        let home = try Self.freshHome()
        let config = home.appendingPathComponent("config")
        let folder = home.appendingPathComponent("dump").path
        let file = Self.fixture
        // Each command with the exit codes it may end with on this file, and a key its object holds.
        let commands: [(arguments: [String], codes: Set<Int32>, key: String)] = [
            (["add", file], [0, 2], "files"), (["reparse", file], [0, 2], "reparsed"), (["ls"], [0], "documents"),
            (["info", file], [0, 2], "pageCount"),
            (["read", file], [0, 2], "blocks"), (["search", file, "words"], [0], "hits"), (["search", "words"], [0], "hits"),
            (["crop", file, "--page", "1"], [0], "image"), (["dump", file, "--markdown", "-o", folder], [0, 2], "written"),
            // These two fail on this file (it has no unsure words and no equation): the failure is the JSON.
            (["pick", file, "p1.1", "a"], [1], "failed"), (["transcribe", file, "--page", "1", "--equation", "1"], [1], "failed"),
            (["note", file, "1"], [1], "failed"), (["ref", file, "1"], [1], "failed"),
            (["agent-guide"], [0], "guide"), (["agent-guide", "--install", "claude-code"], [0], "installed"),
            (["rm", file], [0], "title"), (["clean"], [0], "clean"), (["doctor"], [0, 2], "cache"),
            (["setup"], [0], "workers"), (["setup", "--memory", "balanced"], [0], "memoryMB"),
        ]
        for command in commands {
            let run = try Self.pdf(command.arguments + ["--json"], home: home, stdin: "x\n", config: config)
            let name = command.arguments.prefix { !$0.hasPrefix("/") }.joined(separator: " ")
            #expect(command.codes.contains(run.status), "pdf \(name) --json ended with \(run.status): \(run.output.prefix(200))")
            let object = run.json
            #expect(object != nil, "pdf \(name) --json printed no JSON object: \(run.output.prefix(200))")
            #expect(object?[command.key] != nil, "pdf \(name) --json has no \(command.key): \(run.output.prefix(200))")
        }
    }

    @Test func aFailureHasOneShapeAndTheExitCodesOfTheTable() throws {
        let home = try Self.freshHome()
        for command in Self.withPath {
            for json in [false, true] {
                for (file, code, reason) in [(Self.missing, Int32(1), "no such file"), (Self.notAPDF, Int32(3), "not a PDF")] {
                    let arguments = [command.name] + command.arguments.map { $0 == "$" ? file : $0 } + (json ? ["--json"] : [])
                    let run = try Self.pdf(arguments, home: home, stdin: command.stdin)
                    let label = "pdf " + arguments.joined(separator: " ")
                    #expect(run.status == code, "\(label) ended with \(run.status), not \(code): \(run.output.prefix(200))")
                    if json {
                        let object = run.json
                        // `add` lists its failures in "files"; the others print the failure itself.
                        let failure = command.name == "add" ? (object?["files"] as? [[String: Any]])?.first : object
                        #expect(failure?["file"] as? String == file, "\(label): \(run.output.prefix(200))")
                        #expect((failure?["failed"] as? String)?.hasPrefix(reason) == true, "\(label): \(run.output.prefix(200))")
                    } else {
                        #expect(run.output.hasPrefix("\(file): failed: \(reason)"), "\(label): \(run.output.prefix(200))")
                    }
                }
                // A wrong flag is the parser's own: 64.
                let wrong = try Self.pdf([command.name] + command.arguments.map { $0 == "$" ? Self.fixture : $0 } + ["--no-such-flag"], home: home)
                #expect(wrong.status == 64, "pdf \(command.name) --no-such-flag ended with \(wrong.status)")
            }
        }
        // The library commands: an unknown PDF is not there (1), a wrong flag is 64.
        let removed = try Self.pdf(["rm", Self.missing, "--json"], home: home)
        #expect(removed.status == 1 && removed.json?["failed"] != nil && removed.json?["file"] as? String == Self.missing)
        for name in ["ls", "rm", "doctor", "clean", "setup", "agent-guide"] {
            #expect(try Self.pdf([name, "--no-such-flag"], home: home).status == 64, "pdf \(name) --no-such-flag")
        }
    }

    /// A look-up that matches nothing is a run-time failure in the one shape, exit 1, with the
    /// reason on standard output, not a usage error (M2.15's review, M4).
    @Test func aLookUpThatMatchesNothingFailsInTheOneShape() throws {
        let home = try Self.freshHome()
        let file = Self.fixture
        let misses: [(arguments: [String], reason: String)] = [
            (["note", file, "99"], "no footnote or endnote is 99"), (["ref", file, "99"], "no entry of the reference list is 99"),
            (["read", file, "--section", "Nonesuch"], "no section matches Nonesuch"),
            (["read", file, "--printed-page", "zz"], "no page is printed zz"),
        ]
        for miss in misses {
            let label = "pdf " + miss.arguments.joined(separator: " ")
            let plain = try Self.pdf(miss.arguments, home: home)
            #expect(plain.status == 1, "\(label) ended with \(plain.status): \(plain.output.prefix(200))")
            #expect(plain.output.hasPrefix("\(file): failed: \(miss.reason)"), "\(label): \(plain.output.prefix(200))")
            let json = try Self.pdf(miss.arguments + ["--json"], home: home)
            #expect(json.status == 1, "\(label) --json ended with \(json.status)")
            #expect(json.json?["file"] as? String == file, "\(label) --json: \(json.output.prefix(200))")
            #expect((json.json?["failed"] as? String)?.hasPrefix(miss.reason) == true, "\(label) --json: \(json.output.prefix(200))")
        }
        // An empty id is a wrong use: 64.
        #expect(try Self.pdf(["note", file, ""], home: home).status == 64)
        #expect(try Self.pdf(["ref", file, " "], home: home).status == 64)
        // The old flags are gone; hidden, they point to the new commands and run nothing.
        #expect(try Self.pdf(["read", file, "--footnote", "1"], home: home).status == 64)
        #expect(try Self.pdf(["read", file, "--ref", "1"], home: home).status == 64)
    }

    /// `--show` takes raw, hidden and headers, as a comma list or repeated; the three flags it
    /// took over end 64 with a pointer and run nothing (M2.17).
    @Test func showTakesTheThreeValuesAndTheOldFlagsPointToIt() throws {
        #expect(ReadCommand.shown([]) == [])
        #expect(ReadCommand.shown(["raw"]) == ["raw"])
        #expect(ReadCommand.shown(["hidden"]) == ["hidden"])
        #expect(ReadCommand.shown(["headers"]) == ["headers"])
        #expect(ReadCommand.shown(["raw,hidden"]) == ["raw", "hidden"])
        #expect(ReadCommand.shown(["raw", "headers,hidden"]) == ["raw", "hidden", "headers"])
        #expect(ReadCommand.shown(["raw,"]) == nil && ReadCommand.shown(["all"]) == nil && ReadCommand.shown(["Raw"]) == nil)
        let home = try Self.freshHome()
        let file = Self.fixture
        let unknown = try Self.pdf(["read", file, "--show", "Hidden"], home: home)
        #expect(unknown.status == 64 && unknown.errors.contains("--show: 'Hidden' is not raw, hidden or headers"), "\(unknown.errors.prefix(200))")
        for (old, new) in [("--raw", "--show raw"), ("--include-hidden", "--show hidden"), ("--headers", "--show headers")] {
            let run = try Self.pdf(["read", file, old], home: home)
            #expect(run.status == 64 && run.errors.contains("`\(old)` is now `\(new)`"), "\(old): \(run.errors.prefix(200))")
        }
        // Only hidden shows hidden words, however --show is spelled (hidden-color.pdf has one hidden run).
        let hidden = Self.root.appendingPathComponent("testdata/safety/hidden-color.pdf").path
        for (shows, expected) in [
            (["hidden"], true), (["raw", "--show", "hidden"], true), (["hidden,raw"], true),
            (["raw,headers"], false), ([], false),
        ] {
            let arguments = ["read", hidden, "--budget", "all"] + (shows.isEmpty ? [] : ["--show"] + shows)
            let run = try Self.pdf(arguments, home: home)
            #expect(run.status == 0 && run.output.contains("[hidden, ") == expected, "\(shows): \(run.output.prefix(300))")
        }
    }

    /// A found note and a found entry, in JSON, on two smoke files (M2.16's review, L6).
    @Test func aFoundNoteAndEntryHaveTheirKeysInJSON() throws {
        let home = try Self.freshHome()
        let smoke = Self.root.appendingPathComponent("testdata/smoke")
        let note = try Self.pdf(["note", smoke.appendingPathComponent("arxiv-2608.04589.pdf").path, "3", "--json"], home: home)
        #expect(note.status == 0, "\(note.output.prefix(200))")
        #expect(Set(note.json.map { Array($0.keys) } ?? []).isSuperset(of: Set(["id", "kind", "page", "text", "references"])), "\(note.output.prefix(200))")
        #expect(note.json?["id"] as? String == "3")
        let entry = try Self.pdf(["ref", smoke.appendingPathComponent("arxiv-2608.26848.pdf").path, "15", "--json"], home: home)
        #expect(entry.status == 0, "\(entry.output.prefix(200))")
        #expect(Set(entry.json.map { Array($0.keys) } ?? []).isSuperset(of: Set(["id", "page", "text", "citations"])), "\(entry.output.prefix(200))")
        #expect(entry.json?["id"] as? String == "15")
    }

    @Test func aFailingInnerReadKeepsItsExitCodeAndReason() throws {
        let home = try Self.freshHome()
        let run = try Self.pdf(["dump", Self.fixture, "--text", "--page", "99", "-o", home.appendingPathComponent("d").path], home: home)
        #expect(run.status == 1, "\(run.status): \(run.output)")
        #expect(run.output.contains("page 99 is out of range"), "\(run.output)")
    }

    @Test func aFoundationErrorIsOneCleanSentence() throws {
        let home = try Self.freshHome()
        let file = home.appendingPathComponent("a-regular-file")
        try Data().write(to: file)
        let run = try Self.pdf(["ls", "--json"], home: file)
        #expect(run.status == 1)
        let reason = run.json?["failed"] as? String
        #expect(reason != nil && !reason!.contains("Error Domain") && !reason!.contains("NSCocoa"), "\(run.output)")
    }

    @Test func aCompactingCleanDoesNotBlameARemovalThatNeverHappened() async throws {
        let home = try Self.freshHome()
        _ = try Self.pdf(["add", Self.fixture], home: home)
        try await DryRunTests.settle(home)
        for _ in 0..<2 {
            let run = try Self.pdf(["clean"], home: home)
            #expect(run.status == 0 && run.output.contains("freed") && !run.output.contains("pdf rm"), "\(run.output)")
        }
    }

    @Test func anEmptyLibraryAnswersInJSON() throws {
        let home = try Self.freshHome()
        #expect(((try Self.pdf(["ls", "--json"], home: home)).json?["documents"] as? [Any])?.isEmpty == true)
        let search = try Self.pdf(["search", "words", "--json"], home: home)
        #expect(search.status == 0 && (search.json?["hits"] as? [Any])?.isEmpty == true, "\(search.output)")
    }

    /// A folder that cannot be written ends 1; a file that cannot be read ends 3.
    @Test func aFolderFailureIsOneAndAFileFailureIsThree() throws {
        let home = try Self.freshHome()
        let target = home.appendingPathComponent("target")
        let link = home.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let folder = try Self.pdf(["dump", Self.fixture, "--markdown", "-o", link.path, "--json"], home: home)
        #expect(folder.status == 1 && folder.json?["failed"] != nil, "\(folder.status): \(folder.output)")
        let file = try Self.pdf(["dump", Self.notAPDF, "--markdown", "-o", link.path, "--json"], home: home)
        #expect(file.status == 3, "\(file.status): \(file.output)")
    }

    /// A link where the figures folder should be is refused, and nothing is written through it.
    @Test func aLinkInPlaceOfTheFiguresFolderIsRefused() throws {
        let home = try Self.freshHome()
        let out = home.appendingPathComponent("out")
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("figures"), withDestinationURL: elsewhere)
        let paper = Self.root.appendingPathComponent("testdata/smoke/arxiv-2608.16011.pdf").path
        let run = try Self.pdf(["dump", paper, "--figures", "-o", out.path, "--json"], home: home)
        #expect(run.status == 1, "\(run.status): \(run.output.prefix(300))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
