import Foundation
import PDFCore
import Testing

@testable import pdf

/// `pdf doctor`, `pdf setup` and the `pdf gc` stub (ROADMAP.md → M2.11), run as the built `pdf`
/// with a fresh home, so the user's real settings and cache are never touched.
@Suite(.serialized) struct DoctorSetupTests {
    static func pdf(_ arguments: [String], home: URL, stdin: String = "") throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home, stdin: stdin)
    }

    @Test func doctorShowsItsPartsInTextAndJSON() async throws {
        let home = try OutputContractTests.freshHome()
        _ = try Self.pdf(["add", OutputContractTests.fixture], home: home)
        try await DryRunTests.settle(home)
        let text = try Self.pdf(["doctor"], home: home)
        #expect(text.status == 0, "\(text.output)")
        for part in [
            "macOS ", "pdf parser \(Env.parserVersion)", "models: none installed · none exist yet", "cache: ok", "library: ok · 1 PDF",
            "parsing: memory budget not set (the default)", "running: no runner", "problems: none",
        ] {
            #expect(text.output.contains(part), "no \"\(part)\" in: \(text.output)")
        }
        let json = try #require(try Self.pdf(["doctor", "--json"], home: home).json)
        for key in ["macOS", "parserVersion", "models", "cache", "library", "parsing", "running", "cleanable", "missing", "problems", "fixedByClean"]
        {
            #expect(json[key] != nil, "no \(key)")
        }
        #expect(json["parserVersion"] as? Int == Env.parserVersion && json["clean"] == nil)
        let cache = json["cache"] as? [String: Any]
        #expect(cache?["state"] as? String == "ok" && (cache?["pages"] as? Int ?? 0) > 0)
        let parsing = json["parsing"] as? [String: Any]
        #expect((parsing?["workers"] as? [String: Any])?["source"] as? String == "default")
        #expect(((json["models"] as? [String: Any])?["available"] as? [Any])?.isEmpty == true)
    }

    @Test func doctorWithoutCleanChangesNothing() async throws {
        let home = try OutputContractTests.freshHome()
        _ = try Self.pdf(["add", OutputContractTests.fixture], home: home)
        try await DryRunTests.settle(home)
        let before = DryRunTests.snapshot(home)
        _ = try Self.pdf(["doctor"], home: home)
        _ = try Self.pdf(["doctor", "--json"], home: home)
        #expect(DryRunTests.snapshot(home) == before, "pdf doctor changed a file")
    }

    @Test func aDryCleanChangesNothingAndTheRealCleanRemovesWhatItSaid() async throws {
        let home = try OutputContractTests.freshHome()
        let copy = home.appendingPathComponent("temporary.pdf")
        try FileManager.default.copyItem(atPath: DryRunTests.unsure, toPath: copy.path)
        _ = try Self.pdf(["add", copy.path], home: home)
        try await DryRunTests.settle(home)
        try FileManager.default.removeItem(at: copy)
        let before = DryRunTests.snapshot(home)
        let dry = try Self.pdf(["doctor", "--clean", "--dry-run"], home: home)
        let dryJSON = try Self.pdf(["doctor", "--clean", "--dry-run", "--json"], home: home)
        #expect(dry.status == 0 && dryJSON.status == 0, "\(dry.output)")
        #expect(dry.output.hasPrefix("dry run: would remove 1 file gone or changed, 1 document, "), "\(dry.output)")
        #expect(dry.output.contains("nothing was removed"))
        #expect(DryRunTests.snapshot(home) == before, "a dry clean changed the cache or the library")
        let real = try Self.pdf(["doctor", "--clean", "--json"], home: home)
        #expect(real.status == 0, "\(real.output)")
        let dryClean = try #require(dryJSON.json?["clean"] as? [String: Any])
        let realClean = try #require(real.json?["clean"] as? [String: Any])
        #expect(dryClean["dryRun"] as? Bool == true && realClean["dryRun"] == nil)
        #expect(Set(dryClean.keys).subtracting(["dryRun"]) == Set(realClean.keys))
        #expect("\(dryClean["removed"] ?? "")" == "\(realClean["removed"] ?? "")")
        #expect((realClean["removed"] as? [String: Int])?["libraryEntries"] == 1)
        #expect(DryRunTests.snapshot(home) != before)
        // The text of a real clean keeps the words pdf gc used, with the space it freed.
        let ls = try Self.pdf(["ls", "--json"], home: home)
        #expect((ls.json?["documents"] as? [Any])?.isEmpty == true)
        let text = try Self.pdf(["doctor", "--clean"], home: home)
        #expect(
            text.output.hasPrefix("removed 0 files gone or changed, 0 documents, 0 page results, 0 library entries for files gone"), "\(text.output)")
    }

    @Test func doctorNamesAnOlderCacheAndALeftoverLockAndCleanFixesTheLock() async throws {
        let home = try OutputContractTests.freshHome()
        _ = try Self.pdf(["add", OutputContractTests.fixture], home: home)
        try await DryRunTests.settle(home)
        let database = home.appendingPathComponent("Caches/cache.sqlite")
        try DryRunTests.sqlite(database, "INSERT INTO runner_lock (lock_key, pid, heartbeat_at) VALUES ('path:/x', 999999, 0)")
        let locked = try Self.pdf(["doctor"], home: home)
        #expect(locked.status == 2 && locked.output.contains("problem: 1 runner lock left by runners that are gone"), "\(locked.output)")
        let cleaned = try Self.pdf(["doctor", "--clean"], home: home)
        #expect(cleaned.status == 0 && cleaned.output.contains("1 runner lock left over"), "\(cleaned.output)")
        #expect(try Self.pdf(["doctor"], home: home).status == 0)
        // An older schema: named, exit 2, and a dry clean refuses in the one failure shape.
        try DryRunTests.sqlite(database, "PRAGMA user_version = 3")
        let older = try Self.pdf(["doctor", "--json"], home: home)
        #expect(older.status == 2 && (older.json?["cache"] as? [String: Any])?["state"] as? String == "older schema", "\(older.output)")
        let refused = try Self.pdf(["doctor", "--clean", "--dry-run", "--json"], home: home)
        #expect(refused.status == 1 && refused.json?["file"] as? String == "pdf doctor" && refused.json?["failed"] != nil, "\(refused.output)")
    }

    @Test func aDryRunWithoutCleanIsAUsageError() throws {
        let home = try OutputContractTests.freshHome()
        #expect(try Self.pdf(["doctor", "--dry-run"], home: home).status == 64)
    }

    @Test func gcIsGoneAndPointsToDoctor() throws {
        let home = try OutputContractTests.freshHome()
        for arguments in [["gc"], ["gc", "--json"], ["gc", "--dry-run"]] {
            let run = try Self.pdf(arguments, home: home)
            #expect(run.status == 64 && run.output.isEmpty, "\(arguments): \(run.status) \(run.output)")
            #expect(run.errors.contains("`pdf gc` is now `pdf doctor --clean`"), "\(run.errors)")
        }
        // It runs nothing, and the top-level help does not list it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        #expect(!PDF.helpMessage(for: PDF.self).contains("gc"))
    }

    @Test func eachPresetANumberAndDefaultAreStoredAndShownByDoctor() throws {
        let home = try OutputContractTests.freshHome()
        let cores = Env.performanceCores
        let cases: [(value: String, megabytes: Int?, preset: String?)] = [
            ("light", 2048, "light"), ("balanced", 4096, "balanced"), ("fastest", 8192, "fastest"),
            ("3GB", 3072, nil), ("6144", 6144, nil), ("default", nil, nil),
        ]
        for item in cases {
            let run = try Self.pdf(["setup", "--memory", item.value, "--json"], home: home)
            #expect(run.status == 0, "\(item.value): \(run.output)")
            let json = try #require(run.json, "\(run.output)")
            #expect(json["memoryMB"] as? Int == item.megabytes, "\(item.value)")
            #expect(json["preset"] as? String == item.preset, "\(item.value)")
            let plan = Settings.plan(budgetMB: item.megabytes, performanceCores: cores)
            #expect(json["workers"] as? Int == plan.workers && json["workerLimitMB"] as? Int == plan.workerLimitMB)
            #expect(json["prompted"] as? Bool == false)
            #expect(((json["models"] as? [String: Any])?["available"] as? [Any])?.isEmpty == true)
            // Doctor reads it back through Env: the number, and that setup set it.
            let parsing = try #require(try Self.pdf(["doctor", "--json"], home: home).json?["parsing"] as? [String: Any])
            let budget = parsing["memoryBudgetMB"] as? [String: Any]
            #expect(budget?["value"] as? Int == item.megabytes, "\(item.value): \(parsing)")
            #expect(budget?["source"] as? String == (item.megabytes == nil ? "default" : "setup"))
            #expect((parsing["workers"] as? [String: Any])?["value"] as? Int == plan.workers)
        }
        // "default" removed the file.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Support/settings.json").path))
    }

    @Test func aBadValueEnds64AndStoresNothing() throws {
        let home = try OutputContractTests.freshHome()
        for value in ["banana", "3", "100MB", "-1GB", "0", ""] {
            let run = try Self.pdf(["setup", "--memory", value], home: home)
            #expect(run.status == 64, "--memory \(value) ended \(run.status)")
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Support/settings.json").path))
    }

    @Test func withoutATerminalSetupNeverAsks() throws {
        let home = try OutputContractTests.freshHome()
        // The test's standard input is a pipe holding an answer; nothing reads it.
        let run = try Self.pdf(["setup"], home: home, stdin: "3\n")
        #expect(run.status == 0 && !run.output.contains("How much memory") && !run.output.contains("> "), "\(run.output)")
        #expect(run.output.contains("unchanged") && run.output.contains("no models to download"), "\(run.output)")
        let json = try #require(try Self.pdf(["setup", "--json"], home: home, stdin: "3\n").json)
        #expect(json["prompted"] as? Bool == false && json["changed"] as? Bool == false && json["memoryMB"] is NSNull || json["memoryMB"] == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Support/settings.json").path))
    }

    @Test func theAnswersAtThePromptReadAsTheFlagDoes() throws {
        #expect(try SetupCommand.answer("").get() == nil)
        #expect(try SetupCommand.answer("1").get() == .budget(2048))
        #expect(try SetupCommand.answer("3").get() == .budget(8192))
        #expect(try SetupCommand.answer("Balanced").get() == .budget(4096))
        #expect(try SetupCommand.answer("3GB").get() == .budget(3072))
        #expect(try SetupCommand.answer("default").get() == .budget(nil))
        #expect(throws: (any Error).self) { try SetupCommand.answer("4").get() }
        #expect(throws: (any Error).self) { try SetupCommand.answer("lots").get() }
        let prompt = SetupCommand.prompt(current: 4096, cores: 6)
        for word in ["light", "balanced", "fastest", "2 GB", "4 GB", "8 GB", "now 4 GB"] { #expect(prompt.contains(word), "\(word)") }
    }
}
