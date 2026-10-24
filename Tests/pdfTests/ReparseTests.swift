import Foundation
import Testing

@testable import pdf

/// `pdf reparse` (ROADMAP.md → M2.10): it replaces the cached results of the pages it reads again,
/// clears their picks, keeps transcripts, follows the contract of M2.15, and a command that dies
/// half way changes nothing. The tests run the built `pdf` with a fresh home, as an agent would.
@Suite(.serialized) struct ReparseTests {
    static let root = OutputContractTests.root
    static let paper = root.appendingPathComponent("testdata/smoke/arxiv-2609.23257.pdf").path
    static let scan = root.appendingPathComponent("testdata/smoke/scan-naca-report-1034.pdf").path
    static let small = root.appendingPathComponent("testdata/safety/carries-comments.pdf").path
    static let regions = root.appendingPathComponent("testdata/safety/hidden-figure-alt.pdf").path

    static func pdf(_ arguments: [String], home: URL, stdin: String = "") throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home, stdin: stdin)
    }

    /// Runs `statement` on one of the home's databases and returns what `sqlite3` prints.
    @discardableResult
    static func sql(_ home: URL, _ database: String, _ statement: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [home.appendingPathComponent(database).path, statement]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func cache(_ home: URL, _ statement: String) throws -> String { try sql(home, "Caches/cache.sqlite", statement) }

    /// A copy of a fixture in the home, so its path names this test alone.
    static func copy(_ file: String, to home: URL) throws -> String {
        let target = home.appendingPathComponent("copy-" + URL(fileURLWithPath: file).lastPathComponent)
        try FileManager.default.copyItem(atPath: file, toPath: target.path)
        return target.path
    }

    /// Whether a runner or worker for a file is still alive.
    static func running(_ file: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", file]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func aReparseReplacesTheCachedResultsClearsPicksAndLeavesOtherPagesAlone() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        try await DryRunTests.settle(home)
        let picked = try Self.pdf(["pick", file, "p2.2", "b"], home: home)
        #expect(picked.status == 0, "\(picked.output)")
        #expect(try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home).output.contains("[picked"))
        // Plant a change in every cached result: a reparse that replaces gets the real reading back.
        try Self.cache(home, "UPDATE page_result SET status = 'failed', reason = 'planted', text = 'planted'")
        let cached = try Self.cache(home, "SELECT count(*) FROM page_result")
        let indexed = try Self.cache(home, "SELECT count(*) FROM search_page")

        let run = try Self.pdf(["reparse", file, "--page", "2", "--json"], home: home)
        #expect(run.status == 2, "p.2 holds unsure words, so the reparse ends 2: \(run.output.prefix(300))")
        let object = try #require(run.json, "\(run.output.prefix(300))")
        #expect(object["reparsed"] as? Int == 1 && object["pages"] as? [Int] == [2])
        #expect(object["picksCleared"] as? Int == 1)
        let change = try #require((object["changes"] as? [[String: Any]])?.first)
        #expect(change["page"] as? Int == 2 && change["before"] as? String == "failed" && change["after"] as? String == "unsure", "\(change)")
        // Exactly one result came back; the other pages keep what was planted.
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result") == cached)
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result WHERE status = 'failed'") == String((Int(cached) ?? 0) - 1))
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result WHERE text = 'planted'") == String((Int(cached) ?? 0) - 1))
        // The keyword index follows: the page is indexed once, and no row is left behind or lost.
        #expect(try Self.cache(home, "SELECT count(*) FROM search_page") == indexed)
        #expect(try Self.cache(home, "SELECT count(*) FROM search_block WHERE id NOT IN (SELECT rowid FROM block_text)") == "0")
        #expect(
            try Self.cache(home, "SELECT count(*) FROM search_block s WHERE NOT EXISTS (SELECT 1 FROM page_result r WHERE r.page_key = s.page_key)")
                == "0")
        // The pick is gone: the page offers its two readings again.
        let again = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        #expect(!again.output.contains("[picked") && again.output.contains("unsure: two readings differ"), "\(again.output.prefix(400))")
        // No runner is left parsing the other pages of the file.
        #expect(!Self.running(file))
        // The other pages were not parsed by the reparse: still planted.
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result WHERE reason = 'planted'") == String((Int(cached) ?? 0) - 1))
    }

    @Test func pageSpecsAreReadsAndBadOnesAreRefused() throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.paper, to: home)
        let run = try Self.pdf(["reparse", file, "--page", "3,5-6", "--page", "5", "--json"], home: home)
        #expect([0, 2].contains(run.status), "\(run.output.prefix(300))")
        #expect(run.json?["pages"] as? [Int] == [3, 5, 6], "\(run.output.prefix(300))")
        #expect(run.json?["neverRead"] as? Bool == true)
        // Only these pages are cached: the reparse of a file never read just parses them.
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result") == "3")
        #expect(try Self.pdf(["ls"], home: home).output.contains("parsed 3 of 18 pages"))
        #expect(!Self.running(file))
        for bad in ["0", "3-1", "x", "1-"] {
            #expect(try Self.pdf(["reparse", file, "--page", bad], home: home).status == 64, "--page \(bad)")
        }
        let range = try Self.pdf(["reparse", file, "--page", "99", "--json"], home: home)
        #expect(range.status == 1 && (range.json?["failed"] as? String)?.contains("page 99 is out of range") == true, "\(range.output)")
    }

    @Test func stepOCRReadsThePagesByOCRAndPlainReparseGoesBack() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.scan, to: home)
        _ = try Self.pdf(["read", file, "--page", "1"], home: home)
        try await DryRunTests.settle(home)
        try Self.cache(home, "UPDATE page_result SET method = 'planted'")
        let run = try Self.pdf(["reparse", file, "--page", "1", "--step", "ocr", "--json"], home: home)
        #expect([0, 2, 3].contains(Int32(run.status)), "\(run.output.prefix(300))")
        #expect(run.json?["step"] as? String == "ocr")
        #expect(try Self.cache(home, "SELECT method FROM page_result WHERE method <> 'planted'") == "ocr", "page 1 was read by OCR")
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result WHERE method = 'planted'") != "0", "the other pages stay")
        #expect(!Self.running(file))

        // A born-digital page, read by OCR on request, under the same key, and back with a plain reparse.
        let small = try Self.copy(Self.small, to: home)
        _ = try Self.pdf(["reparse", small, "--json"], home: home)
        #expect(try Self.cache(home, "SELECT method FROM page_result WHERE text LIKE '%' ORDER BY parsed_at DESC LIMIT 1") == "pdfkit")
        let ocr = try Self.pdf(["reparse", small, "--step", "ocr"], home: home)
        #expect(ocr.output.contains("with OCR"), "\(ocr.output)")
        #expect(try Self.cache(home, "SELECT method FROM page_result ORDER BY parsed_at DESC LIMIT 1") == "ocr")
        _ = try Self.pdf(["reparse", small], home: home)
        #expect(try Self.cache(home, "SELECT method FROM page_result ORDER BY parsed_at DESC LIMIT 1") == "pdfkit")
    }

    @Test func transcriptsStayWhenAPageIsReparsed() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.regions, to: home)
        _ = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        try await DryRunTests.settle(home)
        let kept = try Self.pdf(["transcribe", file, "--page", "2", "--equation", "1"], home: home, stdin: "E = m c^{2}\n")
        #expect(kept.status == 0, "\(kept.output)")
        let before = try Self.sql(home, "Support/library.sqlite", "SELECT page_key, text FROM transcript")
        #expect(before.contains("E = m c^{2}"))
        for arguments in [["reparse", file, "--page", "2"], ["reparse", file, "--page", "2", "--step", "ocr"]] {
            let run = try Self.pdf(arguments, home: home)
            #expect([0, 2, 3].contains(run.status), "\(run.output)")
            #expect(
                try Self.sql(home, "Support/library.sqlite", "SELECT page_key, text FROM transcript") == before, "the transcript went on \(arguments)"
            )
        }
        // A plain reparse keeps the page's key, so the page shows the reading in place, labelled.
        _ = try Self.pdf(["reparse", file, "--page", "2"], home: home)
        let read = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        #expect(read.output.contains("E = m c^{2}"), "\(read.output.prefix(600))")
    }

    @Test func theContractHolds() throws {
        let home = try OutputContractTests.freshHome()
        let missing = try Self.pdf(["reparse", OutputContractTests.missing], home: home)
        #expect(missing.status == 1 && missing.output.hasPrefix("\(OutputContractTests.missing): failed: no such file"), "\(missing.output)")
        let broken = try Self.pdf(["reparse", OutputContractTests.notAPDF, "--json"], home: home)
        #expect(broken.status == 3 && (broken.json?["failed"] as? String)?.hasPrefix("not a PDF") == true, "\(broken.output)")
        let step = try Self.pdf(["reparse", Self.small, "--step", "pdfkit"], home: home)
        #expect(step.status == 64 && step.errors.contains("ocr"), "\(step.errors)")
        let json = try Self.pdf(["reparse", Self.small, "--json"], home: home)
        #expect(json.status == 0)
        for key in ["file", "id", "step", "reparsed", "pages", "flagged", "changes", "kept", "picksCleared"] {
            #expect(json.json?[key] != nil, "no \(key): \(json.output)")
        }
        // A locked file points to the command that opens it, as pdf add does.
        let both = try Self.pdf(["reparse", Self.small, "--password", "a", "--password-stdin"], home: home)
        #expect(both.status == 64)
    }

    @Test func aCommandKilledHalfWayLeavesTheOldResultsAndNothingParsing() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--budget", "all"], home: home)
        try await DryRunTests.settle(home)
        try Self.cache(home, "UPDATE page_result SET status = 'failed', reason = 'planted'")
        let before = try Self.cache(home, "SELECT page_key || status || parsed_at FROM page_result ORDER BY page_key")

        // Page 5's worker hangs, so the reparse is half way when the command is killed.
        let process = Process()
        process.executableURL = try #require(OutputContractTests.binary)
        process.arguments = ["reparse", file]
        var environment = ProcessInfo.processInfo.environment
        environment["PDF_CLI_HOME"] = home.path
        environment["PDF_CLI_TEST_FAULT"] = "hang:5"
        environment["PDF_CLI_PAGE_TIME_LIMIT"] = "300"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(nanoseconds: 6_000_000_000)
        #expect(process.isRunning, "the reparse should still be waiting on page 5")
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        // The runner and its workers notice that the command is gone and stop.
        var alive = true
        for _ in 0..<40 where alive {
            try await Task.sleep(nanoseconds: 500_000_000)
            alive = Self.running(file)
        }
        #expect(!alive, "a runner is still parsing after its command was killed")
        #expect(try Self.cache(home, "SELECT page_key || status || parsed_at FROM page_result ORDER BY page_key") == before, "a result changed")
    }
}
