import CoreGraphics
import Foundation
import PDFKit
import Vision

/// The space repair for a file at risk (DESIGNS.md → Decision: Apple OCR word breaks over
/// PDFium for fonts that hide spaces). PDFKit's characters stay; Apple OCR reads the rendered
/// page, and only its word breaks are taken, where the two texts agree on the characters
/// around them.
enum SpaceRepair {
    /// UTF-16 offsets in `page.string` before which a space belongs.
    static func spacesBefore(_ page: PDFPage) async -> Set<Int> {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let image = OCR.render(page, dpi: 200) else { return [] }
        let rendered = DispatchTime.now().uptimeNanoseconds
        guard let paragraphs = await OCR.recognize(image) else { return [] }
        let recognized = DispatchTime.now().uptimeNanoseconds
        let spaces = align(kit: page.string ?? "", ocr: paragraphs.map(\.text).joined(separator: "\n"))
        let aligned = DispatchTime.now().uptimeNanoseconds
        Env.log("space repair: render \((rendered - start) / 1_000_000) ms, OCR \((recognized - rendered) / 1_000_000) ms, "
                + "align \((aligned - recognized) / 1_000_000) ms, \(spaces.count) spaces")
        return spaces
    }

    /// Finds where OCR puts a space that PDFKit lacks. The two texts are aligned character by
    /// character, whitespace left out. A space counts only inside a run where both sides agree:
    /// the first character of a run has no reliable neighbour, as the spike's method had it.
    static func align(kit: String, ocr: String) -> Set<Int> {
        var kitScalars: [Unicode.Scalar] = []
        var kitOffsets: [Int] = []
        var kitGap: [Bool] = []
        var offset = 0
        var gap = false
        for scalar in kit.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
            } else {
                kitScalars.append(scalar)
                kitOffsets.append(offset)
                kitGap.append(gap)
                gap = false
            }
            offset += scalar.utf16.count
        }
        var ocrScalars: [Unicode.Scalar] = []
        var ocrGap: [Bool] = []
        gap = false
        for scalar in ocr.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
            } else {
                ocrScalars.append(scalar)
                ocrGap.append(gap)
                gap = false
            }
        }

        var removed = Set<Int>(), inserted = Set<Int>()
        for change in ocrScalars.difference(from: kitScalars) {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var spaces = Set<Int>()
        var i = 0, j = 0
        var inRun = false
        while i < kitScalars.count, j < ocrScalars.count {
            if removed.contains(i) {
                i += 1
                inRun = false
            } else if inserted.contains(j) {
                j += 1
                inRun = false
            } else {
                if inRun, ocrGap[j], !kitGap[i] { spaces.insert(kitOffsets[i]) }
                inRun = true
                i += 1
                j += 1
            }
        }
        return spaces
    }
}
