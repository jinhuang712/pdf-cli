import Foundation
import Testing
@testable import PDFCore

@Suite struct OutputTests {
    let box = Box(x: 0.1, y: 0.2, width: 0.8, height: 0.05)

    func page(_ index: Int, _ layer: PageText, method: String = "pdfkit") throws -> Output.Page {
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        return Output.Page(index: index, result: PageResult(status: .ok, method: method, text: layer.text, reason: "",
                                                            parseMillis: 1, data: data), key: "key-\(index)")
    }

    func layer(_ texts: [String]) -> PageText {
        PageText(blocks: texts.map { TextBlock(text: $0, box: box, lines: [TextLine(text: $0, box: box)]) },
                 words: texts.count, runTogether: 0)
    }

    func unsure(_ block: Int, _ a: String, _ b: String, at offset: Int) -> Unsure {
        Unsure(block: block, offset: offset, readings: [a, b], box: box)
    }

    @Test func aGoodPageExitsZeroAndFlagsNothing() throws {
        let report = Output.render(file: "paper.pdf", pageCount: 3, pages: [try page(0, layer(["Hello there."]))])
        #expect(report.exitCode == 0)
        #expect(report.text.hasPrefix("paper.pdf · 3 pages · read p.1 · flagged: none"))
        #expect(report.text.contains("p.1 ¶1 · 0.10,0.20,0.80,0.05\nHello there."))
    }

    @Test func aFailedPageGetsAFailureBlockWithACrop() throws {
        let failed = Output.Page(index: 6, result: .failed("time limit: the page took more than 30 s"), key: "k")
        let report = Output.render(file: "my paper.pdf", pageCount: 9, pages: [failed])
        #expect(report.exitCode == 3)
        #expect(report.text.contains("⚠ p.7 failed: time limit: the page took more than 30 s"))
        #expect(report.text.contains("read it as an image: pdf crop 'my paper.pdf' --page 7"))
        #expect(report.text.contains("flagged: p.7 (failed)"))
    }

    @Test func aPageWhoseOCRReadingsDisagreeIsLowQualityAsAWhole() throws {
        var read = layer(["Xeeris aubecription"])
        read.agreement = 0.62
        let report = Output.render(file: "scan.pdf", pageCount: 2,
                                   pages: [try page(0, read, method: "ocr"), try page(1, layer(["Fine text."]))])
        #expect(report.exitCode == 2)
        #expect(report.text.contains("⚠ p.1 low-quality: two OCR readings of the page disagree (score 0.62)"))
        #expect(report.text.contains("raw: pdf read scan.pdf --page 1 --raw"))
        #expect(!report.text.contains("Xeeris"))
        #expect(report.text.contains("set aside: 1 doubtful block (show: --raw)"))
        let raw = Output.render(file: "scan.pdf", pageCount: 2, pages: [try page(0, read, method: "ocr")], raw: true)
        #expect(raw.text.contains("[low-quality] Xeeris aubecription"))
    }

    @Test func oneDoubtfulBlockIsSetAsideAndTheRestReads() throws {
        var read = layer(["Good paragraph.", "Smudged lines"])
        read.blocks[1].agreement = 0.5
        read.agreement = 0.9
        let report = Output.render(file: "scan.pdf", pageCount: 1, pages: [try page(0, read, method: "ocr")])
        #expect(report.exitCode == 2)
        #expect(report.text.contains("Good paragraph."))
        #expect(report.text.contains("⚠ p.1 ¶2 low-quality: two OCR readings of this block disagree (score 0.50)"))
        #expect(report.text.contains("--page 1 --bbox "))
        #expect(!report.text.contains("Smudged"))
    }

    @Test func unsureWordsShowBothReadingsUntilPicked() throws {
        var read = layer(["Intro.", "CTRLperforms well and overallshift too."])
        read.unsure = [unsure(1, "CTRLperforms", "CTRL performs", at: 0), unsure(1, "overallshift", "overall shift", at: 22)]
        let pages = [try page(1, read)]
        let report = Output.render(file: "paper.pdf", pageCount: 5, pages: pages)
        #expect(report.exitCode == 2)
        #expect(report.text.contains("flagged: p.2 (unsure)"))
        #expect(report.text.contains("[a] CTRLperforms … overallshift\n  [b] CTRL performs … overall shift"))
        #expect(report.text.contains("pick: pdf pick paper.pdf p2.2 a  (or b)"))

        let pick = Pick(pageKey: "key-1", block: 1, readings: ["CTRLperforms … overallshift", "CTRL performs … overall shift"],
                        chosen: 1, pickedAt: Date())
        let picked = Output.render(file: "paper.pdf", pageCount: 5, pages: pages, picks: ["key-1": [pick]])
        #expect(picked.exitCode == 0)
        #expect(picked.text.contains("CTRL performs [picked "))
        #expect(picked.text.contains("overall shift [picked "))
        #expect(!picked.text.contains("unsure"))
    }

    @Test func aPickForOtherReadingsIsIgnored() throws {
        var read = layer(["CTRLperforms well."])
        read.unsure = [unsure(0, "CTRLperforms", "CTRL performs", at: 0)]
        let stale = Pick(pageKey: "key-0", block: 0, readings: ["CTRLworks", "CTRL works"], chosen: 1, pickedAt: Date())
        let report = Output.render(file: "paper.pdf", pageCount: 1, pages: [try page(0, read)], picks: ["key-0": [stale]])
        #expect(report.text.contains("unsure: two readings differ"))
    }

    @Test func theOldOCRLayerShowsWithRaw() throws {
        var read = layer(["Read by OCR."])
        read.replacedText = "Rcad bv 0CR."
        read.agreement = 0.95
        let pages = [try page(0, read, method: "ocr")]
        #expect(Output.render(file: "scan.pdf", pageCount: 1, pages: pages).text.contains("set aside: 1 old OCR layer"))
        #expect(Output.render(file: "scan.pdf", pageCount: 1, pages: pages, raw: true).text.contains("[old OCR] Rcad bv 0CR."))
    }

    @Test func aFilePDFKitSavedCarriesAWarning() throws {
        let report = Output.render(file: "paper.pdf", pageCount: 1, pages: [try page(0, layer(["Text."]))], savedByPDFKit: true)
        #expect(report.text.components(separatedBy: "\n")[0].contains("⚠ made or last saved by macOS PDFKit"))
    }

    @Test func aGarbledLayerThatOCRCouldNotReplaceIsLowQuality() throws {
        var read = layer(["~~~ ### abc"])
        read.layerScore = 0.27
        let quality = Quality.judge(try page(0, read, method: "pdfkit+ocr-failed").result)
        #expect(quality.status == .lowQuality)
        #expect(quality.doubts.first?.score == 0.27)
        #expect(quality.wholePage)
    }

    @Test func wordsWithNoSecondReadingAskTheAgentToLook() throws {
        var read = layer(["Twoprompttemplateswereused here."])
        read.unsure = [Unsure(block: 0, offset: 0, readings: ["Twoprompttemplateswereused"], box: box)]
        let report = Output.render(file: "paper.pdf", pageCount: 1, pages: [try page(0, read)])
        #expect(report.exitCode == 2)
        #expect(report.text.contains("⚠ p.1 ¶1 unsure: words run together, and no reading splits them"))
        #expect(report.text.contains("look: pdf crop paper.pdf --page 1 --bbox "))
        #expect(!report.text.contains("pdf pick"))
    }

    func paragraphs(_ count: Int, words: Int) -> PageText {
        layer((1...count).map { number in Array(repeating: "word\(number)", count: words).joined(separator: " ") })
    }

    @Test func theBudgetStopsBetweenBlocksAndSaysHowToGoOn() throws {
        var document = Output.Document(file: "paper.pdf", pageCount: 3, budget: 200)
        var added = true
        for index in 0..<3 where added { added = document.add(try page(index, paragraphs(4, words: 40))) }
        let report = document.report()
        #expect(!added)
        #expect(report.text.hasSuffix("next: pdf read paper.pdf --from p1.3\n"))
        #expect(report.text.contains("word2 word2"))
        #expect(!report.text.contains("word3"))
        #expect(report.text.contains("read p.1 ·"))
    }

    @Test func aBlockLargerThanTheBudgetIsCutInsideAndGoesOnFromTheCut() throws {
        var document = Output.Document(file: "paper.pdf", pageCount: 1, budget: 120)
        #expect(!document.add(try page(0, paragraphs(1, words: 200))))
        let next = try #require(document.next)
        #expect(next.hasPrefix("pdf read paper.pdf --from p1.1:"))
        let offset = try #require(Int(next.split(separator: ":").last!))
        var rest = Output.Document(file: "paper.pdf", pageCount: 1, budget: nil)
        _ = rest.add(try page(0, paragraphs(1, words: 200)), from: 1, offset: offset)
        let shown = try #require(document.blocks.last?.text), more = try #require(rest.blocks.last?.text)
        let whole = Array(repeating: "word1", count: 200).joined(separator: " ")
        #expect(String(shown.dropLast()) + String(more.dropFirst()) == whole)
    }

    @Test func readsChainedThroughTheirNextLinesShowTheWholeBlockOnce() throws {
        let whole = Array(repeating: "word1", count: 600).joined(separator: " ")
        var shown = "", block: Int? = nil, offset: Int? = nil, reads = 0
        repeat {
            reads += 1
            var document = Output.Document(file: "paper.pdf", pageCount: 1, budget: 120)
            let done = document.add(try page(0, paragraphs(1, words: 600)), from: block, offset: offset)
            var text = try #require(document.blocks.last?.text)
            if offset != nil { text = String(text.dropFirst()) }
            if !done { text = String(text.dropLast()) }
            shown += text
            if done { break }
            let next = try #require(document.next)
            let place = try #require(next.split(separator: " ").last)
            block = 1
            offset = Int(place.split(separator: ":").last!)
        } while reads < 50
        #expect(shown == whole)
        #expect(reads > 2)
    }

    @Test func aDoubtLargerThanTheBudgetStillGoesOutSoTheReadMovesOn() throws {
        var read = layer(Array(repeating: "Smudged words here", count: 60))
        read.agreement = 0.3
        var document = Output.Document(file: "scan.pdf", pageCount: 2, raw: true, budget: 50)
        #expect(document.add(try page(0, read, method: "ocr")))
        #expect(document.blocks.contains { $0.kind == .doubtful })
        #expect(!document.add(try page(1, layer(["Next page."]))))
        #expect(document.next == "pdf read scan.pdf --from p2")
    }

    @Test func aPageWhoseHeadingAloneWentOutIsNotCountedAsRead() throws {
        var flaggedPage = layer(["CTRLperforms well."])
        flaggedPage.unsure = [unsure(0, "CTRLperforms", "CTRL performs", at: 0)]
        var document = Output.Document(file: "paper.pdf", pageCount: 2, budget: 40)
        _ = document.add(try page(0, layer(["A short first page."])))
        _ = document.add(try page(1, flaggedPage))
        let report = document.report()
        #expect(report.text.contains("read p.1 ·"))
        #expect(report.text.contains("flagged: none"))
        #expect(report.exitCode == 0)
    }

    @Test func aReadThatGoesOnSkipsTheBlocksAlreadyShown() throws {
        var document = Output.Document(file: "paper.pdf", pageCount: 1)
        _ = document.add(try page(0, paragraphs(4, words: 3)), from: 3)
        #expect(document.blocks.compactMap(\.block) == [3, 4])
    }

    @Test func everyBlockInJSONHasAPageAndAPosition() throws {
        var read = layer(["Fine.", "CTRLperforms well.", "Smudged"])
        read.unsure = [unsure(1, "CTRLperforms", "CTRL performs", at: 0)]
        read.blocks[2].agreement = 0.4
        read.agreement = 0.9
        read.replacedText = "old"
        var document = Output.Document(file: "scan.pdf", pageCount: 2, raw: true)
        _ = document.add(try page(0, read, method: "ocr"))
        _ = document.add(Output.Page(index: 1, result: .failed("time limit"), key: "k"))
        let body = try #require(try JSONSerialization.jsonObject(with: document.json()) as? [String: Any])
        let blocks = try #require(body["blocks"] as? [[String: Any]])
        #expect(Set(blocks.compactMap { $0["kind"] as? String })
                == ["page", "text", "unsure", "failure", "low-quality-text", "old-ocr"])
        for block in blocks {
            #expect(block["page"] is Int)
            #expect((block["bbox"] as? [Double])?.count == 4)
        }
    }

    @Test func tokensAreCountedRoughly() {
        #expect(Output.tokens("abcd efgh") == 3)
        #expect(Output.tokens("数据集") == 3)
    }

    @Test func pageRangesAndQuoting() {
        #expect(Output.ranges([1, 2, 3, 7, 9, 10]) == "p.1–3, p.7, p.9–10")
        #expect(Output.quoted("/tmp/a.pdf") == "/tmp/a.pdf")
        #expect(Output.quoted("it's here.pdf") == "'it'\\''s here.pdf'")
        #expect(Output.quoted("~notes.pdf") == "'~notes.pdf'")
        #expect(Output.quoted("-x.pdf") == "./-x.pdf")
    }
}
