import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

@Suite struct TextCleanupTests {
    @Test func ligaturesAreSpelledOut() {
        #expect(TextCleanup.line("e\u{FB03}cient \u{FB01}rst \u{FB02}ow") == "efficient first flow")
    }

    @Test func invisibleAndControlCharactersGo() {
        #expect(TextCleanup.line("a\u{200B}b\u{FEFF}c\u{0007}d\u{00AD}e") == "abcde")
    }

    @Test func everySpaceBecomesOnePlainSpace() {
        #expect(TextCleanup.line("a\u{00A0}b\u{2009}c\u{3000}d \t e") == "a b c d e")
    }

    @Test func accentsAreComposed() {
        #expect(TextCleanup.line("Cafe\u{0301}") == "Café")
    }

    @Test func mathLettersStay() {
        #expect(TextCleanup.line("𝑒 = mc²") == "𝑒 = mc²")
    }

    @Test func runTogetherWordsAreLetterRunsLongerThan25() {
        #expect(TextCleanup.runTogetherWords("thequickbrownfoxjumpsoverthelazydog and a normal sentence") == 1)
        #expect(TextCleanup.runTogetherWords("internationalization") == 0)
    }
}

@Suite struct DehyphenatorTests {
    let none = Dehyphenator(pageText: "")

    @Test func aSplitDictionaryWordJoins() {
        #expect(none.joins("for exam", "ple, this"))
        #expect(none.joins("several exam", "ples here"))
    }

    @Test func aCompoundKeepsItsHyphen() {
        #expect(!none.joins("using self", "attention layers"))
    }

    @Test func aCapitalOrDigitAfterTheBreakKeepsTheHyphen() {
        #expect(!none.joins("the COVID", "19 data"))
        #expect(!none.joins("Smith", "Jones model"))
    }

    @Test func theSamePageDecidesFirst() {
        let page = Dehyphenator(pageText: "We release the dataset. The data-")
        #expect(page.joins("the data", "set has"))
        let hyphenated = Dehyphenator(pageText: "a well-known result")
        #expect(!hyphenated.joins("is well", "known"))
    }
}

@Suite struct SpaceRepairTests {
    @Test func ocrWordBreaksGoWhereBothTextsAgree() {
        let kit = "Thequickbrown fox"
        let breaks = SpaceRepair.align(kit: kit, ocr: "The quick brown fox")
        #expect(breaks.spaces == [3, 8])
        #expect(breaks.unsure.isEmpty)
    }

    @Test func aBreakAtAMismatchIsNotTrusted() {
        // OCR misread "1" as "l": the break before the misread character has no agreeing
        // neighbour on its left, so it is not taken. The break after it, at the start of the
        // next agreeing run, goes to the agent as a second reading.
        let breaks = SpaceRepair.align(kit: "Lee1and", ocr: "Lee l and")
        #expect(breaks.spaces.isEmpty)
        #expect(breaks.unsure == [4])
    }

    @Test func aWordReadInAnotherOrderIsRepairedWhereItsLettersMatch() {
        // OCR reads the run-together line before the paragraph that PDFKit puts first, so the
        // alignment matches the paragraph and leaves the line unmatched.
        let paragraph = String(repeating: "a long paragraph that both readers agree on ", count: 4)
        let line = "nineALW/WOAHeditionsviatheACLAnthology"
        let kit = paragraph + line
        let breaks = SpaceRepair.align(kit: kit, ocr: "nine ALW/WOAH editions via the ACL Anthology\n" + paragraph)
        let start = paragraph.utf16.count
        #expect(breaks.spaces.isSuperset(of: [4, 12, 20, 23, 26, 29].map { start + $0 }))
    }

    @Test func existingSpacesAreLeftAlone() {
        #expect(SpaceRepair.align(kit: "a b c", ocr: "a b c") == SpaceRepair.Breaks())
    }

    func page(_ texts: [String]) -> PageText {
        let box = Box(x: 0.1, y: 0.1, width: 0.8, height: 0.05)
        return PageText(blocks: texts.map { TextBlock(text: $0, box: box, lines: [TextLine(text: $0, box: box)]) },
                        words: 0, runTogether: 0)
    }

    @Test func aWordTheSecondReadingSplitsIsUnsure() {
        let spans = SpaceRepair.unsureSpans(strict: page(["Data", "We see timeseries are hard."]),
                                            relaxed: page(["Data", "We see time series are hard."]))
        #expect(spans.map(\.readings) == [["timeseries", "time series"]])
        #expect(spans.first?.block == 1)
        #expect(spans.first?.offset == 7)
    }

    @Test func punctuationStaysOutOfTheReadings() {
        let spans = SpaceRepair.unsureSpans(strict: page(["see (inhigh) and (inlow"]),
                                            relaxed: page(["see (in high) and ( inlow"]))
        #expect(spans.map(\.readings) == [["inhigh", "in high"]])
        #expect(spans.first?.offset == 5)
    }

    @Test func onlyBreaksTheWordListBacksCount() {
        let spans = SpaceRepair.unsureSpans(
            strict: page(["See Table and CTRLperforms well on 𝑁test and statistics"]),
            relaxed: page(["See T able and CTRL performs well on 𝑁 test and s tatistics"]))
        #expect(spans.map(\.readings) == [["CTRLperforms", "CTRL performs"], ["𝑁test", "𝑁 test"]])
    }

    func split(_ word: String) -> String? {
        SpaceRepair.splitSpans(page([word]), besides: []).first.flatMap { $0.pickable ? $0.readings[1] : nil }
    }

    @Test func wordsBothReadersRunTogetherSplitIntoCommonWords() {
        #expect(split("singledatasetperconditionandshouldbetreated") == "single dataset per condition and should be treated")
        #expect(split("Alldatasetsarepubliclyavailableoravailableupon") == "All datasets are publicly available or available upon")
        #expect(split("conditionandRU-ENEmotionusesemotionlabels") == "condition and RU-EN Emotion uses emotion labels")
        #expect(split("FirstspecialisthandlingTRENDcorrection") == "First specialist handling TREND correction")
    }

    @Test func englishRunTogetherWithNoCleanSplitIsMarkedToLookAt() {
        let spans = SpaceRepair.splitSpans(page(["Twoprompttemplateswereusedthroughouttheexpe riment."]), besides: [])
        #expect(spans.map(\.readings) == [["Twoprompttemplateswereusedthroughouttheexpe"]])
        #expect(spans.first?.pickable == false)
    }

    @Test func aLongWordInAnotherLanguageStaysUnmarked() {
        #expect(SpaceRepair.splitSpans(page(["Die Donaudampfschifffahrtsgesellschaft fuhr."]), besides: []).isEmpty)
    }

    @Test func namesFromCodeAndWebAddressesStayUnmarked() {
        let text = "Call SpaceRepairRelocateRunTogetherWords at https://example.com/averylongpathsegmentwithoutanyspaces"
            + " or read_the_file_named_averylongnamewithoutanyspaces now"
        #expect(SpaceRepair.splitSpans(page([text]), besides: []).isEmpty)
    }

    @Test func anAccentedLetterIsNoMathsLetter() {
        #expect(SpaceRepair.unsureSpans(strict: page(["un caféchat"]), relaxed: page(["un café chat"])).isEmpty)
    }

    @Test func aLineEndHyphenJoinedDifferentlyKeepsTheWalkInStep() {
        // The relaxed reading joined "exam-" and "ple" where the strict one kept the hyphen.
        let spans = SpaceRepair.unsureSpans(strict: page(["an exam-ple of overallshift here"]),
                                            relaxed: page(["an example of overall shift here"]))
        #expect(spans.map(\.readings) == [["overallshift", "overall shift"]])
    }

    @Test func spacingInsideFormulasIsNoWordDifference() {
        #expect(SpaceRepair.unsureSpans(strict: page(["so x2+3=y holds"]), relaxed: page(["so x2 + 3 = y holds"])).isEmpty)
    }
}

@Suite struct FontCheckTests {
    func atRisk(_ name: String) throws -> Bool {
        let url = repoRoot.appendingPathComponent("testdata/smoke/\(name)")
        let document = try #require(CGPDFDocument(url as CFURL))
        var gaps = 0, risky = 0
        for number in 1...document.numberOfPages {
            let check = FontCheck(page: try #require(document.page(at: number)))
            gaps += check.gaps
            risky += check.risky
        }
        return FontCheck.atRisk(gaps: gaps, risky: risky)
    }

    @Test func thePaperThatLosesSpacesIsAtRisk() throws {
        #expect(try atRisk("arxiv-2609.23257.pdf"))
    }

    @Test func thePageRuleFlagsTheBadPapersPagesAndNoOthers() throws {
        let folder = repoRoot.appendingPathComponent("testdata/smoke")
        var flagged: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".pdf") {
            let document = try #require(CGPDFDocument(folder.appendingPathComponent(name) as CFURL))
            flagged[name] = (1...document.numberOfPages).filter { FontCheck(page: document.page(at: $0)!).pageAtRisk }.count
        }
        // 16 of its 18 pages: a table page and the references page fall under 10%, and the
        // file-level verdict covers them.
        #expect(flagged["arxiv-2609.23257.pdf"] == 16)
        #expect(flagged.filter { $0.key != "arxiv-2609.23257.pdf" }.values.allSatisfy { $0 == 0 })
    }

    @Test func theOtherSamplesAreNot() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: repoRoot.appendingPathComponent("testdata/smoke").path)
            .filter { $0.hasSuffix(".pdf") && $0 != "arxiv-2609.23257.pdf" }
        #expect(names.count == 10)
        for name in names {
            #expect(try !atRisk(name), "\(name)")
        }
    }
}

@Suite struct TextLayerTests {
    @Test func aPageBecomesBlocksWithBoxesInsideThePage() throws {
        let document = try #require(PDFDocument(url: samplePaper))
        let layer = TextLayer.read(try #require(document.page(at: 1)))
        #expect(layer.blocks.count > 5)
        #expect(layer.runTogether == 0)
        for block in layer.blocks {
            #expect(block.box.x >= 0 && block.box.y >= 0)
            #expect(block.box.x + block.box.width <= 1.001 && block.box.y + block.box.height <= 1.001)
            #expect(!block.lines.isEmpty)
        }
    }

    @Test func aTitleWithALigatureKeepsItsBoxOnItsLine() throws {
        // "Dataset Distillation by Influence Matching": the "fl" ligature made PDFKit give the
        // last letter the box of the next line's first letter, so the title's box took two lines.
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2607.16859.pdf")
        let layer = TextLayer.read(try #require(PDFDocument(url: url)?.page(at: 0)))
        let title = try #require(layer.blocks.first)
        #expect(title.text == "Dataset Distillation by Influence Matching")
        #expect(title.box.height < 0.03)
    }

    @Test func smallerRaisedOrLoweredCharactersGetMarks() {
        // "x2 y3 Z": the 2 is smaller and lowered, the 3 smaller and raised, and the Z at the
        // main size but a little raised, as PDFKit reports some table cells.
        let sizes: [CGFloat] = [10, 7, 10, 10, 7, 10, 10]
        let raises: [CGFloat] = [0, -1.5, 0, 0, 3.5, 0, 1.0]
        let glyphs = Glyphs(boxes: Array(repeating: nil, count: 7), sizes: sizes, raises: raises)
        let marks = glyphs.marks([0, 1, 3, 4, 6])
        #expect(marks == [1: "_", 4: "^"])
    }

    @Test func marksWrapTheirCharactersInTheLine() throws {
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2607.16859.pdf")
        let text = TextLayer.read(try #require(PDFDocument(url: url)?.page(at: 0))).text
        #expect(text.contains("Haoru Tan^{1,†} Wang Wang^{1,†}"))
    }

    @Test func blockTextHasNoLineEndHyphensFromSplitWords() throws {
        let document = try #require(PDFDocument(url: samplePaper))
        let text = TextLayer.read(try #require(document.page(at: 1))).text
        // The raw page keeps "exam-\nple"-style breaks; the block text joins them.
        let raw = document.page(at: 1)?.string ?? ""
        let rawBreaks = raw.components(separatedBy: "-\n").count - 1
        let leftover = text.components(separatedBy: "- ").count - 1
        #expect(rawBreaks > 0)
        #expect(leftover < rawBreaks)
    }
}
