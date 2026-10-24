import Foundation
import Testing

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
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
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
    ]

    @Test func everyCommandPrintsJSONUnderDashDashJSON() throws {
        let home = try Self.freshHome()
        let config = home.appendingPathComponent("config")
        let folder = home.appendingPathComponent("dump").path
        let file = Self.fixture
        // Each command with the exit codes it may end with on this file, and a key its object holds.
        let commands: [(arguments: [String], codes: Set<Int32>, key: String)] = [
            (["add", file], [0, 2], "files"), (["ls"], [0], "documents"), (["info", file], [0, 2], "pageCount"),
            (["read", file], [0, 2], "blocks"), (["search", file, "words"], [0], "hits"), (["search", "words"], [0], "hits"),
            (["crop", file, "--page", "1"], [0], "image"), (["dump", file, "--markdown", "-o", folder], [0, 2], "written"),
            // These two fail on this file (it has no unsure words and no equation): the failure is the JSON.
            (["pick", file, "p1.1", "a"], [1], "failed"), (["transcribe", file, "--page", "1", "--equation", "1"], [1], "failed"),
            (["agent-guide"], [0], "guide"), (["agent-guide", "--install", "claude-code"], [0], "installed"),
            (["rm", file], [0], "removed"), (["gc"], [0], "removed"),
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
        for name in ["ls", "rm", "gc", "agent-guide"] {
            #expect(try Self.pdf([name, "--no-such-flag"], home: home).status == 64, "pdf \(name) --no-such-flag")
        }
    }
}
