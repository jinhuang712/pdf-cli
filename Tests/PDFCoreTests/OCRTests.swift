import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

let ocrFolder = repoRoot.appendingPathComponent("testdata/ocr")

@Suite struct OCRTriggerTests {
    @Test func aScanWithNoTextGoesToOCR() {
        #expect(OCR.needed(text: "", images: 1))
        #expect(OCR.needed(text: " 12 ", images: 1))
    }

    @Test func aBlankPageWithNoImageDoesNot() {
        #expect(!OCR.needed(text: "", images: 0))
    }

    @Test func anOldOCRLayerOfMostlyMarksGoesToOCR() {
        let noise = "‘ : , -- . ‘ \\ I ‘ L( ’ . ,. ,’ I ‘ L , I_ ., ,: : .: .L .- _- - ,,- :/-/ - : i ’ ,_ -. - ;;y-"
        #expect(OCR.needed(text: noise, images: 3))
    }

    @Test func aNormalPageWithFiguresKeepsItsTextLayer() {
        let text = String(repeating: "The model reaches 92.4% accuracy on the held-out set (Table 2). ", count: 20)
        #expect(!OCR.needed(text: text, images: 4))
    }

    @Test func aGarbledTextLayerGoesToOCR() {
        let garbled = String(repeating: "\u{E001}\u{E017}\u{E02A} ", count: 20) + "some real words here"
        #expect(OCR.needed(text: garbled, images: 0))
    }
}

@Suite struct SampleCheckTests {
    @Test func wordsMatchEvenWhenTheLayerLostItsSpaces() {
        #expect(OCR.wordAgreement(layer: "Thequickbrownfoxjumpsoverthelazydog", ocr: "The quick brown fox jumps over the lazy dog") == 1)
    }

    @Test func aLayerWithAWrongLetterPerWordDisagrees() {
        #expect(OCR.wordAgreement(layer: "Il\\jVESTIGATION of spoller allerons", ocr: "INVESTIGATION of spoiler ailerons") == 0)
    }

    @Test func theFixturesSeparate() async throws {
        let right = try #require(PDFDocument(url: ocrFolder.appendingPathComponent("scan-right-layer.pdf")))
        let wrong = try #require(PDFDocument(url: ocrFolder.appendingPathComponent("scan-wrong-layer.pdf")))
        let none = try #require(PDFDocument(url: ocrFolder.appendingPathComponent("scan-no-text.pdf")))
        let rightAgreement = try #require(await OCR.sampleAgreement(right)).agreement
        let wrongAgreement = try #require(await OCR.sampleAgreement(wrong)).agreement
        #expect(rightAgreement >= OCR.sampleThreshold)
        #expect(wrongAgreement < OCR.sampleThreshold)
        #expect(await OCR.sampleAgreement(none) == nil)
    }

    @Test func everyBornDigitalSampleAndTheOldScanPass() async throws {
        let folder = repoRoot.appendingPathComponent("testdata/smoke")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".pdf") {
            let document = try #require(PDFDocument(url: folder.appendingPathComponent(name)))
            let agreement = try #require(await OCR.sampleAgreement(document), "\(name)").agreement
            #expect(agreement >= OCR.sampleThreshold, "\(name): \(agreement)")
        }
    }
}

@Suite struct OCRPageTests {
    @Test func aScannedPageBecomesBlocksInsideThePage() async throws {
        let document = try #require(PDFDocument(url: ocrFolder.appendingPathComponent("scan-no-text.pdf")))
        let page = try #require(document.page(at: 0))
        let layer = try #require(await OCR.pageText(page))
        #expect(layer.words > 300)
        #expect(layer.confidence != nil)
        for block in layer.blocks {
            #expect(block.box.x >= -0.001 && block.box.y >= -0.001)
            #expect(block.box.x + block.box.width <= 1.001 && block.box.y + block.box.height <= 1.001)
        }
    }

    @Test func boxesOnARotatedPageMapBackToThePage() async throws {
        let url = repoRoot.appendingPathComponent("testdata/smoke/arxiv-2608.04589.pdf")
        for rotation in [90, 180, 270] {
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 1))
            let reference = TextLayer.read(page).blocks.map { ($0.box.x + $0.box.width / 2, $0.box.y + $0.box.height / 2) }
            page.rotation = rotation
            let layer = try #require(await OCR.pageText(page))
            let offsets = layer.blocks.map { block -> Double in
                let x = block.box.x + block.box.width / 2, y = block.box.y + block.box.height / 2
                return reference.map { hypot($0.0 - x, $0.1 - y) }.min() ?? 1
            }.sorted()
            #expect(offsets[offsets.count / 2] < 0.05, "rotation \(rotation)")
        }
    }
}
