import Foundation
import Testing

@testable import pdf

/// `--dry-run` on `pick`, `transcribe` and `rm` (plan/ROADMAP.md → M2.18): it says what the real run
/// would do, with its keys and its exit code, and changes nothing in the cache or the agent's
/// folder. The tests run the built `pdf` with a fresh home, as an agent would.
@Suite(.serialized) struct DryRunTests {
    static let root = OutputContractTests.root
    static let unsure = root.appendingPathComponent("testdata/smoke/arxiv-2609.23257.pdf").path
    static let regions = root.appendingPathComponent("testdata/safety/hidden-figure-alt.pdf").path

    static func pdf(_ arguments: [String], home: URL, stdin: String = "") throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home, stdin: stdin)
    }

    /// Every file under the home, by path, with its bytes: a database's header and log too, and
    /// its `user_version`, which `sqlite3 -readonly` reads without touching the files. Only a
    /// shared-memory index (`-shm`) is compared by its size: SQLite's readers keep their marks in it.
    static func snapshot(_ home: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            let name = url.lastPathComponent
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            var content = Data()
            if name.hasSuffix("-shm") {
                content = Data("\((try? Data(contentsOf: url))?.count ?? 0) bytes".utf8)
            } else if !directory {
                content = (try? Data(contentsOf: url)) ?? Data()
            }
            if name.hasSuffix(".sqlite") { content.append(Data(userVersion(url).utf8)) }
            found[String(url.path.dropFirst(home.path.count)) + (directory ? "/" : "")] = content
        }
        return found
    }

    static func userVersion(_ database: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", database.path, "PRAGMA user_version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func sqlite(_ database: URL, _ statement: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, statement]
        try process.run()
        process.waitUntilExit()
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
        // Under load a runner can be quiet for 1.5 s and still alive: wait for the home's processes to go.
        for _ in 0..<120 where ReparseTests.running(home.path) { try await Task.sleep(nanoseconds: 500_000_000) }
    }

    /// The keys of a dry run's object are the real run's, and the dry-run keys.
    static func expectSameKeys(_ dry: [String: Any]?, _ real: [String: Any]?, extra: Set<String>, _ label: String) {
        let dryKeys = Set(dry?.keys.map { $0 } ?? [])
        let realKeys = Set(real?.keys.map { $0 } ?? [])
        #expect(dry?["dryRun"] as? Bool == true, "\(label): no dryRun")
        #expect(realKeys.isSubset(of: dryKeys), "\(label): the dry run lacks \(realKeys.subtracting(dryKeys))")
        #expect(dryKeys.subtracting(realKeys).subtracting(["dryRun"]).isSubset(of: extra), "\(label): extra keys \(dryKeys.subtracting(realKeys))")
        #expect(real?["dryRun"] == nil, "\(label): the real run says dryRun")
        for key in realKeys {
            #expect("\(real?[key] ?? "")" == "\(dry?[key] ?? "")", "\(label): \(key) differs")
        }
    }

    @Test func pickDryRunSaysWhatItWouldKeepAndKeepsNothing() async throws {
        let home = try OutputContractTests.freshHome()
        let file = Self.unsure
        // A long page limit: under the load of a parallel suite, page 3 can pass the default 30 s.
        _ = try ReparseTests.pdf(["read", file, "--page", "3", "--budget", "all"], home: home, environment: ["PDF_CLI_PAGE_TIME_LIMIT": "180"])
        try await Self.settle(home)
        let before = Self.snapshot(home)
        let dry = try Self.pdf(["pick", file, "p3.5", "b", "--dry-run"], home: home)
        #expect(dry.status == 0)
        #expect(dry.output.hasPrefix("dry run: would pick b for p.3 ¶5: "), "\(dry.output)")
        let dryJSON = try Self.pdf(["pick", file, "p3.5", "b", "--dry-run", "--json"], home: home)
        #expect(Self.snapshot(home) == before, "a dry pick changed the cache or the library")
        let real = try Self.pdf(["pick", file, "p3.5", "b", "--json"], home: home)
        #expect(real.status == 0)
        #expect(Self.snapshot(home) != before)
        Self.expectSameKeys(dryJSON.json, real.json, extra: ["replaces"], "pick")
        // A second pick would replace the first, and the dry run says which.
        let again = try Self.pdf(["pick", file, "p3.5", "a", "--dry-run", "--json"], home: home)
        #expect(again.json?["replaces"] as? String == "b", "\(again.output)")
        let same = try Self.pdf(["pick", file, "p3.5", "b", "--dry-run"], home: home)
        #expect(same.output.contains("(already picked b)"), "\(same.output)")
        #expect(dryJSON.json?["replaces"] is NSNull, "replaces is null when nothing is picked: \(dryJSON.output)")
        // A miss ends the same way as the real run.
        for json in [[], ["--json"]] {
            let miss = try Self.pdf(["pick", file, "p3.1", "a"] + json, home: home)
            let dryMiss = try Self.pdf(["pick", file, "p3.1", "a", "--dry-run"] + json, home: home)
            #expect(miss.status == 1 && dryMiss.status == 1)
            #expect(miss.output == dryMiss.output, "\(dryMiss.output)")
        }
        // The same wrong flag value is the parser's.
        #expect(try Self.pdf(["pick", file, "p3.5", "c", "--dry-run"], home: home).status == 64)
    }

    /// A pick that no longer applies (the page offers other words) is no earlier pick: `read` shows the
    /// page unpicked, and neither the dry run nor the real pick replaces it: it stays stored
    /// (M2.23 review, L4; M2.24 review, M1).
    @Test func pickDryRunIgnoresAPickThatNoLongerApplies() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try ReparseTests.copy(ReparseTests.paper, to: home)
        let blocks = try ReparseTests.unsureBlocks(file, home: home)
        try await Self.settle(home)
        let first = try #require(blocks.first, "no unsure paragraph")
        let address = "p\(first.page).\(first.block)"
        #expect(try Self.pdf(["pick", file, address, "b"], home: home).status == 0)
        let applies = try Self.pdf(["pick", file, address, "a", "--dry-run", "--json"], home: home)
        #expect(applies.json?["replaces"] as? String == "b", "\(applies.output)")
        try ReparseTests.picksDB(home, "UPDATE pick SET reading_a = 'planted words'")
        let stale = try Self.pdf(["pick", file, address, "a", "--dry-run", "--json"], home: home)
        #expect(stale.json?["replaces"] is NSNull, "\(stale.output)")
        // The real pick does not replace it either: a stale pick stays stored (M2.24 review, M1).
        #expect(try Self.pdf(["pick", file, address, "a"], home: home).status == 0)
        #expect(try ReparseTests.picksDB(home, "SELECT count(*) FROM pick") == "2")
        #expect(try ReparseTests.picksDB(home, "SELECT count(*) FROM pick WHERE reading_a = 'planted words'") == "1")
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
        #expect(dryJSON.json?["characters"] as? Int == 11 && dryJSON.json?["replaces"] is NSNull)
        #expect(Self.snapshot(home) == before, "a dry transcribe changed the cache or the library")
        let real = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--json"], home: home, stdin: latex)
        #expect(real.status == 0)
        Self.expectSameKeys(dryJSON.json, real.json, extra: ["replaces", "characters"], "transcribe")
        // Kept now: a dry run replaces it, and a dry clear removes it, each changing nothing.
        let kept = Self.snapshot(home)
        let replace = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1", "--dry-run", "--json"], home: home, stdin: "x\n")
        #expect((replace.json?["replaces"] as? String)?.count == 10, "the day of the reading it replaces: \(replace.output)")
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
            ["pick", Self.unsure, "p3.5", "a", "--dry-run"],
            ["transcribe", Self.regions, "--page", "2", "--equation", "1", "--dry-run"],
            ["transcribe", Self.regions, "--page", "2", "--equation", "1", "--clear", "--dry-run"],
            ["rm", Self.regions, "--dry-run"],
        ]
        for arguments in runs {
            let run = try Self.pdf(arguments, home: home, stdin: "x\n")
            #expect(run.status == 1, "pdf \(arguments.joined(separator: " ")): \(run.output)")
            #expect(Self.snapshot(home).isEmpty, "pdf \(arguments.joined(separator: " ")) created \(Self.snapshot(home).keys)")
        }
        #expect(try Self.pdf(["pick", Self.unsure, "p3.5", "a", "--dry-run"], home: home).output.contains("not in the cache yet"))
    }

    @Test func aDryRunOnAnOlderCacheLeavesItAndSaysSo() async throws {
        let home = try OutputContractTests.freshHome()
        let file = Self.regions
        _ = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        try await Self.settle(home)
        let cache = home.appendingPathComponent("Caches/cache.sqlite")
        try Self.sqlite(cache, "PRAGMA user_version=7")
        let before = Self.snapshot(home)
        #expect(Self.userVersion(cache).hasPrefix("7"))
        let runs: [[String]] = [
            ["pick", Self.regions, "p2.1", "a", "--dry-run"],
            ["transcribe", file, "--page", "2", "--equation", "1", "--dry-run"],
            ["transcribe", file, "--page", "2", "--equation", "1", "--clear", "--dry-run"],
            ["rm", file, "--dry-run"],
        ]
        for arguments in runs {
            let run = try Self.pdf(arguments, home: home, stdin: "x\n")
            #expect(run.status == 1 && run.output.contains("older version of pdf"), "pdf \(arguments.joined(separator: " ")): \(run.output)")
        }
        #expect(Self.snapshot(home) == before, "a dry run changed the older cache")
        #expect(Self.userVersion(cache).hasPrefix("7"))
    }

    @Test func aMissingFileIsNoSuchFileEvenWithNoCache() throws {
        let home = try OutputContractTests.freshHome()
        let missing = OutputContractTests.missing
        for arguments in [["pick", missing, "p1.1", "a"], ["transcribe", missing, "--page", "1", "--equation", "1"]] {
            let real = try Self.pdf(arguments, home: try OutputContractTests.freshHome(), stdin: "x\n")
            let dry = try Self.pdf(arguments + ["--dry-run"], home: home, stdin: "x\n")
            #expect(dry.status == 1 && dry.output == real.output && dry.output.contains("no such file"), "\(dry.output)")
        }
        #expect(Self.snapshot(home).isEmpty)
    }

    @Test func aFileChangedSinceItWasReadIsNamedAsSuch() async throws {
        let home = try OutputContractTests.freshHome()
        let copy = home.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(atPath: Self.regions, toPath: copy.path)
        _ = try Self.pdf(["read", copy.path, "--page", "2", "--budget", "all"], home: home)
        try await Self.settle(home)
        var bytes = try Data(contentsOf: copy)
        bytes.append(Data("\n% touched\n".utf8))
        try bytes.write(to: copy)
        let run = try Self.pdf(["transcribe", copy.path, "--page", "2", "--equation", "1", "--dry-run"], home: home, stdin: "x\n")
        #expect(run.status == 1 && run.output.contains("changed since it was read"), "\(run.output)")
        // A file never read: no page in the advice, as the file's page count is unknown.
        let fresh = try Self.pdf(["pick", Self.unsure, "p99.1", "a", "--dry-run"], home: home)
        #expect(fresh.status == 1 && fresh.output.contains("not in the cache yet") && !fresh.output.contains("--page 99"), "\(fresh.output)")
    }

    @Test func rmDryRunOfAFileOnlyTheCacheKnowsCountsItsDocument() async throws {
        let home = try OutputContractTests.freshHome()
        let copy = home.appendingPathComponent("copy.pdf").path
        try FileManager.default.copyItem(atPath: Self.regions, toPath: copy)
        for path in [Self.regions, copy] { _ = try Self.pdf(["read", path, "--page", "2", "--budget", "all"], home: home) }
        _ = try Self.pdf(["transcribe", Self.regions, "--page", "2", "--equation", "1"], home: home, stdin: "x\n")
        try await Self.settle(home)
        // The copy leaves the library list, but the cache still knows it.
        try Self.sqlite(home.appendingPathComponent("Support/library.sqlite"), "DELETE FROM library_entry WHERE path LIKE '%copy.pdf'")
        let before = Self.snapshot(home)
        let dry = try Self.pdf(["rm", copy, "--dry-run", "--json"], home: home)
        #expect(Self.snapshot(home) == before)
        #expect(dry.status == 0 && dry.json?["transcriptsKept"] as? Int == 1 && (dry.json?["sharedWith"] as? [String])?.count == 1, "\(dry.output)")
        let real = try Self.pdf(["rm", copy, "--json"], home: home)
        #expect(real.json?["cachedPages"] as? Int == dry.json?["cachedPages"] as? Int)
    }

    @Test func aCacheWithItsLogFilesGoneIsNamedNotRawSQLite() async throws {
        let home = try OutputContractTests.freshHome()
        _ = try Self.pdf(["read", Self.regions, "--page", "2", "--budget", "all"], home: home)
        try await Self.settle(home)
        let caches = home.appendingPathComponent("Caches")
        try Self.sqlite(caches.appendingPathComponent("cache.sqlite"), "PRAGMA wal_checkpoint(TRUNCATE)")
        for name in ["cache.sqlite-wal", "cache.sqlite-shm"] { try? FileManager.default.removeItem(at: caches.appendingPathComponent(name)) }
        let before = Self.snapshot(home)
        let run = try Self.pdf(["rm", Self.regions, "--dry-run"], home: home)
        #expect(run.status == 1 && run.output.contains("log files are gone") && !run.output.contains("SQLite error"), "\(run.output)")
        #expect(Self.snapshot(home) == before)
    }
}
