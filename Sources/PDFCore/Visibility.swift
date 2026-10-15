import CoreGraphics
import Foundation
import PDFKit

/// Why a reader cannot see a run of text (FEATURES.md → F9).
public enum HiddenReason: Int, Codable, Sendable, CaseIterable {
    case background, invisible, tiny, covered, offPage

    /// How the marker names it.
    public var words: String {
        switch self {
        case .background: return "in the color behind it"
        case .invisible: return "leaves no ink: clipped, covered by a shape, in a layer switched off or in invisible mode"
        case .tiny: return "too small to read: under 2 pt, squeezed or stacked"
        case .covered: return "covered by an image"
        case .offPage: return "off the page"
        }
    }
}

/// A run of a block's text that a reader cannot see.
public struct Hidden: Codable, Equatable, Sendable {
    /// Where the run starts in the block's text, in UTF-16 units, and how long it is.
    public var offset: Int
    public var length: Int
    public var reason: HiddenReason
}

/// A color, each part from 0 to 1.
struct Color: Equatable {
    var red, green, blue: CGFloat

    /// How far apart two colors are: the largest difference in one part. Red on a grey of the
    /// same lightness is far from it, though their greys match.
    func distance(_ other: Color) -> CGFloat {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }
}

/// What a reader can see of a page (DESIGNS.md → Decision: hidden text found by ink, with the
/// drawing commands for what ink cannot tell). The page is drawn in color, and a word with no
/// ink in its box is not drawn, or drawn in the color behind it. The page's drawing commands add
/// what ink cannot tell: images drawn over text after it, which OCR then checks, text placed off
/// the page, forms in a layer switched off, and a scan's own image under its text layer.
struct Visibility {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat
    let crop: CGRect
    let rotation: Int
    let drawing: Drawing
    let page: PDFPage
    let ocr = OCRCache()

    /// 2 px a point: the strokes of 4-pt text still show as ink.
    static let scale: CGFloat = 2
    /// A pixel is ink when one part of its color differs from the background's by more than
    /// this, out of 255: red on a grey of the same lightness, or ...
    static let hueStep = 38
    /// ... when its lightness stands apart by this contrast, as WCAG measures it. Pale grey
    /// #D9D9D9 on white is 1.41 to 1 and shows; #EEEEEE is 1.16 and white on #E6E6E6 1.25, and
    /// a reader barely finds either.
    static let minContrast = 1.3

    /// Each 8-bit part of an sRGB color, made linear, looked up rather than computed for every
    /// pixel.
    static let linear: [Double] = (0..<256).map { value in
        let part = Double(value) / 255
        return part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
    }

    /// The relative lightness of an sRGB color, as WCAG defines it.
    static func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Double {
        0.2126 * linear[red] + 0.7152 * linear[green] + 0.0722 * linear[blue]
    }

    static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// What OCR reads in each image drawn over text, read once, when a word under it is first
    /// checked, and a table the ink test counts colors in, kept for the page.
    final class OCRCache: @unchecked Sendable {
        var text: [Int: String] = [:]
        var counts = [Int32](repeating: 0, count: 1 << 15)
        var sums = [Int32](repeating: 0, count: 3 << 15)
    }

    init?(page: PDFPage) {
        guard let reference = page.pageRef else { return nil }
        let crop = page.bounds(for: .cropBox)
        let width = Int(crop.width * Visibility.scale), height = Int(crop.height * Visibility.scale)
        // A poster-sized page is checked by its drawing commands alone.
        guard width > 0, height > 0, width * height <= 25_000_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: Visibility.scale, y: Visibility.scale)
            // Unturned, so the pixels line up with the characters' boxes in page space.
            context.translateBy(x: -crop.minX, y: -crop.minY)
            context.drawPDFPage(reference)
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
        self.width = width
        self.height = height
        self.scale = Visibility.scale
        self.crop = crop
        self.rotation = ((page.rotation % 360) + 360) % 360
        self.drawing = Drawing(page: reference, crop: crop)
        self.page = page
    }

    /// A word's box, from PDFKit's selection of it. PDFKit's per-character boxes can sit a
    /// character off within a line, as where a line changes color mid-way, which would test a
    /// neighbour's ink; a selection lands on its own characters.
    func box(of range: NSRange) -> CGRect? {
        guard let rect = page.selection(for: range)?.bounds(for: page), !rect.isEmpty else { return nil }
        return rect
    }

    /// Why a reader cannot see a word, or nil when they can.
    /// - Parameters:
    ///   - rect: the word's box in page space.
    ///   - text: the word.
    ///   - size: its font size, as PDFKit gives it.
    ///   - color: its text color, when known.
    ///   - straight: the word runs straight across or down. PDFKit's boxes for a word set at an
    ///     angle are several glyphs tall and wide, and hold other words' ink.
    ///   - squeezed: its letters are squeezed or stacked into a smudge, by horizontal scaling or
    ///     negative spacing.
    func reason(_ rect: CGRect, text: String, size: CGFloat, color: Color?, straight: Bool, squeezed: Bool = false) -> HiddenReason? {
        // A form in a layer switched off, which CoreGraphics draws all the same: the word is one
        // the form shows, where the form shows it.
        let spelled = Visibility.normalized(text)
        if !spelled.isEmpty, drawing.switchedOff.contains(where: { $0.rect.intersection(rect).area >= 0.8 * rect.area && $0.text.contains(spelled) }) {
            return .invisible
        }
        // Type under 2 pt. The box must be small too: some files set text at 1 pt and scale it
        // up, and PDFKit gives the size before the scaling.
        if size > 0 && size < 2 && min(rect.height, rect.width) < 2 { return .tiny }
        // Letters squeezed or stacked into a smudge, by horizontal scaling or negative spacing:
        // each takes a sliver of the room its height asks for.
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        // A point above and below the box, where PDFKit places some glyphs' boxes a little off
        // their ink; none to the sides, where the next word's ink starts.
        guard let ink = ink(in: rect.insetBy(dx: 0, dy: -1)) else { return nil }
        // A scan's text layer lies in or under its image, invisible by design, and its words can
        // sit a little off the image's: there only text in the color behind it counts as hidden
        // (DESIGNS.md → Principles → Safety). A page of images and visible text, as a slide with
        // a full-page background, gets the same test.
        if drawing.underlay {
            if let color, color.distance(ink.background) < 0.2, ink.count < 2 || ink.share < 0.005 { return .background }
            return nil
        }
        // A scan's OCR layer squeezes and stretches its words to fit the image, so this comes
        // after the scan's test.
        if squeezed { return .tiny }
        // Letters set at an angle: PDFKit's boxes for them miss their ink, so ink cannot judge them.
        guard straight else { return nil }
        if ink.count < 2 || ink.share < 0.005 {
            if let color, color.distance(ink.background) < 0.2 { return .background }
            return .invisible
        }
        // Ink under an image drawn after the text may be the image's own: OCR reads what shows.
        if letters >= 3, let index = drawing.coverings.firstIndex(where: { $0.intersection(rect).area >= 0.5 * rect.area }),
           !Visibility.read(Visibility.normalized(text), in: ocrText(index)) {
            return .covered
        }
        return nil
    }

    /// Whether OCR read a word: whole, or, for a word of 4 letters or more, with one letter
    /// missed, as OCR reads a comic font's "XSports" as "sports".
    static func read(_ word: String, in seen: String) -> Bool {
        guard !word.isEmpty else { return true }
        if seen.contains(word) { return true }
        guard word.count >= 4 else { return false }
        let letters = Array(word)
        return letters.indices.contains { index in
            var shorter = letters
            shorter.remove(at: index)
            return seen.contains(String(shorter))
        }
    }

    /// Whether an image drawn after text lies over most of a box.
    func underCovering(_ rect: CGRect) -> Bool {
        !drawing.underlay && drawing.coverings.contains { $0.intersection(rect).area >= 0.5 * rect.area }
    }

    /// The color most of a box's pixels have, when a box is large enough to tell.
    func background(of rect: CGRect) -> Color? {
        ink(in: rect.insetBy(dx: 0, dy: -1))?.background
    }

    /// How a word is compared with OCR's: its letters and digits, lowercased.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// What OCR reads where an image covers text, as letters and digits run together, so a word
    /// is found inside whatever OCR joins it with, as "Reasoning(RDR)". Read at 300 dpi, upright.
    func ocrText(_ index: Int) -> String {
        if let known = ocr.text[index] { return known }
        // With a margin: an icon's box can reach over half a label below it, and OCR needs the
        // whole label to read it.
        let image = drawing.coverings[index]
        let area = image.insetBy(dx: -max(12, image.width / 4), dy: -max(12, image.height / 4)).intersection(crop)
        var picture: CGImage?
        if rotation == 0, !area.isNull {
            picture = OCR.render(page, dpi: 300, region: area.offsetBy(dx: -crop.minX, dy: -crop.minY))
        } else {
            picture = self.image(of: area)
        }
        let lines = picture.flatMap(OCR.textRecognizerLines) ?? []
        let found = Visibility.normalized(lines.map(\.text).joined())
        ocr.text[index] = found
        return found
    }

    /// Part of the drawn page as an image, turned upright, for OCR.
    func image(of rect: CGRect) -> CGImage? {
        let left = max(0, Int(((rect.minX - crop.minX) * scale).rounded(.down)))
        let right = min(width, Int(((rect.maxX - crop.minX) * scale).rounded(.up)))
        let top = max(0, Int(((crop.maxY - rect.maxY) * scale).rounded(.down)))
        let bottom = min(height, Int(((crop.maxY - rect.minY) * scale).rounded(.up)))
        guard right - left >= 8, bottom - top >= 8 else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let whole = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let part = whole.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        else { return nil }
        guard rotation != 0 else { return part }
        // PDFKit turns a page clockwise by its rotation when it shows it.
        let turned = rotation % 180 != 0
        let size = turned ? CGSize(width: part.height, height: part.width) : CGSize(width: part.width, height: part.height)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -CGFloat(rotation) * .pi / 180)
        context.draw(part, in: CGRect(x: -CGFloat(part.width) / 2, y: -CGFloat(part.height) / 2,
                                      width: CGFloat(part.width), height: CGFloat(part.height)))
        return context.makeImage()
    }

    /// The pixels in a box whose color differs from the box's most common color, and that color.
    /// With `stopEarly`, the count stops once it is enough to call the box inked.
    func ink(in rect: CGRect, stopEarly: Bool = true) -> (count: Int, share: Double, background: Color)? {
        let left = max(0, Int(((rect.minX - crop.minX) * scale).rounded(.down)))
        let right = min(width, Int(((rect.maxX - crop.minX) * scale).rounded(.up)))
        let top = max(0, Int(((crop.maxY - rect.maxY) * scale).rounded(.down)) - 1)
        let bottom = min(height, Int(((crop.maxY - rect.minY) * scale).rounded(.up)) + 1)
        guard right > left, bottom > top else { return nil }
        // The color behind the word: the most common one on the box's border, a pixel outside
        // its glyphs above and below, by 5 bits a part, with the sums of its pixels' parts,
        // counted in tables kept for the page. The border is far cheaper than the whole box.
        var common = 0, most = 0
        var touched: [Int] = []
        let tables = ocr
        var border: [(Int, Int)] = []
        for column in left..<right { border.append((top, column)); border.append((bottom - 1, column)) }
        for row in (top + 1)..<max(top + 1, bottom - 1) { border.append((row, left)); border.append((row, right - 1)) }
        for (row, column) in border {
            let at = (row * width + column) * 4
            let (red, green, blue) = (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
            let key = (red >> 3) << 10 | (green >> 3) << 5 | blue >> 3
            if tables.counts[key] == 0 { touched.append(key) }
            tables.counts[key] &+= 1
            tables.sums[key * 3] &+= Int32(red)
            tables.sums[key * 3 + 1] &+= Int32(green)
            tables.sums[key * 3 + 2] &+= Int32(blue)
            let count = Int(tables.counts[key])
            if count > most {
                most = count
                common = key
            }
        }
        guard most > 0 else { return nil }
        // The common color itself: the mean of the pixels in its bin.
        let base = (Int(tables.sums[common * 3]) / most, Int(tables.sums[common * 3 + 1]) / most, Int(tables.sums[common * 3 + 2]) / most)
        for key in touched {
            tables.counts[key] = 0
            tables.sums[key * 3] = 0
            tables.sums[key * 3 + 1] = 0
            tables.sums[key * 3 + 2] = 0
        }
        let baseLight = Visibility.luminance(base.0, base.1, base.2)
        let total = (right - left) * (bottom - top)
        // Enough ink to call the word seen ends the count early: most words are.
        let enough = max(2, Int((0.005 * Double(total)).rounded(.up))) + 1
        var differing = 0
        count: for row in top..<bottom {
            for column in left..<right {
                let at = (row * width + column) * 4
                let (red, green, blue) = (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
                // Ink is a pixel a reader tells from the color behind it: a hue apart, or a
                // light apart by contrast. #EEEEEE text on white, 1.16 to 1, is not.
                if max(abs(red - base.0), abs(green - base.1), abs(blue - base.2)) > Visibility.hueStep
                    || Visibility.contrast(Visibility.luminance(red, green, blue), baseLight) >= Visibility.minContrast {
                    differing += 1
                    if stopEarly && differing >= enough { break count }
                }
            }
        }
        return (differing, Double(differing) / Double(total),
                Color(red: CGFloat(base.0) / 255, green: CGFloat(base.1) / 255, blue: CGFloat(base.2) / 255))
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// What a page's drawing commands tell about its text, read with CGPDFScanner: images drawn
/// after text, which may cover it, text placed off the page, forms in a layer switched off, and
/// images that together cover most of the page, as a scan's.
final class Drawing {
    /// Images drawn after some text, in page space, masked or not: OCR tells what they cover.
    var coverings: [CGRect] = []
    /// Text placed off the page, as far as its strings spell it. PDFKit leaves it out of the
    /// page's text, so only the drawing commands know it is there.
    var offPage: [String] = []
    /// Forms in a layer switched off, in page space, with the text they show, as letters and
    /// digits run together. CoreGraphics draws them all the same.
    var switchedOff: [(rect: CGRect, text: String)] = []
    /// While a form in a layer switched off is read, the text it shows.
    var offText: String?
    /// Images cover most of the page, as a scan's.
    var underlay = false
    /// The scan stopped at a limit, so what it did not read is unknown.
    var incomplete = false
    /// Every image the page draws, in page space.
    var images: [CGRect] = []

    let crop: CGRect
    var transforms: [CGAffineTransform] = [.identity]
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    var leading: CGFloat = 0
    var textSeen = false
    var depth = 0
    var operations = 0
    var pageResources: CGPDFDictionaryRef?
    /// The layers the file switches off, by their dictionaries.
    var layersOff = Set<OpaquePointer>()

    static let operationLimit = 200_000
    static let depthLimit = 8

    init(page: CGPDFPage, crop: CGRect) {
        self.crop = crop
        if let dictionary = page.dictionary, let object = PageKeyer.inherited(dictionary, "Resources") {
            var resources: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &resources) { pageResources = resources }
        }
        if let catalog = page.document?.catalog {
            var properties: CGPDFDictionaryRef?, defaults: CGPDFDictionaryRef?, off: CGPDFArrayRef?
            if CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties), let properties,
               CGPDFDictionaryGetDictionary(properties, "D", &defaults), let defaults,
               CGPDFDictionaryGetArray(defaults, "OFF", &off), let off {
                for index in 0..<min(CGPDFArrayGetCount(off), 1_000) {
                    var layer: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(off, index, &layer), let layer { layersOff.insert(FactReader.identity(layer)) }
                }
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        run(stream)
        // Images that together cover most of the page, counted on a grid so overlaps count once.
        let cells = 40
        var covered = Set<Int>()
        for rect in images {
            let area = rect.intersection(crop)
            guard !area.isNull, area.width > 0, area.height > 0 else { continue }
            let x0 = Int((area.minX - crop.minX) / crop.width * CGFloat(cells)), x1 = Int(((area.maxX - crop.minX) / crop.width * CGFloat(cells)).rounded(.up))
            let y0 = Int((area.minY - crop.minY) / crop.height * CGFloat(cells)), y1 = Int(((area.maxY - crop.minY) / crop.height * CGFloat(cells)).rounded(.up))
            for x in max(0, x0)..<min(cells, max(x1, x0 + 1)) {
                for y in max(0, y0)..<min(cells, max(y1, y0 + 1)) { covered.insert(y * cells + x) }
            }
        }
        underlay = covered.count * 10 >= cells * cells * 8
        if operations > Drawing.operationLimit { incomplete = true }
    }

    var transform: CGAffineTransform {
        get { transforms[transforms.count - 1] }
        set { transforms[transforms.count - 1] = newValue }
    }

    func run(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, Drawing.table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    /// Text shown at the text matrix's origin: off the page when that point is.
    func show(_ text: String) {
        guard !text.isEmpty else { return }
        operations += 1
        if offText != nil {
            offText! += Visibility.normalized(text)
            return
        }
        textSeen = true
        let point = CGPoint.zero.applying(textMatrix.concatenating(transform))
        if !crop.insetBy(dx: -1, dy: -1).contains(point), offPage.count < 100 {
            offPage.append(TextCleanup.line(text))
        }
    }

    func image() {
        operations += 1
        // An image in a layer switched off covers nothing.
        guard offText == nil else { return }
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform)
        images.append(rect)
        if textSeen { coverings.append(rect) }
    }

    func moveLine(_ x: CGFloat, _ y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values.insert(value, at: 0)
        }
        return values
    }

    static func string(_ scanner: CGPDFScannerRef) -> String? {
        var string: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &string), let string else { return nil }
        return CGPDFStringCopyTextString(string) as String?
    }

    /// What each operator does, by name. CGPDFScanner takes C callbacks, which hold no context,
    /// so each callback names its operator and looks its handler up here. Filled once, with the
    /// table, and only read afterwards.
    nonisolated(unsafe) static var handlers: [String: (CGPDFScannerRef, Drawing) -> Void] = [:]

    static func dispatch(_ name: String, _ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
        guard let info, let handler = handlers[name] else { return }
        let drawing = Unmanaged<Drawing>.fromOpaque(info).takeUnretainedValue()
        guard drawing.operations <= operationLimit else {
            drawing.operations = operationLimit + 1
            return
        }
        handler(scanner, drawing)
    }

    /// Created once and only read afterwards, so sharing it across threads is safe.
    nonisolated(unsafe) static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        func on(_ name: String, _ body: @escaping (CGPDFScannerRef, Drawing) -> Void) { handlers[name] = body }
        on("q") { _, drawing in drawing.transforms.append(drawing.transform) }
        on("Q") { _, drawing in if drawing.transforms.count > 1 { drawing.transforms.removeLast() } }
        on("cm") { scanner, drawing in
            guard let n = numbers(scanner, 6) else { return }
            drawing.transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                .concatenating(drawing.transform)
        }
        on("BT") { _, drawing in
            drawing.textMatrix = .identity
            drawing.lineMatrix = .identity
        }
        on("Tm") { scanner, drawing in
            guard let n = numbers(scanner, 6) else { return }
            drawing.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            drawing.textMatrix = drawing.lineMatrix
        }
        on("Td") { scanner, drawing in
            guard let n = numbers(scanner, 2) else { return }
            drawing.moveLine(n[0], n[1])
        }
        on("TD") { scanner, drawing in
            guard let n = numbers(scanner, 2) else { return }
            drawing.leading = -n[1]
            drawing.moveLine(n[0], n[1])
        }
        on("TL") { scanner, drawing in
            guard let n = numbers(scanner, 1) else { return }
            drawing.leading = n[0]
        }
        on("T*") { _, drawing in drawing.moveLine(0, -drawing.leading) }
        on("Tj") { scanner, drawing in drawing.show(string(scanner) ?? "") }
        on("'") { scanner, drawing in
            drawing.moveLine(0, -drawing.leading)
            drawing.show(string(scanner) ?? "")
        }
        on("\"") { scanner, drawing in
            let text = string(scanner) ?? ""
            _ = numbers(scanner, 2)
            drawing.moveLine(0, -drawing.leading)
            drawing.show(text)
        }
        on("TJ") { scanner, drawing in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            var text = ""
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                if CGPDFArrayGetString(array, index, &string), let string, let piece = CGPDFStringCopyTextString(string) as String? {
                    text += piece
                }
            }
            drawing.show(text)
        }
        on("Do") { scanner, drawing in
            var name: UnsafePointer<CChar>?
            let stream = CGPDFScannerGetContentStream(scanner)
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            // A form or an image in a layer switched off is not shown, though CoreGraphics
            // draws it.
            var layer: CGPDFDictionaryRef?
            let off = CGPDFDictionaryGetDictionary(dictionary, "OC", &layer) && layer.map { drawing.layersOff.contains(FactReader.identity($0)) } == true
            switch String(cString: subtype) {
            case "Image":
                if !off { drawing.image() }
            case "Form":
                guard drawing.depth < depthLimit else {
                    drawing.incomplete = true
                    return
                }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var n = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { _ = CGPDFArrayGetNumber(array, index, &n[index]) }
                    matrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                }
                var bounds = CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)
                if off {
                    var box: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dictionary, "BBox", &box), let box, CGPDFArrayGetCount(box) == 4 {
                        var n = [CGPDFReal](repeating: 0, count: 4)
                        for index in 0..<4 { _ = CGPDFArrayGetNumber(box, index, &n[index]) }
                        bounds = CGRect(x: min(n[0], n[2]), y: min(n[1], n[3]), width: abs(n[2] - n[0]), height: abs(n[3] - n[1]))
                    }
                }
                // A form without its own resources is rare, and old: it uses the page's.
                var own: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
                guard let resources = own ?? drawing.pageResources else { return }
                let inner = CGPDFContentStreamCreateWithStream(xobject, resources, stream)
                defer { CGPDFContentStreamRelease(inner) }
                // A form draws inside its own graphics state, and what it leaves on the stack,
                // an unbalanced "q", ends with it.
                let saved = drawing.transforms.count
                let placed = matrix.concatenating(drawing.transform)
                drawing.transforms.append(placed)
                let text = (drawing.textMatrix, drawing.lineMatrix)
                // A form in a layer switched off is read for the text it shows, which a reader
                // does not see.
                let outer = drawing.offText
                if off && outer == nil { drawing.offText = "" }
                drawing.depth += 1
                drawing.run(inner)
                drawing.depth -= 1
                if off && outer == nil {
                    drawing.switchedOff.append((bounds.applying(placed), drawing.offText ?? ""))
                    drawing.offText = nil
                }
                drawing.transforms.removeLast(drawing.transforms.count - saved)
                (drawing.textMatrix, drawing.lineMatrix) = text
            default:
                break
            }
        }
        // An image drawn inline in the content stream.
        on("EI") { _, drawing in drawing.image() }
        CGPDFOperatorTableSetCallback(table, "q") { dispatch("q", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Q") { dispatch("Q", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "cm") { dispatch("cm", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "BT") { dispatch("BT", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tm") { dispatch("Tm", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Td") { dispatch("Td", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "TD") { dispatch("TD", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "TL") { dispatch("TL", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "T*") { dispatch("T*", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tj") { dispatch("Tj", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "'") { dispatch("'", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "\"") { dispatch("\"", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "TJ") { dispatch("TJ", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Do") { dispatch("Do", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "EI") { dispatch("EI", $0, $1) }
        return table
    }()
}
