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
        guard let image = render(page, dpi: 200) else { return [] }
        let rendered = DispatchTime.now().uptimeNanoseconds
        guard let ocr = await recognize(image) else { return [] }
        let recognized = DispatchTime.now().uptimeNanoseconds
        let spaces = align(kit: page.string ?? "", ocr: ocr)
        let aligned = DispatchTime.now().uptimeNanoseconds
        Env.log("space repair: render \((rendered - start) / 1_000_000) ms, OCR \((recognized - rendered) / 1_000_000) ms, "
                + "align \((aligned - recognized) / 1_000_000) ms, \(spaces.count) spaces")
        return spaces
    }

    /// Which OCR engine reads the page. macOS 26's document recognizer is the one the M0 spike
    /// scored; older systems use the text recognizer. `PDF_CLI_OCR=text` forces the older one,
    /// so it can be tested on macOS 26 too.
    static func recognize(_ image: CGImage) async -> String? {
        if #available(macOS 26, *), Env.variables["PDF_CLI_OCR"] != "text" {
            return await documentText(image)
        }
        return lineText(image)
    }

    /// Awaited directly from the worker's async code. Run in a task that a blocked thread
    /// waited on, the same request took about twice as long.
    @available(macOS 26, *)
    static func documentText(_ image: CGImage) async -> String? {
        let observations = try? await RecognizeDocumentsRequest().perform(on: image)
        return observations?.first.map { $0.document.paragraphs.map(\.transcript).joined(separator: "\n") }
    }

    static func lineText(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Renders the crop box on white, at `dpi` dots per inch.
    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let scale = dpi / 72
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 60_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
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
