import Darwin
import Foundation
import GRDB

/// What `pdf doctor` shows (FEATURES.md → F12): the Mac, the parser, the models, what the cache and
/// the library hold, the parsing settings in force, what is running, and what is wrong. It reads
/// everything read-only, so it changes nothing and never parses; `Doctor.clean` is what `--clean`
/// adds, the job `pdf gc` had.
/// A value that encodes as `null` when it is missing, where a plain optional would leave its key out:
/// every key of a command's JSON is always there (FEATURES.md → F7).
public struct Nullable<Value: Encodable>: Encodable {
    public var value: Value?
    public init(_ value: Value?) { self.value = value }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

public struct DoctorReport: Encodable {
    public struct MacOS: Encodable {
        public var version: String
        public var build: String
        /// The engine that reads scanned pages here: "document recognizer" (macOS 26) or "text recognizer".
        public var scanReader: String
        public var unlocks: [String]
    }

    public struct ModelInfo: Encodable {
        public var name: String
        public var bytes: Int64
        public var license: String
        public var unlocks: String
    }

    public struct Models: Encodable {
        public var installed: [String]
        public var available: [ModelInfo]
        public var note: String
    }

    public struct Cache: Encodable {
        public var path: String
        /// "ok", "none yet", "older schema" or "log files gone" (the next normal command repairs both),
        /// "cut off" (a runner left work half written; the next normal command repairs it), or "cannot open".
        public var state: String
        /// The whole folder: the database, the crop images and the pool's slot files.
        public var bytes: Int64
        public var databaseBytes: Int64
        public var schema: Nullable<Int>
        public var files: Int
        public var documents: Int
        public var pages: Int
        public var crops: Int
        public var cropBytes: Int64
    }

    public struct Library: Encodable {
        public var path: String
        public var state: String
        public var bytes: Int64
        public var entries: Int
        public var filesMissing: Int
        public var filesOutOfReach: Int
    }

    public struct Setting: Encodable {
        public var value: Nullable<Int>
        /// "setup", "environment" or "default", with the variable's name for the environment.
        public var source: String
    }

    public struct Parsing: Encodable {
        public var memoryBudgetMB: Setting
        public var workers: Setting
        public var workerLimitMB: Setting
        public var performanceCores: Int
        /// The most workers the pool allows now: fewer under pressure.
        public var workersNow: Int
        public var load: String
        public var loadReasons: [String]
        public var settingsFile: String
    }

    public struct Running: Encodable {
        public struct Runner: Encodable {
            public var pid: Int32
            public var lock: String
        }
        public var runners: [Runner]
        public var slotsInUse: Int
        public var slots: Int
    }

    public struct Cleanable: Encodable {
        public var files: Int
        public var documents: Int
        public var pages: Int
        public var libraryEntries: Int
        public var crops: Int
        public var runnerLocks: Int
        public var reclaimableBytes: Int64
    }

    public struct Missing: Encodable {
        public var piece: String
        public var unlocks: String
    }

    public var macOS: MacOS
    public var parserVersion: Int
    public var models: Models
    public var cache: Cache
    public var library: Library
    public var parsing: Parsing
    public var running: Running
    /// What `pdf doctor --clean` would remove now.
    public var cleanable: Cleanable
    public var missing: [Missing]
    /// What is wrong and needs the user. A state the next normal command repairs is a note, not a problem.
    public var problems: [String]
    public var notes: [String]
    /// The problems that `--clean` fixes: a subset of `problems`.
    public var fixedByClean: [String]
}

/// What `pdf doctor --clean` removed, or with `dryRun` would.
public struct CleanReport: Encodable {
    public var removed: [String: Int]
    /// Space given back. With `dryRun`, at least that much: the crop images and the free space in
    /// the database now; compacting gives back more once the rows are gone.
    public var freedBytes: Int64
    public var compacted: Bool
    /// Compacting waited because a parse is running; the space returns at the next clean.
    public var parseRunning: Bool
    public var dryRun: Bool?
}

public enum Doctor {
    public static func inspect(
        cache cacheDirectory: URL = Env.cacheDirectory,
        support supportDirectory: URL = Env.supportDirectory,
        modelList: [ModelSpec] = Models.available
    ) -> DoctorReport {
        var problems: [String] = []
        var notes: [String] = []
        var fixable: [String] = []
        let macOS = macOSReport()

        // The cache.
        var cache = DoctorReport.Cache(
            path: cacheDirectory.path, state: "none yet", bytes: folderSize(cacheDirectory),
            databaseBytes: databaseBytes(cacheDirectory, "cache.sqlite"), schema: Nullable(nil), files: 0,
            documents: 0, pages: 0, crops: 0, cropBytes: 0)
        let crops = Crop.usage(in: cacheDirectory.appendingPathComponent("crops", isDirectory: true))
        cache.crops = crops.images
        cache.cropBytes = crops.bytes
        var runners: [Store.LiveRunner] = []
        var leftoverLocks = 0
        var garbage = Store.Removed()
        var reclaimable: Int64 = 0
        if Store.exists(directory: cacheDirectory) {
            do {
                let store = try Store(directory: cacheDirectory, readOnly: true)
                let counts = try store.counts()
                cache.state = "ok"
                cache.schema = Nullable(Store.schemaVersion)
                cache.files = counts.files
                cache.documents = counts.documents
                cache.pages = counts.pages
                let locks = try store.runners()
                runners = locks.alive
                leftoverLocks = locks.leftover.count
                garbage = try store.wouldCollectGarbage()
                reclaimable = try store.freePageBytes()
                if leftoverLocks > 0 {
                    let problem = "\(leftoverLocks) runner lock\(leftoverLocks == 1 ? "" : "s") left by runners that are gone; --clean removes them"
                    problems.append(problem)
                    fixable.append(problem)
                }
            } catch is Store.OlderCache {
                cache.state = "older schema"
                notes.append("the cache is from an older version of pdf; the next normal command (pdf ls) brings it up to date")
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
                cache.state = "log files gone"
                notes.append("the cache's log files are gone; the next normal command (pdf ls) recreates them")
            } catch let error as DatabaseError where error.resultCode == .SQLITE_READONLY {
                cache.state = "cut off"
                notes.append("another pdf run was cut off and left its work half written; the next normal command (pdf ls) repairs it")
            } catch {
                cache.state = "cannot open"
                problems.append(
                    "the cache cannot be opened (\(Doctor.shortReason(error))); it holds only what pdf can rebuild, so remove the folder and read the files again: rm -r \(Doctor.quoted(cacheDirectory.path))"
                )
            }
        } else if let unreadable = unreadable(cacheDirectory) {
            problems.append(unreadable)
        }

        // The library.
        var library = DoctorReport.Library(
            path: supportDirectory.path, state: "none yet",
            bytes: databaseBytes(supportDirectory, "library.sqlite"), entries: 0,
            filesMissing: 0, filesOutOfReach: 0)
        var goneEntries = 0
        if PDFCore.Library.exists(directory: supportDirectory) {
            do {
                let entries = try PDFCore.Library(directory: supportDirectory, readOnly: true).entries()
                library.state = "ok"
                library.entries = entries.count
                for entry in entries where FileStat(path: entry.path) == nil {
                    if FileStat.isGone(path: entry.path) { library.filesMissing += 1 } else { library.filesOutOfReach += 1 }
                }
                goneEntries = library.filesMissing
                if library.filesMissing > 0 {
                    let problem =
                        "\(library.filesMissing) PDF\(library.filesMissing == 1 ? " in the library no longer exists" : "s in the library no longer exist"); --clean removes \(library.filesMissing == 1 ? "it" : "them") (pdf ls names \(library.filesMissing == 1 ? "it" : "them"))"
                    problems.append(problem)
                    fixable.append(problem)
                }
            } catch {
                library.state = "cannot open"
                problems.append(
                    "the library cannot be opened (\(Doctor.shortReason(error))); its list can be made again with pdf add, but the picks and transcripts beside it are the agent's work: move \(Doctor.quoted(supportDirectory.appendingPathComponent("library.sqlite").path)) aside rather than delete it"
                )
            }
        } else if let unreadable = unreadable(supportDirectory) {
            problems.append(unreadable)
        }

        // The settings in force.
        let parsing = Env.resolveParsing(supportDirectory: supportDirectory, variables: Env.variables)
        let pressure = Pressure.current
        if let problem = parsing.problem { problems.append(problem) }
        let source = { (source: Env.Source, variable: String) in
            source == .environment ? "environment (\(variable))" : source.rawValue
        }
        let settings = DoctorReport.Parsing(
            memoryBudgetMB: .init(value: Nullable(parsing.memoryBudgetMB), source: source(parsing.memorySource, "")),
            workers: .init(value: Nullable(parsing.workers), source: source(parsing.workersSource, "PDF_CLI_WORKERS")),
            workerLimitMB: .init(
                value: Nullable(parsing.workerLimitMB), source: source(parsing.workerLimitSource, "PDF_CLI_MEMORY_LIMIT_MB")),
            performanceCores: Env.performanceCores, workersNow: Pressure.reduced(parsing.workers, pressure.level),
            load: ["normal", "high", "critical"][pressure.level.rawValue], loadReasons: pressure.reasons,
            settingsFile: Settings.file(in: supportDirectory).path)

        // What runs.
        let running = DoctorReport.Running(
            runners: runners.map { .init(pid: $0.pid, lock: $0.lock) },
            slotsInUse: slotsInUse(cacheDirectory), slots: parsing.workers)

        let installed = Models.installed(in: supportDirectory.appendingPathComponent("models", isDirectory: true))
        let models = DoctorReport.Models(
            installed: installed,
            available: modelList.map { .init(name: $0.name, bytes: $0.bytes, license: $0.license, unlocks: $0.unlocks) },
            note: modelList.isEmpty
                ? "none exist yet: nothing built needs a model, and pdf setup has none to download"
                : "pdf setup downloads the ones not installed")
        var missing = macOS.unlocks.map { DoctorReport.Missing(piece: $0.piece, unlocks: $0.unlocks) }
        missing += Models.missing(from: modelList, installed: installed).map { .init(piece: "model \($0.name)", unlocks: $0.unlocks) }

        let sweep = Crop.sweep(dryRun: true, in: cacheDirectory.appendingPathComponent("crops", isDirectory: true))
        let cleanable = DoctorReport.Cleanable(
            files: garbage.files, documents: garbage.documents, pages: garbage.pages, libraryEntries: goneEntries,
            crops: sweep.images, runnerLocks: leftoverLocks, reclaimableBytes: reclaimable + sweep.bytes)
        return DoctorReport(
            macOS: macOS.report, parserVersion: Env.parserVersion, models: models, cache: cache, library: library,
            parsing: settings, running: running, cleanable: cleanable, missing: missing, problems: problems,
            notes: notes, fixedByClean: fixable)
    }

    // MARK: macOS

    struct Unlock {
        var piece: String
        var unlocks: String
    }

    static func macOSReport(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        build: String = Env.macOSBuild
    ) -> (report: DoctorReport.MacOS, unlocks: [Unlock]) {
        var unlocks: [Unlock] = []
        if version.majorVersion < 26 {
            unlocks.append(
                Unlock(
                    piece: "macOS 26",
                    unlocks:
                        "scanned pages are read by Apple's document recognizer, which returns paragraphs and their lines itself and finds word breaks a little better; until then the older text recognizer reads them, and pdf groups its lines into paragraphs by position"
                ))
        }
        if version.majorVersion < 13 {
            unlocks.append(
                Unlock(
                    piece: "macOS 13",
                    unlocks:
                        "scanned pages in Japanese or Korean, and automatic detection of a scan's language (before it, OCR reads English, French, Italian, German, Spanish, Portuguese and Chinese)"
                ))
        }
        let text = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        let report = DoctorReport.MacOS(
            version: text, build: build,
            scanReader: version.majorVersion >= 26 ? "document recognizer" : "text recognizer",
            unlocks: unlocks.map { "\($0.piece): \($0.unlocks)" })
        return (report, unlocks)
    }

    // MARK: Sizes

    static func folderSize(_ folder: URL) -> Int64 {
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func databaseBytes(_ folder: URL, _ name: String) -> Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name + suffix).path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// How many of the pool's slots are held now, counting every slot file there is. A slot file is
    /// opened read-only and locked for a moment, which creates and writes nothing; a slot that
    /// no one has made is free.
    static func slotsInUse(_ cacheDirectory: URL) -> Int {
        let folder = cacheDirectory.appendingPathComponent("slots", isDirectory: true)
        var used = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("slot-") && name.hasSuffix(".lock") {
            let descriptor = open(folder.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { flock(descriptor, LOCK_UN) } else { used += 1 }
            close(descriptor)
        }
        return used
    }

    /// A folder that exists but cannot be read, which is not the same as one that is not there.
    static func unreadable(_ folder: URL) -> String? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) else {
            // Not found, or behind a folder that cannot be searched.
            let parent = folder.deletingLastPathComponent()
            return FileManager.default.fileExists(atPath: parent.path) && !FileManager.default.isReadableFile(atPath: parent.path)
                ? "\(parent.path) cannot be read" : nil
        }
        guard isFolder.boolValue else { return "\(folder.path) is a file, not a folder" }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil
            ? "\(folder.path) cannot be read; pdf cannot see what it holds" : nil
    }

    static func shortReason(_ error: Error) -> String {
        if let error = error as? DatabaseError { return error.message ?? "SQLite error \(error.resultCode.rawValue)" }
        return "\(error)"
    }

    static func quoted(_ path: String) -> String {
        path.contains(" ") ? "'\(path)'" : path
    }

    // MARK: Clean

    /// Removes what no read can use any more, as `pdf gc` did: cached results for files that no
    /// longer exist or changed and for old parser versions, library entries of files that no
    /// longer exist, runner locks of runners that are gone, and crops older than 7 days. A file on a
    /// drive not plugged in keeps both its rows and its entry. With `dryRun` it opens both
    /// databases read-only and counts (ROADMAP.md → M2.18's rules), parsing and writing nothing.
    public static func clean(
        dryRun: Bool, cache cacheDirectory: URL = Env.cacheDirectory,
        support supportDirectory: URL = Env.supportDirectory
    ) throws -> CleanReport {
        let cropsFolder = cacheDirectory.appendingPathComponent("crops", isDirectory: true)
        var removed = Store.Removed()
        var gone: [String] = []
        var locks = 0
        var freed: Int64 = 0
        var compacted = false
        var parseRunning = false
        if Store.exists(directory: cacheDirectory) {
            if dryRun {
                let store = try Store(directory: cacheDirectory, readOnly: true)
                removed = try store.wouldCollectGarbage()
                locks = try store.runners().leftover.count
                freed = try store.freePageBytes()
                parseRunning = !(try store.runners().alive.isEmpty)
                compacted = !parseRunning
            } else {
                let store = try Store(directory: cacheDirectory)
                let before = store.size
                locks = try store.runners().leftover.count
                removed = try store.collectGarbage()
                compacted = store.compact()
                parseRunning = !compacted
                // What compacting gave back includes the space that rows removed earlier left and
                // the write-ahead log; the counts are only what this run removed.
                freed = compacted ? max(0, before - store.size) : 0
            }
        }
        if PDFCore.Library.exists(directory: supportDirectory) {
            let library = try PDFCore.Library(directory: supportDirectory, readOnly: dryRun)
            gone = try library.entries().filter { FileStat.isGone(path: $0.path) }.map(\.path)
            if !dryRun { try library.remove(paths: gone) }
        }
        let crops = Crop.sweep(dryRun: dryRun, in: cropsFolder)
        return CleanReport(
            removed: [
                "files": removed.files, "documents": removed.documents, "pages": removed.pages,
                "libraryEntries": gone.count, "crops": crops.images, "runnerLocks": locks,
            ],
            freedBytes: freed + crops.bytes, compacted: compacted, parseRunning: parseRunning,
            dryRun: dryRun ? true : nil)
    }
}
