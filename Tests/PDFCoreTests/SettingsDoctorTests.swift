import Foundation
import Testing

@testable import PDFCore

/// Parsing's memory setting, the pressure rules, the models list and `Doctor` (ROADMAP.md → M2.11).
/// Each test uses its own folders, so the user's real settings are never touched.
@Suite struct SettingsDoctorTests {
    func folder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-\(name)-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aMemorySizeReadsAsAPersonWritesIt() {
        for (text, megabytes) in [
            ("4GB", 4096), ("4gb", 4096), ("4 GB", 4096), ("2.5GB", 2560), ("3072MB", 3072), ("3072", 3072), ("1g", 1024), ("1TB", 1_048_576),
            ("1 tb", 1_048_576), ("0.5TB", 524_288),
        ] {
            #expect(Settings.parseMemory(text) == .success(megabytes), "\(text)")
        }
        #expect(Settings.parseMemory("banana") == .failure(.notANumber("banana")))
        #expect(Settings.parseMemory("-2GB") == .failure(.notANumber("-2GB")))
        // A bare small number is most likely gigabytes: ask for a unit.
        #expect(Settings.parseMemory("4") == .failure(.ambiguous("4")))
        #expect(Settings.parseMemory("100MB") == .failure(.tooSmall(100)))
        #expect(Settings.parseMemory("511") == .failure(.tooSmall(511)))
        // No overflow, whatever is written: too large, or not a plain number at all.
        for huge in ["1.0000001TB", "2TB", "9223372036854775807", "4611686018427387904", "99999999999999999999GB"] {
            #expect(Settings.parseMemory(huge) == .failure(.tooLarge), "\(huge)")
        }
        for odd in ["1e19", "1e3GB", "0x10", "0x10GB", "inf", "nan", "+4GB", "4GB4", "", "GB", "4.GB"] {
            #expect(Settings.parseMemory(odd) == .failure(.notANumber(odd)), "\(odd)")
        }
        #expect(Settings.format(4096) == "4 GB" && Settings.format(512) == "512 MB" && Settings.format(1_048_576) == "1 TB")
        #expect(Settings.format(2560) == "2.5 GB")
    }

    @Test func theWorkerCountFollowsFromTheBudgetAndTheCores() {
        // The default is what the pool always gave: half the performance cores, at least 2, each 2 GB.
        #expect(Settings.plan(budgetMB: nil, performanceCores: 4) == .init(workers: 2, workerLimitMB: 2048))
        #expect(Settings.plan(budgetMB: nil, performanceCores: 8) == .init(workers: 4, workerLimitMB: 2048))
        // The presets scale with the cores: light is one worker, balanced is the default, fastest a
        // worker for each performance core, so the default is never above fastest or below balanced.
        for cores in [1, 2, 3, 4, 6, 8, 10, 12, 16, 24, 32] {
            let light = Settings.plan(budgetMB: Settings.Preset.light.megabytes(performanceCores: cores), performanceCores: cores)
            let balanced = Settings.plan(budgetMB: Settings.Preset.balanced.megabytes(performanceCores: cores), performanceCores: cores)
            let fastest = Settings.plan(budgetMB: Settings.Preset.fastest.megabytes(performanceCores: cores), performanceCores: cores)
            let unset = Settings.plan(budgetMB: nil, performanceCores: cores)
            #expect(light.workers == 1)
            #expect(balanced == unset, "\(cores) cores")
            #expect(fastest.workers == max(2, cores) && unset.workers <= fastest.workers && light.workers <= unset.workers)
            #expect(unset.workers * unset.workerLimitMB <= Settings.Preset.fastest.megabytes(performanceCores: cores))
        }
        // The workers' limits never add up past the budget, and a budget below 2 GB is one smaller worker.
        for budget in [512, 1024, 2048, 3000, 4096, 6000, 8192, 65536] {
            let plan = Settings.plan(budgetMB: budget, performanceCores: 8)
            #expect(plan.workers * plan.workerLimitMB <= budget, "\(budget): \(plan)")
            #expect(plan.workerLimitMB <= Settings.workerLimitMB && plan.workers >= 1)
        }
        #expect(Settings.plan(budgetMB: 1024, performanceCores: 8) == .init(workers: 1, workerLimitMB: 1024))
        #expect(Settings.plan(budgetMB: 65536, performanceCores: 4).workers == 4)
        #expect(Settings.plan(budgetMB: Settings.maximumMB, performanceCores: 8).workers == 8)
    }

    @Test func theSettingIsStoredAndEnvReadsItBack() throws {
        let support = folder("support")
        #expect(Settings.load(from: support).stored == Settings.Stored())
        try Settings.save(.init(memoryMB: 8192), to: support)
        #expect(Settings.load(from: support).stored.memoryMB == 8192)
        let parsing = Env.resolveParsing(supportDirectory: support, variables: [:])
        #expect(parsing.memoryBudgetMB == 8192 && parsing.memorySource == .setup)
        #expect(parsing.workersSource == .setup && parsing.workerLimitSource == .setup)
        #expect(parsing.workers == Settings.plan(budgetMB: 8192, performanceCores: Env.performanceCores).workers)
        // The test variables still win, and the source says so.
        let forced = Env.resolveParsing(supportDirectory: support, variables: ["PDF_CLI_WORKERS": "7", "PDF_CLI_MEMORY_LIMIT_MB": "300"])
        #expect(forced.workers == 7 && forced.workersSource == .environment)
        #expect(forced.workerLimitMB == 300 && forced.workerLimitSource == .environment)
        #expect(forced.memorySource == .setup)
        // Nothing set removes the file, and the default holds.
        try Settings.save(.init(), to: support)
        #expect(!FileManager.default.fileExists(atPath: Settings.file(in: support).path))
        let none = Env.resolveParsing(supportDirectory: support, variables: [:])
        #expect(none.memoryBudgetMB == nil && none.memorySource == .default && none.workersSource == .default)
    }

    @Test func aSettingsFileThatIsNotValidFallsBackAndSaysSo() throws {
        let support = folder("broken")
        try Data("not json".utf8).write(to: Settings.file(in: support))
        let (stored, problem) = Settings.load(from: support)
        #expect(stored == Settings.Stored() && problem?.contains("is not valid") == true)
        try Data(#"{"memoryMB": 64}"#.utf8).write(to: Settings.file(in: support))
        #expect(Settings.load(from: support).problem?.contains("outside 512 MB to 1 TB") == true)
        #expect(Env.resolveParsing(supportDirectory: support, variables: [:]).problem != nil)
        // Values that would overflow a shift or a product are a problem, never a crash.
        for huge in ["1e19", "4611686018427387904", "9223372036854775807", "-5", "1.5"] {
            try Data(#"{"memoryMB": \#(huge)}"#.utf8).write(to: Settings.file(in: support))
            let problem = Settings.load(from: support).problem
            #expect(problem != nil, "\(huge)")
            let parsing = Env.resolveParsing(supportDirectory: support, variables: [:])
            #expect(parsing.memoryBudgetMB == nil && parsing.workers >= 1 && UInt64(parsing.workerLimitMB) << 20 > 0)
            #expect(Doctor.inspect(cache: folder("c"), support: support).problems.contains { $0.contains("settings.json") }, "\(huge)")
        }
    }

    @Test func aSettingsFileThatCannotBeReadIsAProblemAndOnlyNotFoundMeansNotSet() throws {
        let support = folder("unreadable")
        try Settings.save(.init(memoryMB: 4096), to: support)
        let file = Settings.file(in: support)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        if getuid() != 0 {
            #expect(Settings.load(from: support).problem?.contains("cannot be read") == true)
            #expect(Doctor.inspect(cache: folder("c"), support: support).problems.contains { $0.contains("cannot be read") })
        }
        #expect(Settings.load(from: folder("none")).problem == nil)
    }

    @Test func aLinkedSettingsFileIsWrittenThroughAndKept() throws {
        let support = folder("link-support")
        let elsewhere = folder("link-target")
        let target = elsewhere.appendingPathComponent("my-settings.json")
        try Data(#"{"memoryMB": 3072}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: Settings.file(in: support), withDestinationURL: target)
        try Settings.save(.init(memoryMB: 8192), to: support)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: Settings.file(in: support).path)) != nil)
        #expect(Settings.load(from: support).stored.memoryMB == 8192)
        #expect(String(data: try Data(contentsOf: target), encoding: .utf8)?.contains("8192") == true)
        // Clearing writes an empty object through the link: the link and its target stay.
        try Settings.save(.init(), to: support)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: Settings.file(in: support).path)) != nil)
        #expect(FileManager.default.fileExists(atPath: target.path) && Settings.load(from: support).stored == Settings.Stored())
    }

    @Test func fewerWorkersRunUnderPressureAndOCRPagesWeighMore() {
        #expect(Pressure.reduced(4, .normal) == 4 && Pressure.reduced(4, .high) == 2 && Pressure.reduced(4, .critical) == 1)
        #expect(Pressure.reduced(1, .high) == 1 && Pressure.reduced(3, .high) == 1)
        // Half as many for a scan, but a pool of two keeps both.
        #expect(Pressure.ocrWeighted(1) == 1 && Pressure.ocrWeighted(2) == 2 && Pressure.ocrWeighted(3) == 2)
        #expect(Pressure.ocrWeighted(4) == 2 && Pressure.ocrWeighted(8) == 4)
    }

    @Test func noModelIsBuiltAndTheNoticeNamesWhatTheUserAccepts() {
        #expect(Models.available.isEmpty)
        let sample = ModelSpec(
            name: "layout-sample", unlocks: "tables found by a model", bytes: 150_000_000,
            sourceURL: "https://example.org/layout.mlpackage", author: "Example Lab", license: "Apache-2.0",
            licenseURL: "https://www.apache.org/licenses/LICENSE-2.0")
        let notice = sample.licenseNotice
        #expect(notice.contains("not part of pdf-cli") && notice.contains("MIT licence does not cover it"))
        #expect(notice.contains("Apache-2.0") && notice.contains("Example Lab") && notice.contains("https://example.org/layout.mlpackage"))
        #expect(notice.contains("MB"))
        let support = folder("models")
        #expect(Models.installed(in: support.appendingPathComponent("models")).isEmpty)
        try? FileManager.default.createDirectory(at: support.appendingPathComponent("models/layout-sample"), withIntermediateDirectories: true)
        #expect(Models.installed(in: support.appendingPathComponent("models")) == ["layout-sample"])
        #expect(Models.missing(from: [sample], installed: []).map(\.name) == ["layout-sample"])
        #expect(Models.missing(from: [sample], installed: ["layout-sample"]).isEmpty)
        // A model that exists shows in the report as missing, with what it unlocks.
        let report = Doctor.inspect(cache: folder("c"), support: folder("s"), modelList: [sample])
        #expect(report.missing.contains { $0.piece == "model layout-sample" && $0.unlocks == "tables found by a model" })
    }

    @Test func doctorSaysOnlyWhatTheMacOSVersionReallyUnlocks() {
        func unlocks(_ major: Int) -> [String] {
            Doctor.macOSReport(version: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0), build: "x").report.unlocks
        }
        #expect(unlocks(26).isEmpty)
        #expect(unlocks(14).count == 1 && unlocks(14)[0].hasPrefix("macOS 26: "))
        #expect(unlocks(12).count == 2 && unlocks(12)[1].hasPrefix("macOS 13: "))
        #expect(
            Doctor.macOSReport(version: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0), build: "b").report.scanReader
                == "document recognizer")
        #expect(
            Doctor.macOSReport(version: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0), build: "b").report.scanReader
                == "text recognizer")
    }

    @Test func doctorOnNothingSaysNoneYetAndCreatesNothing() throws {
        let cache = folder("empty-cache")
        let support = folder("empty-support")
        let report = Doctor.inspect(cache: cache, support: support)
        #expect(report.cache.state == "none yet" && report.library.state == "none yet")
        #expect(report.problems.isEmpty && report.parserVersion == Env.parserVersion)
        #expect(report.models.installed.isEmpty && report.models.available.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []).isEmpty)
        // A clean of nothing does not claim a parse is running.
        let clean = try Doctor.clean(dryRun: false, cache: cache, support: support)
        #expect(clean.parseRunning == false)
        let dry = try Doctor.clean(dryRun: true, cache: folder("empty-cache2"), support: folder("empty-support2"))
        #expect(dry.parseRunning == false)
    }

    @Test func aStateTheNextCommandRepairsIsANoteAndAnUnopenableCacheIsAProblemWithANextStep() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(atPath: world.here) }
        let store = try Store(directory: world.cache)
        try store.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA user_version = 3") }
        let older = Doctor.inspect(cache: world.cache, support: world.support)
        #expect(older.cache.state == "older schema" && older.notes.count == 1)
        #expect(!older.problems.contains { $0.contains("older version") })
        // A database that is not one: a problem, with the folder to remove and no raw SQLite text alone.
        let broken = folder("broken-cache")
        try Data(repeating: 7, count: 4096).write(to: broken.appendingPathComponent("cache.sqlite"))
        let report = Doctor.inspect(cache: broken, support: folder("s"))
        #expect(report.cache.state == "cannot open")
        #expect(report.problems.contains { $0.contains("rm -r") && $0.contains(broken.path) })
        let json =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Doctor.inspect(cache: folder("c"), support: folder("s")))) as? [String: Any]
        #expect((json?["cache"] as? [String: Any])?.keys.contains("schema") == true)
        #expect((((json?["parsing"] as? [String: Any])?["memoryBudgetMB"]) as? [String: Any])?.keys.contains("value") == true)
    }

    @Test func everySlotFileIsCounted() throws {
        let cache = folder("slots")
        let held = (0..<6).compactMap { _ in WorkerPool.acquire(foreground: true, size: 6, directory: cache) }
        #expect(held.count == 6 && Doctor.slotsInUse(cache) == 6)
        held.last?.release()
        #expect(Doctor.slotsInUse(cache) == 5)
    }

    /// A runner that was stopped (SIGSTOP) keeps its pid and stops its heartbeat: its lock is not left
    /// over, and the cache is not compacted from under it. A lock whose process is gone is left over.
    @Test func aStoppedRunnersLockIsNotLeftOverButADeadOnesIs() throws {
        let cache = folder("stopped")
        let store = try Store(directory: cache)
        // Spawned with posix_spawn, not Foundation's Process, whose child watching a stopped child can stall other tests.
        let child = try Processes.spawn("/bin/sleep", ["60"], detached: false, captureOutput: false).pid
        defer {
            kill(child, SIGCONT)
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        kill(child, SIGSTOP)
        let now = Date().timeIntervalSince1970
        try store.write { db in
            // Silent for a minute, as a stopped runner is, but its process exists.
            try db.execute(
                sql: "INSERT INTO runner_lock (lock_key, pid, heartbeat_at) VALUES ('path:/stopped', ?, ?)",
                arguments: [child, now - 60])
            try db.execute(
                sql: "INSERT INTO runner_lock (lock_key, pid, heartbeat_at) VALUES ('path:/dead', 999999, ?)",
                arguments: [now])
        }
        let locks = try store.runners()
        #expect(locks.alive.map(\.lock) == ["path:/stopped"] && locks.leftover == ["path:/dead"])
        let report = try Doctor.clean(dryRun: false, cache: cache, support: folder("s"))
        #expect(report.removed["runnerLocks"] == 1 && report.compacted == false && report.parseRunning)
        let after = try store.runners()
        #expect(after.alive.map(\.lock) == ["path:/stopped"] && after.leftover.isEmpty)
        // Minutes of silence make even that one leftover.
        try store.write { db in try db.execute(sql: "UPDATE runner_lock SET heartbeat_at = ?", arguments: [now - 3600]) }
        #expect(try store.runners().alive.isEmpty)
    }

    /// A cache with a file that is gone, a file that stays, an old parser's page and a leftover lock;
    /// a library with the gone file, the kept one, and one on a drive that is not plugged in.
    func makeWorld() throws -> (cache: URL, support: URL, here: String) {
        let cache = folder("world-cache")
        let support = folder("world-support")
        let store = try Store(directory: cache)
        let stat = FileStat(size: 100, modifiedNanos: 1, inode: 2, device: 3)
        let gone = "/nowhere-\(UUID()).pdf"
        try store.saveIndex(path: gone, stat: stat, pageKeys: ["g1", "g2"])
        for key in ["g1", "g2"] {
            try store.saveResult(key: key, PageResult(status: .ok, method: "pdfkit", text: key, reason: "", parseMillis: 1))
        }
        let here = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-here-\(UUID()).pdf").path
        FileManager.default.createFile(atPath: here, contents: Data("%PDF-".utf8))
        try store.saveIndex(path: here, stat: try #require(FileStat(path: here)), pageKeys: ["h1"])
        try store.saveResult(key: "h1", PageResult(status: .ok, method: "pdfkit", text: "h", reason: "", parseMillis: 1))
        try store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO page_result (page_key, parser_version, status, method, text, reason, macos_build, parse_ms, parsed_at)
                    VALUES ('h1', ?, 'ok', 'pdfkit', 'old', '', '', 0, 0)
                    """, arguments: [Env.parserVersion - 1])
            try db.execute(sql: "INSERT INTO runner_lock (lock_key, pid, heartbeat_at) VALUES ('path:/x', 999999, 0)")
        }
        let library = try Library(directory: support)
        try library.register(path: gone, docID: "gone0000", title: "", pageCount: 2)
        try library.register(path: here, docID: "here0000", title: "", pageCount: 1)
        try library.register(path: "/Volumes/PdfCliNoSuchDrive/a.pdf", docID: "away0000", title: "", pageCount: 1)
        return (cache, support, here)
    }

    @Test func aCleanRemovesWhatGCRemovedAndAnUnpluggedDriveKeepsBoth() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(atPath: world.here) }
        let before = Doctor.inspect(cache: world.cache, support: world.support)
        #expect(before.problems.count == 2 && before.fixedByClean.count == 2, "\(before.problems)")
        #expect(before.cleanable.files == 1 && before.cleanable.documents == 1 && before.cleanable.pages == 3)
        #expect(before.cleanable.libraryEntries == 1 && before.cleanable.runnerLocks == 1)
        #expect(before.library.filesOutOfReach == 1 && before.library.filesMissing == 1)
        let dry = try Doctor.clean(dryRun: true, cache: world.cache, support: world.support)
        let real = try Doctor.clean(dryRun: false, cache: world.cache, support: world.support)
        #expect(dry.dryRun == true && real.dryRun == nil)
        #expect(dry.removed == real.removed, "\(dry.removed) \(real.removed)")
        #expect(real.removed == ["files": 1, "documents": 1, "pages": 3, "libraryEntries": 1, "crops": 0, "runnerLocks": 1])
        let store = try Store(directory: world.cache)
        #expect(try store.results(keys: ["h1"])["h1"]?.text == "h" && (try store.results(keys: ["g1"])).isEmpty)
        let kept = try Library(directory: world.support).entries().map(\.docID).sorted()
        #expect(kept == ["away0000", "here0000"])
        let after = Doctor.inspect(cache: world.cache, support: world.support)
        #expect(after.problems.isEmpty && after.cleanable.pages == 0 && after.cleanable.libraryEntries == 0)
        // A second clean has nothing to remove.
        #expect(try Doctor.clean(dryRun: false, cache: world.cache, support: world.support).removed.values.allSatisfy { $0 == 0 })
    }

    @Test func aDryCleanChangesNoFileOfEitherFolder() throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(atPath: world.here) }
        // Close the writers: a checkpoint on close leaves the files steady.
        func bytes(_ root: URL) -> [String: Data] {
            var found: [String: Data] = [:]
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walker?.nextObject() as? URL {
                if !url.lastPathComponent.hasSuffix("-shm"), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    found[url.path] = try? Data(contentsOf: url)
                }
            }
            return found
        }
        let before = (bytes(world.cache), bytes(world.support))
        _ = try Doctor.clean(dryRun: true, cache: world.cache, support: world.support)
        _ = Doctor.inspect(cache: world.cache, support: world.support)
        #expect(bytes(world.cache) == before.0 && bytes(world.support) == before.1)
    }

    @Test func aCropSweepCountsWhatItWouldRemoveAndRemovesOnlyWhenAsked() throws {
        let crops = folder("crops")
        let sub = crops.appendingPathComponent("abcd", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let old = sub.appendingPathComponent("old.png")
        let fresh = sub.appendingPathComponent("fresh.png")
        try Data(repeating: 1, count: 1000).write(to: old)
        try Data(repeating: 1, count: 500).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        #expect(Crop.sweep(dryRun: true, in: crops) == Crop.Swept(images: 1, bytes: 1000))
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(Crop.usage(in: crops) == Crop.Swept(images: 2, bytes: 1500))
        #expect(Crop.sweep(in: crops) == Crop.Swept(images: 1, bytes: 1000))
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
    }
}
