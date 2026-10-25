import Foundation
import PDFKit
import Testing

@testable import pdf

/// `pdf reparse` (ROADMAP.md → M2.10): it replaces the cached results of the pages it reads again,
/// keeps the picks whose readings the page still offers and clears the others (M2.23), keeps transcripts, follows the contract of M2.15, and a command that dies
/// half way changes nothing. The tests run the built `pdf` with a fresh home, as an agent would.
@Suite(.serialized) struct ReparseTests {
    static let root = OutputContractTests.root
    static let paper = root.appendingPathComponent("testdata/smoke/arxiv-2609.23257.pdf").path
    static let scan = root.appendingPathComponent("testdata/smoke/scan-naca-report-1034.pdf").path
    static let small = root.appendingPathComponent("testdata/safety/carries-comments.pdf").path
    static let regions = root.appendingPathComponent("testdata/safety/hidden-figure-alt.pdf").path
    static let manyLinks = root.appendingPathComponent("testdata/safety/carries-many-links.pdf").path

    static func pdf(_ arguments: [String], home: URL, stdin: String = "") throws -> OutputContractTests.Run {
        try OutputContractTests.pdf(arguments, home: home, stdin: stdin)
    }

    /// Runs `pdf` with extra environment variables, a fresh home given, and `stdin` on standard input.
    static func pdf(_ arguments: [String], home: URL, environment extra: [String: String], stdin: String = "") throws -> OutputContractTests.Run {
        let process = Process()
        process.executableURL = try #require(OutputContractTests.binary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PDF_CLI_HOME"] = home.path
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return OutputContractTests.Run(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
            errors: String(decoding: errorData, as: UTF8.self))
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

    @Test func aReparseReplacesTheCachedResultsKeepsAPickOfTheSameReadingsAndLeavesOtherPagesAlone() async throws {
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
        // The new reading offers the same words, so the pick stays and is counted (M2.23).
        #expect(object["picksCleared"] as? Int == 0 && object["picksKept"] as? Int == 1, "\(object)")
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
        // The pick is still there, and still applies.
        let again = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        #expect(again.output.contains("[picked"), "\(again.output.prefix(400))")
        #expect(try Self.sql(home, "Support/library.sqlite", "SELECT count(*) FROM pick") == "1")
        // No runner is left parsing the other pages of the file.
        #expect(!Self.running(file))
        // The other pages were not parsed by the reparse: still planted.
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result WHERE reason = 'planted'") == String((Int(cached) ?? 0) - 1))
    }

    /// Picks and reparse (M2.23): a pick stays while the page still offers the readings it was made
    /// for, and goes when it does not; the summary and `--json` count both. A chunk of one page
    /// checks its own pick, and the runner has settled it before the command ends.
    @Test func aReparseKeepsPicksOfTheSameReadingsAndClearsTheOthersChunkByChunk() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--budget", "all"], home: home)
        try await DryRunTests.settle(home)
        #expect(try Self.pdf(["pick", file, "p2.2", "b"], home: home).status == 0)
        #expect(try Self.pdf(["pick", file, "p3.5", "a"], home: home).status == 0)
        #expect(try Self.pdf(["pick", file, "p6.38", "b"], home: home).status == 0)
        // Page 3's pick was made for other words than the page offers now: planted in the pick's own table.
        try Self.sql(home, "Support/library.sqlite", "UPDATE pick SET reading_a = 'planted words' WHERE block = 4")
        #expect(try Self.sql(home, "Support/library.sqlite", "SELECT count(*) FROM pick WHERE reading_a = 'planted words'") == "1")

        // Chunks of one page: each page's pick is checked as its chunk is replaced.
        let run = try Self.pdf(["reparse", file, "--page", "2,3,6", "--json"], home: home, environment: ["PDF_CLI_REPARSE_CHUNK": "1"])
        let object = try #require(run.json, "\(run.output.prefix(300))")
        #expect(object["picksKept"] as? Int == 2 && object["picksCleared"] as? Int == 1, "\(object)")
        #expect(try Self.sql(home, "Support/library.sqlite", "SELECT count(*) FROM pick") == "2")
        #expect(try Self.sql(home, "Support/library.sqlite", "SELECT count(*) FROM pick WHERE block = 4") == "0")
        let text = try Self.pdf(["reparse", file, "--page", "2"], home: home)
        #expect(text.output.contains("kept 1 pick") && !text.output.contains("cleared"), "\(text.output.prefix(300))")
        let read = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        #expect(read.output.contains("[picked"))
        // OCR reads the page by another method: its readings are not the layer's, so the pick goes.
        let ocr = try Self.pdf(["reparse", file, "--page", "2", "--step", "ocr"], home: home)
        #expect(ocr.output.contains("cleared 1 pick") && !ocr.output.contains("kept 1 pick"), "\(ocr.output.prefix(300))")
        #expect(try Self.sql(home, "Support/library.sqlite", "SELECT count(*) FROM pick WHERE block = 1") == "0")
        #expect(!Self.running(file))
    }

    /// A page's links belong to the file's version, not to the page's parse (M2.21b): a reparse of
    /// one page leaves its links and every other page's as they were, a dry-run `rm` leaves them,
    /// and `rm` removes them.
    @Test func aReparseLeavesThePagesLinksAndRmRemovesThem() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.manyLinks, to: home)
        let link = "[Reference 5 of page 2](https://example.org/p2/5)"
        let first = try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home)
        #expect(first.output.contains(link), "\(first.output.prefix(400))")
        try await DryRunTests.settle(home)
        #expect(try Self.cache(home, "SELECT count(*) FROM page_annotation") == "3")
        let before = try Self.cache(home, "SELECT page_index, length(data), more FROM page_annotation ORDER BY page_index")
        _ = try Self.pdf(["reparse", file, "--page", "2", "--json"], home: home)
        #expect(try Self.cache(home, "SELECT page_index, length(data), more FROM page_annotation ORDER BY page_index") == before)
        #expect(try Self.pdf(["read", file, "--page", "2", "--budget", "all"], home: home).output.contains(link))
        #expect(!Self.running(file))
        _ = try Self.pdf(["rm", file, "--dry-run"], home: home)
        #expect(try Self.cache(home, "SELECT count(*) FROM page_annotation") == "3")
        #expect(try Self.pdf(["rm", file], home: home).status == 0)
        #expect(try Self.cache(home, "SELECT count(*) FROM page_annotation") == "0")
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
        for key in ["file", "id", "step", "reparsed", "pages", "flagged", "changes", "kept", "picksKept", "picksCleared"] {
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

    /// What OCR reads of a page PDFKit draws with hidden text is no more visible than the layer's
    /// words: text under an annotation and in a layer switched off stays under its marker
    /// (M2.10's review, H1; goal G16).
    @Test func readAgainByOCRKeepsHiddenTextHidden() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.root.appendingPathComponent("testdata/hidden/hidden.pdf").path, to: home)
        let pages = "35,43"
        let run = try Self.pdf(["reparse", file, "--page", pages, "--step", "ocr"], home: home)
        #expect([0, 2].contains(run.status), "\(run.output.prefix(300))")
        let normal = try Self.pdf(["read", file, "--page", pages, "--budget", "all"], home: home)
        #expect(!normal.output.contains("PLANTED"), "hidden words read as text: \(normal.output.prefix(600))")
        #expect(normal.output.contains("[hidden:"), "no marker: \(normal.output.prefix(600))")
        #expect(normal.output.contains("hidden text: 2 places"), "\(normal.output.prefix(300))")
        #expect(try Self.pdf(["search", file, "PLANTED"], home: home).output.contains("0 hits"))
        let shown = try Self.pdf(["read", file, "--page", "35", "--budget", "all", "--show", "hidden"], home: home)
        #expect(shown.output.contains("PLANTED"), "--show hidden still shows the words: \(shown.output.prefix(600))")
        #expect(try Self.cache(home, "SELECT count(*) FROM page_result WHERE method = 'ocr'") == "2")
        #expect(!Self.running(file))
    }

    /// Text PDFKit leaves out of its text, drawn in letters in a form switched off or under an
    /// annotation, is read by OCR from the rendering: it stays under its marker too, on the first
    /// reading of a scan and after a reparse (M2.19; goal G16). Page 3 is the control, a reader's
    /// own text from the same font, which OCR shows.
    @Test func ocrOfTextPDFKitLeavesOutKeepsHiddenTextHidden() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.root.appendingPathComponent("testdata/hidden/unread-hidden.pdf").path, to: home)
        let first = try Self.pdf(["read", file, "--page", "4", "--budget", "all"], home: home)
        #expect(!first.output.contains("PLANTED") && first.output.contains("[hidden:"), "scan: \(first.output.prefix(600))")
        let run = try Self.pdf(["reparse", file, "--step", "ocr"], home: home)
        #expect([0, 2].contains(run.status), "\(run.output.prefix(300))")
        let normal = try Self.pdf(["read", file, "--budget", "all"], home: home)
        #expect(!normal.output.contains("PLANTED"), "hidden words read as text: \(normal.output.prefix(900))")
        #expect(normal.output.contains("hidden text: 3 places"), "\(normal.output.prefix(400))")
        #expect(normal.output.contains("LAND TEAM"), "the control reads as text: \(normal.output.prefix(900))")
        #expect(try Self.pdf(["search", file, "PLANTED"], home: home).output.contains("0 hits"))
        let shown = try Self.pdf(["read", file, "--page", "1", "--budget", "all", "--show", "hidden"], home: home)
        #expect(shown.output.contains("PLANTED"), "\(shown.output.prefix(600))")
        #expect(!Self.running(file))
    }

    /// The same, in the shapes M2.19's review found: strings of two glyphs, spelled elsewhere on the page,
    /// rotated, 110 of them, under an annotation with a border, between visible lines, and in a word
    /// whited out inside a line. A visible word in a gap of a visible line, and text in a
    /// border-only annotation, stay text. Nine forms deep the check does not reach, and says so.
    @Test func ocrOfHiddenTextInOtherShapesStaysHidden() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.root.appendingPathComponent("testdata/hidden/unread-hidden-more.pdf").path, to: home)
        let run = try Self.pdf(["reparse", file, "--step", "ocr"], home: home)
        #expect([0, 2].contains(run.status), "\(run.output.prefix(300))")
        func page(_ number: Int) throws -> String {
            try Self.pdf(["read", file, "--page", "\(number)", "--budget", "all"], home: home).output
        }
        for number in [1, 2, 3, 4, 5, 7, 8, 9] {
            let output = try page(number)
            for word in ["PLANTED", "TRICK", "ROTATED", "UPWARD"] {
                #expect(!output.contains(word), "p.\(number): \(word) read as text: \(output.prefix(600))")
            }
            if number != 3 { #expect(output.contains("[hidden:"), "p.\(number): no marker: \(output.prefix(600))") }
        }
        #expect(try page(5).contains("Visible words before the trick"), "visible lines under the 110 strings")
        #expect(try page(6).contains("hidden-text check incomplete"), "nine forms deep: the check says it is incomplete")
        let box = try page(10)
        #expect(box.contains("LAND TEAM") && !box.contains("[hidden:"), "\(box.prefix(600))")
        let gap = try page(11)
        #expect(gap.contains("LAND TEAM MORE WORDS HERE") && !gap.contains("[hidden:"), "\(gap.prefix(600))")
        #expect(!Self.running(file))
    }

    /// A new reading that fails never replaces one that read well: the page keeps its result, the
    /// summary counts it, the command ends 2, and `reparsed` counts replaced pages only.
    @Test func aFailedNewReadingKeepsTheOldResultAndIsCounted() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.small, to: home)
        _ = try Self.pdf(["read", file], home: home)
        try await DryRunTests.settle(home)
        let before = try Self.cache(home, "SELECT page_key || status || parsed_at FROM page_result")
        let fault = ["PDF_CLI_TEST_FAULT": "crash:0"]
        let text = try Self.pdf(["reparse", file], home: home, environment: fault)
        #expect(text.status == 2, "\(text.output)")
        #expect(text.output.contains("1 kept the old result") && text.output.contains("reparsed 0 pages"), "\(text.output)")
        #expect(text.output.contains("p.1: kept the old result, the new reading failed"), "\(text.output)")
        let json = try Self.pdf(["reparse", file, "--json"], home: home, environment: fault)
        #expect(json.status == 2)
        #expect(json.json?["reparsed"] as? Int == 0 && (json.json?["pages"] as? [Int]) == [])
        let kept = try #require((json.json?["kept"] as? [[String: Any]])?.first, "\(json.output)")
        #expect(kept["page"] as? Int == 1 && kept["reason"] is String)
        #expect(try Self.cache(home, "SELECT page_key || status || parsed_at FROM page_result") == before)
        // Without the fault the page is replaced, and exit 0.
        let fine = try Self.pdf(["reparse", file], home: home)
        #expect(fine.status == 0 && fine.output.contains("reparsed 1 page "), "\(fine.output)")
    }

    /// A locked file that reads from the cache keeps its results when the password is missing or
    /// wrong; its failure line names `pdf reparse` (M2.10's review, M1).
    @Test func aLockedFileKeepsItsResultsWithoutThePassword() async throws {
        let home = try OutputContractTests.freshHome()
        let locked = home.appendingPathComponent("locked.pdf")
        let source = try #require(PDFDocument(url: URL(fileURLWithPath: Self.small)))
        #expect(source.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        let file = locked.path
        let first = try Self.pdf(["reparse", file, "--password-stdin", "--json"], home: home, stdin: "pw\n")
        #expect(first.status == 0, "\(first.output)")
        let rows = try Self.cache(home, "SELECT count(*) FROM page_result")
        for (arguments, stdin) in [(["reparse", file], ""), (["reparse", file, "--password-stdin"], "wrong\n")] {
            let run = try Self.pdf(arguments, home: home, stdin: stdin)
            #expect(run.status == 3, "\(run.output)")
            #expect(run.output.hasPrefix("\(file): failed: locked by a password"), "\(run.output)")
            #expect(run.output.contains("pdf reparse \(file) --password-stdin"), "\(run.output)")
            #expect(try Self.cache(home, "SELECT count(*) FROM page_result") == rows)
            #expect(try Self.cache(home, "SELECT count(*) FROM file_entry WHERE doc_id IS NOT NULL") == "1", "a failure was written")
        }
        #expect(try Self.pdf(["ls"], home: home).output.contains("· ok ·"))
        #expect(try Self.pdf(["read", file], home: home).status == 0, "the file still reads from the cache")
    }

    /// A reparse never takes the pool's first slot, which stays free for a new file's first page
    /// (M2.10's review, P1).
    @Test func aReparseKeepsSlotZeroFree() async throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.paper, to: home)
        _ = try Self.pdf(["read", file, "--page", "1"], home: home)
        try await DryRunTests.settle(home)
        let log = home.appendingPathComponent("log.txt")
        let run = try Self.pdf(["reparse", file, "--page", "1-6"], home: home, environment: ["PDF_CLI_LOG": log.path])
        #expect([0, 2].contains(run.status), "\(run.output)")
        let lines = (try String(contentsOf: log, encoding: .utf8)).split(separator: "\n").filter { $0.contains(": parse ") }
        #expect(!lines.isEmpty)
        for line in lines { #expect(!line.contains("in slot 0"), "\(line)") }
    }

    /// A first reading is no change of status, and a reparse reports what happened to the cache.
    @Test func aFirstReadingIsNoChangeAndTheSummaryCountsOnlyReplacedPages() throws {
        let home = try OutputContractTests.freshHome()
        let file = try Self.copy(Self.paper, to: home)
        let run = try Self.pdf(["reparse", file, "--page", "2", "--json"], home: home)
        #expect(run.status == 2)
        #expect(run.json?["neverRead"] as? Bool == true)
        let flagged = try #require((run.json?["flaggedPages"] as? [[String: Any]])?.first)
        #expect(flagged["page"] as? Int == 2 && flagged["status"] as? String == "unsure", "page numbers are numbers: \(run.output)")
        let change = try #require((run.json?["changes"] as? [[String: Any]])?.first)
        #expect(change["before"] is NSNull, "\(run.output)")
        let text = try Self.pdf(["reparse", file, "--page", "3"], home: home)
        #expect(text.output.contains("no page changed status"), "\(text.output)")
        #expect(!text.output.contains("only parsed"), "\(text.output)")
    }
}
