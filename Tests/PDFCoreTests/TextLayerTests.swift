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
        let spaces = SpaceRepair.align(kit: kit, ocr: "The quick brown fox")
        #expect(spaces == [3, 8])
    }

    @Test func aBreakAtAMismatchIsNotTrusted() {
        // OCR misread "1" as "l": the break before the misread character has no agreeing
        // neighbour on its left, so it is not taken.
        let spaces = SpaceRepair.align(kit: "Lee1and", ocr: "Lee l and")
        #expect(!spaces.contains(3))
    }

    @Test func existingSpacesAreLeftAlone() {
        #expect(SpaceRepair.align(kit: "a b c", ocr: "a b c").isEmpty)
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
