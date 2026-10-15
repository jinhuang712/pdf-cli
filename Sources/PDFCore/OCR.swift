import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Apple OCR (DESIGNS.md → Decision: Apple Vision over Tesseract and RapidOCR). On macOS 26
/// the document recognizer returns paragraphs and their lines. Older systems use the text
/// recognizer, whose lines the text layer groups into blocks. `PDF_CLI_OCR=text` forces the
/// older one, so it can be tested on macOS 26 too.
enum OCR {
    struct Line {
        var text: String
        /// Normalized to the rendered image, origin at the lower left.
        var box: CGRect
        var confidence: Double
    }

    struct Paragraph {
        var text: String
        var box: CGRect
        var lines: [Line]
    }

    /// Below this share of OCR's words found in the text layer, a file's text layer is not
    /// trusted, and OCR reads every page. On the eleven samples the share was 0.90–0.99, the
    /// scan's old OCR layer 0.94 included; a layer with a wrong letter in every third word
    /// falls to about 0.67.
    static let sampleThreshold = 0.7

    /// Whether a page's text layer is unusable, so OCR reads the page:
    /// - a scan with no text, or with an old OCR layer of mostly marks, where letters and
    ///   digits make up under 30% of the characters (born-digital pages have about 70–80%);
    /// - a text layer where at least a tenth of the characters, and at least 10, are
    ///   replacement characters, private-use characters or controls.
    static func needed(text: String, images: Int) -> Bool {
        var usable = 0, bad = 0, visible = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            visible += 1
            switch scalar.properties.generalCategory {
            case .privateUse, .unassigned, .control, .surrogate:
                bad += 1
            default:
                if scalar == "\u{FFFD}" { bad += 1 }
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { usable += 1 }
            }
        }
        if images > 0 && (usable < 10 || usable * 10 < visible * 3) { return true }
        return bad >= 10 && bad * 10 >= visible
    }

    static var usesDocumentRecognizer: Bool {
        if #available(macOS 26, *) { return Env.variables["PDF_CLI_OCR"] != "text" }
        return false
    }

    /// Awaited directly from the worker's async code. Run in a task that a blocked thread
    /// waited on, the same request took about twice as long.
    static func recognize(_ image: CGImage) async -> [Paragraph]? {
        if #available(macOS 26, *), usesDocumentRecognizer {
            guard let observations = try? await RecognizeDocumentsRequest().perform(on: image) else { return nil }
            return observations.first?.document.paragraphs.map { paragraph in
                Paragraph(text: paragraph.transcript,
                          box: paragraph.boundingRegion.normalizedPath.boundingBoxOfPath,
                          lines: paragraph.lines.map { line in
                              Line(text: line.topCandidates(1).first?.string ?? line.transcript,
                                   box: line.boundingBox.cgRect, confidence: Double(line.confidence))
                          })
            } ?? []
        }
        return textRecognizerParagraphs(image)
    }

    /// The older text recognizer: lines only, grouped into paragraphs by position.
    static func textRecognizerParagraphs(_ image: CGImage) -> [Paragraph]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox, confidence: Double(candidate.confidence))
        }
        // Group in a top-down frame the size of the image, as the text layer groups PDFKit lines.
        let size = CGSize(width: image.width, height: image.height)
        let raw = lines.map { line in
            TextLayer.RawLine(text: line.text,
                              rect: CGRect(x: line.box.minX * size.width, y: (1 - line.box.maxY) * size.height,
                                           width: line.box.width * size.width, height: line.box.height * size.height),
                              softBreak: false)
        }
        var paragraphs: [Paragraph] = []
        var start = 0
        for block in TextLayer.group(raw, crop: CGRect(origin: .zero, size: size), dehyphenator: Dehyphenator(pageText: "")) {
            let members = Array(lines[start..<start + block.lines.count])
            start += block.lines.count
            let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
            paragraphs.append(Paragraph(text: block.text, box: box, lines: members))
        }
        return paragraphs
    }

    /// Reads a whole page through OCR, as a text layer whose boxes follow the unrotated page,
    /// like PDFKit's.
    static func pageText(_ page: PDFPage) async -> PageText? {
        guard let image = render(page, dpi: 200), let paragraphs = await recognize(image) else { return nil }
        let rotation = ((page.rotation % 360) + 360) % 360
        let dehyphenator = Dehyphenator(pageText: paragraphs.map(\.text).joined(separator: "\n"))
        var blocks: [TextBlock] = []
        var confidences: [Double] = []
        for paragraph in paragraphs {
            let lines = paragraph.lines.compactMap { line -> TextLayer.RawLine? in
                let text = TextCleanup.line(line.text)
                guard !text.isEmpty else { return nil }
                confidences.append(line.confidence)
                return TextLayer.RawLine(text: text, rect: .zero, softBreak: false)
            }
            guard !lines.isEmpty else { continue }
            let lineBoxes = paragraph.lines.filter { !TextCleanup.line($0.text).isEmpty }.map { pageBox($0.box, rotation: rotation) }
            blocks.append(TextBlock(text: TextLayer.join(lines, dehyphenator), box: pageBox(paragraph.box, rotation: rotation),
                                    lines: zip(lines, lineBoxes).map { TextLine(text: $0.text, box: $1) }))
        }
        let joined = blocks.map(\.text).joined(separator: "\n")
        return PageText(blocks: blocks, words: TextCleanup.wordCount(joined),
                        runTogether: TextCleanup.runTogetherWords(joined),
                        confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count))
    }

    /// Maps a box normalized to the upright image, origin lower left, onto the unrotated page,
    /// origin upper left. PDFKit turns a page clockwise by its rotation when it draws it.
    static func pageBox(_ rect: CGRect, rotation: Int) -> Box {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)].map { point -> CGPoint in
            // From the image's lower-left origin to its upper-left origin.
            let u = point.x, down = 1 - point.y
            switch rotation {
            case 90: return CGPoint(x: down, y: 1 - u)
            case 180: return CGPoint(x: 1 - u, y: 1 - down)
            case 270: return CGPoint(x: 1 - down, y: u)
            default: return CGPoint(x: u, y: down)
            }
        }
        let minX = min(corners[0].x, corners[1].x), maxX = max(corners[0].x, corners[1].x)
        let minY = min(corners[0].y, corners[1].y), maxY = max(corners[0].y, corners[1].y)
        return Box(x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
    }

    /// Renders the crop box on white, at `dpi` dots per inch, upright: PDFKit applies the
    /// page's rotation, so a page turned a quarter needs a canvas turned too. With `region`, a
    /// rectangle of the unrotated crop box in points from its lower-left corner, only that part
    /// is drawn.
    static func render(_ page: PDFPage, dpi: Double, region: CGRect? = nil) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let scale = dpi / 72
        let turned = (page.rotation / 90) % 2 != 0
        var size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        if let region { size = region.size }
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 60_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if let region { context.translateBy(x: -region.minX, y: -region.minY) }
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// The sample check (DESIGNS.md → Principles → Silent errors): OCR reads a band of one
    /// text-rich page, and its characters are compared with the text layer's in that band. A
    /// broken font table or an old OCR layer gives words that look real but disagree with the
    /// image. Returns the page, counted from 0, and the agreement, or nil when no page in the
    /// first ten has enough text to sample.
    static func sampleAgreement(_ document: PDFDocument) async -> (page: Int, agreement: Double)? {
        for index in 0..<min(document.pageCount, 10) {
            guard let page = document.page(at: index),
                  (page.string ?? "").unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 300
            else { continue }
            let layer = TextLayer.read(page)
            guard let densest = layer.blocks.max(by: { $0.text.count < $1.text.count }) else { continue }
            let crop = page.bounds(for: .cropBox)
            // A band at least a fifth of the page tall, around the densest block.
            let height = max(densest.box.height, 0.2)
            let top = max(0, min(1 - height, densest.box.y + densest.box.height / 2 - height / 2))
            let bottom = top + height
            func inBand(_ box: Box) -> Bool {
                let middle = box.y + box.height / 2
                return middle >= top && middle <= bottom
            }
            let kit = layer.blocks.flatMap(\.lines).filter { inBand($0.box) }.map(\.text).joined(separator: "\n")
            let rotation = ((page.rotation % 360) + 360) % 360
            let region = CGRect(x: 0, y: CGFloat(1 - bottom) * crop.height,
                                width: crop.width, height: CGFloat(height) * crop.height)
            let image = rotation == 0 ? render(page, dpi: 200, region: region) : render(page, dpi: 200)
            guard let image, let paragraphs = await recognize(image) else { return nil }
            let kept = rotation == 0 ? paragraphs : paragraphs.filter { inBand(pageBox($0.box, rotation: rotation)) }
            let ocr = kept.map(\.text).joined(separator: "\n")
            Env.log("sample check: page \(index + 1), characters \(agreement(kit, ocr)), words \(wordAgreement(layer: kit, ocr: ocr))")
            return (index, wordAgreement(layer: kit, ocr: ocr))
        }
        return nil
    }

    /// The share of OCR's words, four letters or longer, that the text layer spells the same,
    /// matched with spaces left out, so a layer that lost its spaces still agrees. A layer with
    /// one wrong letter per word, as an old OCR layer has, disagrees on most words.
    static func wordAgreement(layer: String, ocr: String) -> Double {
        let letters = String(layer.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
        let words = ocr.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 4 }
        guard !words.isEmpty else { return 1 }
        // `range(of:)` rather than `contains`, which needs macOS 13 for a substring.
        return Double(words.filter { letters.range(of: String($0)) != nil }.count) / Double(words.count)
    }

    /// The share of characters, whitespace left out, that two texts have in common, in order.
    /// 1 means the same text.
    static func agreement(_ first: String, _ second: String) -> Double {
        let a = first.unicodeScalars.filter { !$0.properties.isWhitespace }
        let b = second.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard max(a.count, b.count) > 0 else { return 1 }
        let changes = Array(b).difference(from: Array(a))
        let removed = changes.removals.count
        return Double(a.count - removed) / Double(max(a.count, b.count))
    }
}

/// Checks for development, behind the hidden `pdf debug-ocr` command. They open the PDF in the
/// calling process, so only a developer runs them, on a file they trust.
public enum OCRDiagnostics {
    public static func sampleAgreement(path: String) async -> (page: Int, agreement: Double)? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        return await OCR.sampleAgreement(document)
    }

    /// One page read through OCR, turned by `rotation` degrees first, with the text layer's
    /// boxes for the same page to compare.
    public static func page(path: String, index: Int, rotation: Int) async -> (ocr: PageText?, layer: PageText)? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)), let page = document.page(at: index) else {
            return nil
        }
        let layer = TextLayer.read(page)
        page.rotation = rotation
        return (await OCR.pageText(page), layer)
    }
}
