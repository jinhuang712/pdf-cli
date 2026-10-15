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
        case .tiny: return "tiny, under 2 pt"
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

/// What a reader can see of a page (DESIGNS.md → Principles → Safety: invisible text leaves a
/// marker, not its words). The page is drawn in grey, and a word with no ink in its box is not
/// drawn, or drawn in the color behind it. The page's drawing commands add what ink cannot
/// tell: an image drawn over text after it, text placed off the page, and a scan's own image
/// under its text layer.
struct Visibility {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat
    let crop: CGRect
    let drawing: Drawing
    let page: PDFPage

    /// 2 px a point: the strokes of 4-pt text still show as ink.
    static let scale: CGFloat = 2

    /// A word's box, from PDFKit's selection of it. PDFKit's per-character boxes can sit a
    /// character off within a line, as where a line changes color mid-way, which would test a
    /// neighbour's ink; a selection lands on its own characters.
    func box(of range: NSRange) -> CGRect? {
        guard let rect = page.selection(for: range)?.bounds(for: page), !rect.isEmpty else { return nil }
        return rect
    }

    init?(page: PDFPage) {
        guard let reference = page.pageRef else { return nil }
        let crop = page.bounds(for: .cropBox)
        let width = Int(crop.width * Visibility.scale), height = Int(crop.height * Visibility.scale)
        // A poster-sized page is checked by its drawing commands alone.
        guard width > 0, height > 0, width * height <= 40_000_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
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
        self.drawing = Drawing(page: reference, crop: crop)
        self.page = page
    }

    /// Why a reader cannot see a word, or nil when they can. `rect` is the word's box in page
    /// space, `size` its font size, and `brightness` its text color's, from 0 for black to 1 for
    /// white, when known. Without `inkTells`, the word's boxes are not to be trusted for ink.
    func reason(_ rect: CGRect, size: CGFloat, brightness: CGFloat?, inkTells: Bool = true) -> HiddenReason? {
        if drawing.coverings.contains(where: { $0.intersection(rect).area >= 0.8 * rect.area }) { return .covered }
        // A scan's text layer lies over its image, invisible by design: it is the scan's text.
        guard !drawing.underlay else { return nil }
        // Type under 2 pt, which no reader can read. The box must be small too: some files set
        // text at 1 pt and scale it up, and PDFKit gives the size before the scaling.
        if size > 0 && size < 2 && min(rect.height, rect.width) < 2 { return .tiny }
        // A point above and below the box, where PDFKit places some glyphs' boxes a little off
        // their ink; none to the sides, where the next word's ink starts.
        guard inkTells, let ink = ink(in: rect.insetBy(dx: 0, dy: -1)) else { return nil }
        guard ink.count < 2 || ink.share < 0.005 else { return nil }
        if let brightness, abs(brightness - ink.background) < 0.2 { return .background }
        return .invisible
    }

    /// The pixels in a box that differ from the box's most common value, and that value, from 0
    /// for black to 1 for white.
    func ink(in rect: CGRect) -> (count: Int, share: Double, background: CGFloat)? {
        let left = max(0, Int(((rect.minX - crop.minX) * scale).rounded(.down)))
        let right = min(width, Int(((rect.maxX - crop.minX) * scale).rounded(.up)))
        let top = max(0, Int(((crop.maxY - rect.maxY) * scale).rounded(.down)) - 1)
        let bottom = min(height, Int(((crop.maxY - rect.minY) * scale).rounded(.up)) + 1)
        guard right > left, bottom > top else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        for row in top..<bottom {
            let start = row * width
            for column in left..<right { histogram[Int(pixels[start + column])] += 1 }
        }
        let total = (right - left) * (bottom - top)
        let common = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255
        let differing = histogram.indices.filter { abs($0 - common) > 32 }.reduce(0) { $0 + histogram[$1] }
        return (differing, Double(differing) / Double(total), CGFloat(common) / 255)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// What a page's drawing commands tell about its text, read with CGPDFScanner: images drawn
/// over text after it, text placed off the page, and an image under the whole page drawn before
/// any text, as a scan's.
final class Drawing {
    /// Opaque images drawn after some text, in page space.
    var coverings: [CGRect] = []
    /// Text placed off the page, as far as its strings spell it. PDFKit leaves it out of the
    /// page's text, so only the drawing commands know it is there.
    var offPage: [String] = []
    /// An image as large as most of the page, as a scan's.
    var underlay = false
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

    static let operationLimit = 200_000

    init(page: CGPDFPage, crop: CGRect) {
        self.crop = crop
        if let dictionary = page.dictionary, let object = PageKeyer.inherited(dictionary, "Resources") {
            var resources: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &resources) { pageResources = resources }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        run(stream)
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
        operations += 1
        textSeen = true
        let point = CGPoint.zero.applying(textMatrix.concatenating(transform))
        if !crop.insetBy(dx: -1, dy: -1).contains(point), !text.isEmpty, offPage.count < 100 {
            offPage.append(TextCleanup.line(text))
        }
    }

    /// An image as large as most of the page is a scan's, whichever comes first, it or the text:
    /// some OCR tools write the text layer before the page's image. A smaller opaque image drawn
    /// after text covers it.
    func image(opaque: Bool) {
        operations += 1
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform)
        images.append(rect)
        // A scan can come in strips: the 1951 NACA report draws each page as 33 bands.
        if images.reduce(0, { $0 + $1.intersection(crop).area }) >= 0.8 * crop.area {
            underlay = true
        } else if textSeen, opaque {
            coverings.append(rect)
        }
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
        guard drawing.operations <= operationLimit else { return }
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
            switch String(cString: subtype) {
            case "Image":
                // An image with a mask or soft mask can let the text under it show.
                var flag = false
                var value: CGPDFObjectRef?
                let masked = CGPDFDictionaryGetObject(dictionary, "SMask", &value) || CGPDFDictionaryGetObject(dictionary, "Mask", &value)
                    || (CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &flag) && flag)
                drawing.image(opaque: !masked)
            case "Form" where drawing.depth < 4:
                // A form without its own resources is rare, and old: it uses the page's.
                var own: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
                guard let resources = own ?? drawing.pageResources else { return }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var n = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { _ = CGPDFArrayGetNumber(array, index, &n[index]) }
                    matrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                }
                let inner = CGPDFContentStreamCreateWithStream(xobject, resources, stream)
                defer { CGPDFContentStreamRelease(inner) }
                // A form draws inside its own graphics state.
                drawing.transforms.append(matrix.concatenating(drawing.transform))
                let saved = (drawing.textMatrix, drawing.lineMatrix)
                drawing.depth += 1
                drawing.run(inner)
                drawing.depth -= 1
                drawing.transforms.removeLast()
                (drawing.textMatrix, drawing.lineMatrix) = saved
            default:
                break
            }
        }
        // An image drawn inline in the content stream: its size cannot be told from here, so it
        // counts as opaque.
        on("EI") { _, drawing in drawing.image(opaque: true) }
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
