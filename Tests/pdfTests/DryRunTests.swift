import Foundation
import Testing

@testable import pdf

/// `--dry-run` on `pick`, `transcribe` and `rm` (ROADMAP.md → M2.18): it says what the real run
/// would do, with its keys and its exit code, and changes nothing in the cache or the agent's
/// folder. The tests run the built `pdf` with a fresh home, as an agent would.
@Suite(.serialized) struct DryRunTests {
    static let root = OutputContractTests.root
    static let unsure = root.appendingPathComponent("testdata/smoke/arxiv-2609.23257.pdf").path
    static let regions = root.appendingPathComponent("testdata/safety/hidden-figure-alt.pdf").path

    static func pdf(_ arguments: [String], home: URL, stdin: String = "") throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home, stdin: stdin)
    }

    /// Every file under the home, by path, with its bytes. A database is compared by what it
    /// holds (`sqlite3 .dump`, which reads the write-ahead log too), and its log and index
    /// files are left out: opening a database folds its log in, which changes no row.
    static func snapshot(_ home: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") { continue }
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            var content = Data()
            if name.hasSuffix(".sqlite") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = [url.path, ".dump"]
                let pipe = Pipe()
                process.standardOutput = pipe
                try? process.run()
                content = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
            } else if !directory {
                content = (try? Data(contentsOf: url)) ?? Data()
            }
            found[String(url.path.dropFirst(home.path.count)) + (directory ? "/" : "")] = content
        }
        return found
    }

    /// Waits until a runner that a read left behind has stopped writing,.
    static func settle(_ home: URL) async throws {
        var last = snapshot(home)
        var steady = 0
        for _ in 0..<120 where steady < 3 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let now = snapshot(home)
            steady = now == last ? steady + 1 : 0
            last = now
        }
    }

    /// The keys of a dry run's object are the real run's, and the dry-run keys.
    static func expectSameKeys(_ dry: [String: Any]?, _ real: [String: Any]?, extra: Set<String>, _ label: String) {
        let dryKeys = Set(dry?.keys.map { $0 } ?? [])
        let realKeys = Set(real?.keys.map { $0 } ?? [])
        #expect(dry?["dryRun"] as? Bool == true, "\(label): no dryRun")
        #expect(realKeys.isSubset(of: dryKeys), "\(label): the dry run lacks \(realKeys.subtracting(dryKeys))")
        #expect(dryKeys.subtracting(realKeys).subtracting(["dryRun"]).isSubset(of: extra), "\(label): extra keys \(dryKeys.subtracting(realKeys))")
        #expect(real?["dryRun"] == nil, "\(label): the real run says dryRun")
        for key in realKeys where !["kept"].isEmpty {
            #expect("\(real?[key] ?? "")" == "\(dry?[key] ?? "")", "\(label): \(key) differs")
        }
    }

    @Test func pickDryRunSaysWhatItWouldKeepAndKeepsNothing() async throws {
        let home = try OutputContractTests.freshHome()
        let file = Self.unsure
        _ = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        try await Self.settle(home)
        let before = Self.snapshot(home)
        let dry = try Self.pdf(["pick", file, "p2.2", "b", "--dry-run"], home: home)
        #expect(dry.status == 0)
        #expect(dry.output.hasPrefix("dry run: would pick b for p.2 ¶2: "), "\(dry.output)")
        let dryJSON = try Self.pdf(["pick", file, "p2.2", "b", "--dry-run", "--json"], home: home)
        #expect(Self.snapshot(home) == before, "a dry pick changed the cache or the library")
        let real = try Self.pdf(["pick", file, "p2.2", "b", "--json"], home: home)
        #expect(real.status == 0)
        #expect(Self.snapshot(home) != before)
        Self.expectSameKeys(dryJSON.json, real.json, extra: ["replaces"], "pick")
        // A second pick would replace the first, and the dry run says which.
        let again = try Self.pdf(["pick", file, "p2.2", "a", "--dry-run", "--json"], home: home)
        #expect(again.json?["replaces"] as? String == "b", "\(again.output)")
        // A miss ends the same way as the real run.
        for json in [[], ["--json"]] {
            let miss = try Self.pdf(["pick", file, "p2.1", "a"] + json, home: home)
            let dryMiss = try Self.pdf(["pick", file, "p2.1", "a", "--dry-run"] + json, home: home)
            #expect(miss.status == 1 && dryMiss.status == 1)
            #expect(miss.output == dryMiss.output, "\(dryMiss.output)")
        }
        // The same wrong flag value is the parser's.
        #expect(try Self.pdf(["pick", file, "p2.2", "c", "--dry-run"], home: home).status == 64)
    }

    @Test func transcribeDryRunSaysKeptReplacedOrRemovedAndChangesNothing() async throws {
        let home = try OutputContractTests.freshHome()
        let file = Self.regions
        _ = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        try await Self.settle(home)
        let latex = "$$E = m c^{2}$$\n"
        let before = Self.snapshot(home)
        let dry = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--dry-run"], home: home, stdin: latex)
        #expect(dry.status == 0)
        #expect(dry.output.hasPrefix("dry run: would keep the LaTeX of equation 1 on p.2, 11 characters, with none kept now"), "\(dry.output)")
        let dryJSON = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--dry-run", "--json"], home: home, stdin: latex)
        #expect(dryJSON.json?["characters"] as? Int == 11 && dryJSON.json?["replaces"] as? Bool == false)
        #expect(Self.snapshot(home) == before, "a dry transcribe changed the cache or the library")
        let real = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--json"], home: home, stdin: latex)
        #expect(real.status == 0)
        Self.expectSameKeys(dryJSON.json, real.json, extra: ["replaces", "characters"], "transcribe")
        // Kept now: a dry run replaces it, and a dry clear removes it, each changing nothing.
        let kept = Self.snapshot(home)
        let replace = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--dry-run", "--json"], home: home, stdin: "x\n")
        #expect(replace.json?["replaces"] as? Bool == true)
        let clearDry = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--clear", "--dry-run", "--json"], home: home)
        let clearText = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--clear", "--dry-run"], home: home)
        #expect(clearDry.json?["removed"] as? Bool == true && clearDry.json?["dryRun"] as? Bool == true, "\(clearDry.output)")
        #expect(clearText.output.hasPrefix("dry run: would remove the LaTeX kept for equation 1 on p.2"), "\(clearText.output)")
        #expect(Self.snapshot(home) == kept, "a dry run changed what is kept")
        let clear = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--clear", "--json"], home: home)
        #expect(clear.json?["removed"] as? Bool == true)
        Self.expectSameKeys(clearDry.json, clear.json, extra: [], "transcribe --clear")
        let nothing = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--clear", "--dry-run", "--json"], home: home)
        #expect(nothing.json?["removed"] as? Bool == false)
        // The failures end as the real run's do: no such equation, no text, text too long.
        let cases: [(args: [String], stdin: String)] = [
            (["--page", "2", "--equation", "9"], "x\n"), (["--page", "2", "--equation", "1"], ""),
            (["--page", "99", "--equation", "1"], "x\n"), (["--page", "2", "--equation", "1"], String(repeating: "x", count: 4_001)),
        ]
        for item in cases {
            let miss = try Self.pdf(["transcribe", file] + item.args + ["--json"], home: home, stdin: item.stdin)
            let dryMiss = try Self.pdf(["transcribe", file] + item.args + ["--dry-run", "--json"], home: home, stdin: item.stdin)
            #expect(miss.status == 1 && dryMiss.status == 1, "\(item.args): \(miss.status) \(dryMiss.status)")
            #expect(miss.output == dryMiss.output, "\(dryMiss.output)")
        }
    }

    @Test func rmDryRunSaysWhatGoesAndWhatStaysAndRemovesNothing() async throws {
        let home = try OutputContractTests.freshHome()
        let copy = home.appendingPathComponent("copy.pdf").path
        let file = Self.regions
        try FileManager.default.copyItem(atPath: file, toPath: copy)
        for path in [file, copy] { _ = try Self.pdf(["read", path, "--page", "2", "--budget", "all"], home: home) }
        _ = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1"], home: home, stdin: "x\n")
        try await Self.settle(home)
        // The copy shares every page with the file: removing one leaves the results.
        let shared = try Self.pdf(["rm", copy, "--dry-run", "--json"], home: home)
        #expect(shared.json?["cachedPages"] as? Int == 0, "\(shared.output)")
        #expect((shared.json?["sharedWith"] as? [String])?.count == 1 && shared.json?["transcriptsKept"] as? Int == 1, "\(shared.output)")
        let text = try Self.pdf(["rm", copy, "--dry-run"], home: home)
        #expect(text.output.hasPrefix("dry run: would remove "), "\(text.output)")
        let before = Self.snapshot(home)
        let dry = try Self.pdf(["rm", file, "--dry-run", "--json"], home: home)
        #expect(Self.snapshot(home) == before, "a dry rm changed the cache or the library")
        #expect(dry.status == 0)
        let real = try Self.pdf(["rm", file, "--json"], home: home)
        Self.expectSameKeys(dry.json, real.json, extra: ["picksKept", "transcriptsKept", "sharedWith"], "rm")
        // The second copy is alone now: its pages go with it, the transcript stays.
        let alone = try Self.pdf(["rm", copy, "--dry-run", "--json"], home: home)
        #expect((alone.json?["cachedPages"] as? Int ?? 0) > 0 && (alone.json?["sharedWith"] as? [String])?.isEmpty == true, "\(alone.output)")
        #expect(alone.json?["transcriptsKept"] as? Int == 1)
        let gone = try Self.pdf(["rm", copy, "--json"], home: home)
        #expect(gone.json?["cachedPages"] as? Int == alone.json?["cachedPages"] as? Int)
        // A miss, the same failure and exit code.
        for json in [[], ["--json"]] {
            let miss = try Self.pdf(["rm", "no-such-thing"] + json, home: home)
            let dryMiss = try Self.pdf(["rm", "no-such-thing", "--dry-run"] + json, home: home)
            #expect(miss.status == 1 && dryMiss.status == 1 && miss.output == dryMiss.output, "\(dryMiss.output)")
        }
    }

    @Test func aDryRunOnAnEmptyHomeCreatesNothing() throws {
        let home = try OutputContractTests.freshHome()
        let runs: [[String]] = [
            ["pick", Self.unsure, "p2.2", "a", "--dry-run"],
            ["transcribe", Self.regions, "--page", "2", "--equation", "1", "--dry-run"],
            ["transcribe", Self.regions, "--page", "2", "--equation", "1", "--clear", "--dry-run"],
            ["rm", Self.regions, "--dry-run"],
        ]
        for arguments in runs {
            let run = try Self.pdf(arguments, home: home, stdin: "x\n")
            #expect(run.status == 1, "pdf \(arguments.joined(separator: " ")): \(run.output)")
            #expect(Self.snapshot(home).isEmpty, "pdf \(arguments.joined(separator: " ")) created \(Self.snapshot(home).keys)")
        }
        #expect(try Self.pdf(["pick", Self.unsure, "p2.2", "a", "--dry-run"], home: home).output.contains("is not in the cache yet"))
    }
}
