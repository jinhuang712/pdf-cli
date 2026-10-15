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
/// what ink cannot tell: images drawn over text after it, text placed off the page, forms in a
/// layer switched off, and a scan's own image under its text layer.
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
    /// OCR reads at most this many places a page, and at most twice the page's area in all:
    /// 200 labels under 200 images took 4.3 s, one call each.
    static let ocrCalls = 8

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

    /// What OCR reads where images cover text, read once per area, when a word under it is first
    /// checked, the areas, what OCR has spent, and a table the ink test counts colors in, kept
    /// for the page.
    final class OCRCache: @unchecked Sendable {
        /// What OCR read in each area.
        var text: [Int: String] = [:]
        /// The areas OCR reads: images drawn after text whose surroundings meet, read together.
        var areas: [CGRect] = []
        /// Which area each image drawn after text belongs to.
        var area: [Int: Int] = [:]
        var calls = 0
        var spent: CGFloat = 0
        var counts = [Int32](repeating: 0, count: 1 << 15)
        var sums = [Int32](repeating: 0, count: 3 << 15)
    }

    /// The ink in a word's box.
    struct Ink {
        /// The pixels whose color a reader tells from the color behind them, rules aside.
        var count: Int
        var share: Double
        /// The color behind the word.
        var background: Color
        /// The ink in each column of pixels, from the box's left edge.
        var columns: [Int]
        /// The box's left edge, in pixels of the drawn page.
        var left: Int
    }

    /// What the check found about a word: hidden, and why, or seen, with its ink when ink judged it.
    enum Verdict {
        case hidden(HiddenReason)
        case seen(Ink?)
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

    /// Whether a reader can see a word, and if not, why.
    /// - Parameters:
    ///   - rect: the word's box in page space.
    ///   - text: the word.
    ///   - size: its font size, as PDFKit gives it.
    ///   - color: its text color, when known.
    ///   - straight: the word runs straight across or down. PDFKit's boxes for a word set at an
    ///     angle are several glyphs tall and wide, and hold other words' ink.
    ///   - squeezed: its letters are squeezed or stacked into a smudge, by horizontal scaling or
    ///     negative spacing.
    func check(_ rect: CGRect, text: String, size: CGFloat, color: Color?, straight: Bool, squeezed: Bool = false) -> Verdict {
        // A form in a layer switched off, which CoreGraphics draws all the same: the word is one
        // the form shows, where the form shows it.
        let spelled = Visibility.normalized(text)
        if !spelled.isEmpty, drawing.switchedOff.contains(where: { $0.rect.intersection(rect).area >= 0.8 * rect.area && $0.text.contains(spelled) }) {
            return .hidden(.invisible)
        }
        // Type under 2 pt. The box must be small too: some files set text at 1 pt and scale it
        // up, and PDFKit gives the size before the scaling.
        if size > 0 && size < 2 && min(rect.height, rect.width) < 2 { return .hidden(.tiny) }
        // A scan's text layer: drawn in a mode that paints nothing, over images that cover most
        // of the page, invisible by design, and its words can sit a little off the image's. It
        // reads as text (DESIGNS.md → Principles → Safety). Text drawn to show on such a page, as
        // a slide's over its background image, gets every check.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if drawing.underlay, drawing.runs(at: center).contains(where: \.invisible) { return .seen(nil) }
        // A scan's OCR layer squeezes and stretches its words to fit the image, so this comes
        // after the scan's test.
        if squeezed { return .hidden(.tiny) }
        // Letters set at an angle: PDFKit's boxes for them miss their ink, so ink cannot judge them.
        guard straight else { return .seen(nil) }
        // A point above and below the box, where PDFKit places some glyphs' boxes a little off
        // their ink; none to the sides, where the next word's ink starts.
        guard let ink = ink(in: rect.insetBy(dx: 0, dy: -1)) else { return .seen(nil) }
        if ink.count < 2 || ink.share < 0.005 {
            if let color, color.distance(ink.background) < 0.2 { return .hidden(.background) }
            return .hidden(.invisible)
        }
        if covered(rect, text: text, center: center) { return .hidden(.covered) }
        return .seen(ink)
    }

    /// Whether an image drawn after a word hides it. Ink cannot tell: under an image, the ink may
    /// be the image's own. The drawing commands tell how much of the image lets through: an image
    /// that lets most through hides nothing, and one that lets almost nothing through, drawn
    /// after the word, hides it. Between the two, and where the commands cannot tell, as for a
    /// blend mode or a stencil, OCR reads what shows, for a word in a script it reads.
    func covered(_ rect: CGRect, text: String, center: CGPoint) -> Bool {
        let over = drawing.coverings.indices.filter { drawing.coverings[$0].rect.intersection(rect).area >= 0.5 * rect.area }
        guard !over.isEmpty else { return false }
        // The text drawn where the word is, and so when it was drawn. With none found, an image
        // drawn after any text may cover it.
        let orders = drawing.runs(at: center).map(\.order)
        let first = orders.min() ?? -1
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        for index in over where drawing.coverings[index].order > first {
            let image = drawing.coverings[index]
            let alpha = drawing.alpha(of: image, over: rect)
            if let alpha, alpha.high <= 0.35 { continue }
            // A scan's page draws its own words in its image, so there OCR tells whether the
            // image shows the word.
            if let alpha, alpha.low >= 0.9, let last = orders.max(), image.order > last, !drawing.underlay { return true }
            guard letters >= 3, let seen = ocrText(index) else { continue }
            if Visibility.read(Visibility.normalized(text), in: seen) { return false }
            // OCR cannot vouch for a script it does not read, as Greek: the word reads as seen.
            if Visibility.ocrReads(text) { return true }
        }
        return false
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

    /// Whether OCR reads a word's script: Latin, and Chinese, as `OCR.textRecognizerLines` asks
    /// for. A word with a letter of another script, as Greek or Hebrew, OCR cannot vouch for.
    static func ocrReads(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            guard scalar.properties.isAlphabetic else { return true }
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return true
            default: return false
            }
        }
    }

    /// Whether an image drawn after text lies over most of a box.
    func underCovering(_ rect: CGRect) -> Bool {
        drawing.coverings.contains { $0.rect.intersection(rect).area >= 0.5 * rect.area }
    }

    /// How a word is compared with OCR's: its letters and digits, lowercased.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The area OCR reads for an image drawn after text: the image with a margin, since an
    /// icon's box can reach over half a label below it and OCR needs the whole label, joined
    /// with every other such image whose area meets it, so OCR reads each place once.
    func area(of index: Int) -> Int {
        if let known = ocr.area[index] { return known }
        func around(_ rect: CGRect) -> CGRect {
            rect.insetBy(dx: -max(12, rect.width / 4), dy: -max(12, rect.height / 4)).intersection(crop)
        }
        var area = around(drawing.coverings[index].rect)
        var members: Set<Int> = [index]
        // The first 2,000 images join areas; past them, each is its own.
        let joinable = drawing.coverings.indices.prefix(2_000).filter { ocr.area[$0] == nil }
        var grew = index < 2_000
        while grew {
            grew = false
            for other in joinable where !members.contains(other) {
                let around = around(drawing.coverings[other].rect)
                if around.intersects(area) {
                    area = area.union(around)
                    members.insert(other)
                    grew = true
                }
            }
        }
        let id = ocr.areas.count
        ocr.areas.append(area)
        for member in members { ocr.area[member] = id }
        return id
    }

    /// What OCR reads in the area of an image drawn over text, as letters and digits run
    /// together, so a word is found inside whatever OCR joins it with, as "Reasoning(RDR)". Read
    /// at 300 dpi, upright. Nil past the page's cap, and the page then says its check is
    /// incomplete.
    func ocrText(_ index: Int) -> String? {
        let id = area(of: index)
        if let known = ocr.text[id] { return known }
        let area = ocr.areas[id]
        guard ocr.calls < Visibility.ocrCalls, ocr.spent + area.area <= 2 * crop.area else {
            drawing.incomplete = true
            return nil
        }
        ocr.calls += 1
        ocr.spent += area.area
        var picture: CGImage?
        if rotation == 0, !area.isNull {
            picture = OCR.render(page, dpi: 300, region: area.offsetBy(dx: -crop.minX, dy: -crop.minY))
        } else {
            picture = self.image(of: area)
        }
        let lines = picture.flatMap(OCR.textRecognizerLines) ?? []
        let found = Visibility.normalized(lines.map(\.text).joined())
        ocr.text[id] = found
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

    /// The ink in a box: the pixels whose color differs from the box's most common color, by
    /// column, and that color. A row inked from side to side in one color is a rule, as a table's
    /// or an underline, or a strip of a shape, not letters, and does not count: two grey rules
    /// along white text's box would otherwise read as its ink.
    func ink(in rect: CGRect) -> Ink? {
        let left = max(0, Int(((rect.minX - crop.minX) * scale).rounded(.down)))
        let right = min(width, Int(((rect.maxX - crop.minX) * scale).rounded(.up)))
        let top = max(0, Int(((crop.maxY - rect.maxY) * scale).rounded(.down)) - 1)
        let bottom = min(height, Int(((crop.maxY - rect.minY) * scale).rounded(.up)) + 1)
        guard right > left, bottom > top else { return nil }
        // The color behind the word: the most common one in the box, from every other pixel each
        // way, by 5 bits a part, with the sums of its pixels' parts, counted in tables kept for
        // the page. Letters never fill most of their box; rules along its border can fill most
        // of the border.
        var common = 0, most = 0
        var touched: [Int] = []
        var base = (0, 0, 0)
        pixels.withUnsafeBufferPointer { pixels in
            ocr.counts.withUnsafeMutableBufferPointer { counts in
                ocr.sums.withUnsafeMutableBufferPointer { sums in
                    for row in stride(from: top, to: bottom, by: bottom - top > 4 ? 2 : 1) {
                        for column in stride(from: left, to: right, by: right - left > 4 ? 2 : 1) {
                            let at = (row * width + column) * 4
                            let (red, green, blue) = (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
                            let key = (red >> 3) << 10 | (green >> 3) << 5 | blue >> 3
                            if counts[key] == 0 { touched.append(key) }
                            counts[key] &+= 1
                            sums[key * 3] &+= Int32(red)
                            sums[key * 3 + 1] &+= Int32(green)
                            sums[key * 3 + 2] &+= Int32(blue)
                            let count = Int(counts[key])
                            if count > most {
                                most = count
                                common = key
                            }
                        }
                    }
                    // The common color itself: the mean of the pixels in its bin.
                    if most > 0 {
                        base = (Int(sums[common * 3]) / most, Int(sums[common * 3 + 1]) / most, Int(sums[common * 3 + 2]) / most)
                    }
                    for key in touched {
                        counts[key] = 0
                        sums[key * 3] = 0
                        sums[key * 3 + 1] = 0
                        sums[key * 3 + 2] = 0
                    }
                }
            }
        }
        guard most > 0 else { return nil }
        // The lightness a pixel must reach, or stay under, to stand apart by the contrast.
        let baseLight = Visibility.luminance(base.0, base.1, base.2)
        let lighter = Visibility.minContrast * (baseLight + 0.05) - 0.05
        let darker = (baseLight + 0.05) / Visibility.minContrast - 0.05
        let span = right - left
        var columns = [Int](repeating: 0, count: span)
        var inked = [Int](repeating: 0, count: span)
        var count = 0
        pixels.withUnsafeBufferPointer { pixels in
            for row in top..<bottom {
                var found = 0, key = -1, oneColor = true
                for column in left..<right {
                    let at = (row * width + column) * 4
                    let (red, green, blue) = (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
                    if red == base.0 && green == base.1 && blue == base.2 { continue }
                    // Ink is a pixel a reader tells from the color behind it: a hue apart, or a
                    // light apart by contrast. #EEEEEE text on white, 1.16 to 1, is not.
                    if max(abs(red - base.0), abs(green - base.1), abs(blue - base.2)) <= Visibility.hueStep {
                        let light = Visibility.luminance(red, green, blue)
                        guard light >= lighter || light <= darker else { continue }
                    }
                    let bin = (red >> 3) << 10 | (green >> 3) << 5 | blue >> 3
                    if key < 0 { key = bin } else if bin != key { oneColor = false }
                    inked[found] = column - left
                    found += 1
                }
                if span >= 8 && oneColor && found * 10 >= span * 9 { continue }
                count += found
                for index in 0..<found { columns[inked[index]] += 1 }
            }
        }
        return Ink(count: count, share: Double(count) / Double(span * (bottom - top)),
                   background: Color(red: CGFloat(base.0) / 255, green: CGFloat(base.1) / 255, blue: CGFloat(base.2) / 255),
                   columns: columns, left: left)
    }

    /// Whether a word's ink leaves a stretch of its box as wide as a narrow letter without ink,
    /// as where its letters are hidden one by one, so they are checked one by one.
    func gapped(_ ink: Ink, height: CGFloat) -> Bool {
        let limit = max(3, Int(0.2 * height * scale))
        guard let first = ink.columns.firstIndex(where: { $0 > 0 }), let last = ink.columns.lastIndex(where: { $0 > 0 }) else { return false }
        if first >= limit || ink.columns.count - 1 - last >= limit { return true }
        var empty = 0
        for value in ink.columns[first...last] {
            empty = value == 0 ? empty + 1 : 0
            if empty >= limit { return true }
        }
        return false
    }

    /// Whether a letter shows ink in the middle of its box, within its word's ink.
    func inked(_ letter: CGRect, _ ink: Ink) -> Bool {
        let start = Int(((letter.minX - crop.minX) * scale).rounded(.down)) - ink.left
        let end = Int(((letter.maxX - crop.minX) * scale).rounded(.up)) - ink.left
        let trim = (end - start) / 5
        let from = max(0, start + trim), to = min(ink.columns.count, max(start + trim + 1, end - trim))
        guard from < to else { return true }
        return ink.columns[from..<to].reduce(0, +) >= 2
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// What a page's drawing commands tell about its text, read with CGPDFScanner: where each piece
/// of text is drawn, in what mode and when, the images drawn after text, with how much they let
/// through, text placed off the page, forms in a layer switched off, and images that together
/// cover most of the page, as a scan's.
final class Drawing {
    /// Where a run of text may reach, from where it starts to as far as its glyphs could go if
    /// each took the font's full size: a word drawn by it lies within. Text space here is the
    /// run's own, where its glyphs are the font size tall.
    struct TextRun {
        /// When it was drawn, among the page's text and images.
        var order: Int
        /// From page space to the run's text space.
        var toText: CGAffineTransform
        var reach: CGFloat
        var size: CGFloat
        /// Drawn in a mode that paints nothing, or with no opacity, as a scan's text layer.
        var invisible: Bool
        /// Its bounds in page space, for a quick test.
        var bounds: CGRect

        func holds(_ point: CGPoint) -> Bool {
            guard bounds.contains(point) else { return false }
            let local = point.applying(toText)
            return local.x >= -0.5 * size && local.x <= reach + 0.5 * size && local.y >= -0.6 * size && local.y <= 1.4 * size
        }
    }

    /// An image as drawn: where, when, and how much it lets through.
    struct Placed {
        var order: Int
        /// Its bounds in page space, within the clip's bounds.
        var rect: CGRect
        /// From the unit square to page space.
        var transform: CGAffineTransform
        /// The state's fill opacity.
        var opacity: CGFloat
        var mask: CGPDFStreamRef?
        /// How much it lets through is known: no stencil, color key, blend mode, soft mask in
        /// the state or clip by text.
        var known: Bool
    }

    /// A soft mask's values, from 0, clear, to 255, solid, row by row from the top.
    struct Mask {
        var width: Int
        var height: Int
        var values: [UInt8]
    }

    /// What the graphics state holds that the checks use. `q` saves it and `Q` restores it.
    struct State {
        var transform = CGAffineTransform.identity
        /// The clip's bounds in page space.
        var clip = CGRect.infinite
        var mode = 0
        var fontSize: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var characterSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var leading: CGFloat = 0
        var fillAlpha: CGFloat = 1
        /// A blend mode other than Normal, a soft mask, or a clip by text: what an image lets
        /// through is unknown.
        var blended = false
        var softMask = false
        var textClip = false
    }

    /// Where each piece of text is drawn.
    var runs: [TextRun] = []
    /// Images drawn after some text, which may cover it.
    var coverings: [Placed] = []
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
    /// The check stopped at a limit, so what it did not read is unknown.
    var incomplete = false
    /// Every image the page draws, in page space.
    var images: [CGRect] = []

    let crop: CGRect
    var states = [State()]
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    /// The text drawn since the text position last moved: where it starts, in page space, and how
    /// far it may reach.
    var stretch: (origin: CGAffineTransform, reach: CGFloat)?
    var clipsText = false
    /// The path being built, by its bounds in page space, and whether it then clips.
    var path = CGRect.null
    var clipNext = false
    var textSeen = false
    var depth = 0
    var operations = 0
    var order = 0
    var pageResources: CGPDFDictionaryRef?
    /// The layers the file switches off, by their dictionaries.
    var layersOff = Set<OpaquePointer>()
    var masks: [OpaquePointer: Mask?] = [:]

    static let operationLimit = 200_000
    static let depthLimit = 8
    static let runLimit = 50_000

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
        if operations > Drawing.operationLimit || runs.count >= Drawing.runLimit { incomplete = true }
    }

    var state: State {
        get { states[states.count - 1] }
        set { states[states.count - 1] = newValue }
    }

    func run(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, Drawing.table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    /// The runs of text that may hold a point.
    func runs(at point: CGPoint) -> [TextRun] {
        runs.filter { $0.holds(point) }
    }

    /// Text shown: its string, its length in bytes, its spaces, and how far a TJ array's numbers
    /// spread it, in thousandths of the font size.
    func show(_ text: String, bytes: Int, spaces: Int, spread: CGFloat = 0) {
        // Empty strings draw nothing, and do not count against the limit.
        guard bytes > 0 else { return }
        operations += 1
        if offText != nil {
            offText! += Visibility.normalized(text)
            return
        }
        textSeen = true
        let placed = textMatrix.concatenating(state.transform)
        // Off the page when the point where the string starts is.
        let point = CGPoint.zero.applying(placed)
        if !crop.insetBy(dx: -1, dy: -1).contains(point), offPage.count < 100 {
            offPage.append(TextCleanup.line(text))
        }
        let current = state
        if current.mode >= 4 { clipsText = true }
        let size = abs(current.fontSize)
        let reach = (CGFloat(bytes) * (size + max(current.characterSpacing, 0)) + CGFloat(spaces) * max(current.wordSpacing, 0)
                     + max(0, spread) / 1000 * size) * abs(current.horizontalScale)
        if stretch == nil { stretch = (placed, 0) }
        stretch!.reach += reach
        defer { order += 1 }
        let origin = stretch!.origin
        guard runs.count < Drawing.runLimit, abs(origin.a * origin.d - origin.b * origin.c) > 1e-9 else { return }
        let tall = max(size, 0.5)
        let bounds = CGRect(x: -0.5 * tall, y: -0.6 * tall, width: stretch!.reach + tall, height: 2 * tall).applying(origin)
        let invisible = current.mode == 3 || current.mode == 7 || (current.fillAlpha == 0 && (current.mode == 0 || current.mode == 4))
        runs.append(TextRun(order: order, toText: origin.inverted(), reach: stretch!.reach, size: tall, invisible: invisible, bounds: bounds))
    }

    func image(known: Bool, mask: CGPDFStreamRef? = nil) {
        operations += 1
        // An image in a layer switched off covers nothing.
        guard offText == nil else { return }
        defer { order += 1 }
        let current = state
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(current.transform).intersection(current.clip)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        images.append(rect)
        guard textSeen else { return }
        coverings.append(Placed(order: order, rect: rect, transform: current.transform, opacity: current.fillAlpha,
                                mask: mask, known: known && !current.blended && !current.softMask && !current.textClip))
    }

    /// Text placed at a new position starts a new run.
    func moveLine(_ x: CGFloat, _ y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
        stretch = nil
    }

    /// A point of the path being built, in page space.
    func extend(_ numbers: [CGFloat]) {
        for index in stride(from: 0, to: numbers.count - 1, by: 2) {
            let point = CGPoint(x: numbers[index], y: numbers[index + 1]).applying(state.transform)
            path = path.union(CGRect(origin: point, size: .zero))
        }
    }

    /// How much of an image lets through over a box, from least to most: its state's opacity
    /// times its soft mask's values there. Nil when the drawing commands cannot tell.
    func alpha(of image: Placed, over rect: CGRect) -> (low: CGFloat, high: CGFloat)? {
        guard image.known else { return nil }
        guard let stream = image.mask else { return (image.opacity, image.opacity) }
        let transform = image.transform
        guard abs(transform.a * transform.d - transform.b * transform.c) > 1e-9, let mask = mask(stream) else { return nil }
        let area = rect.intersection(image.rect)
        guard !area.isNull else { return nil }
        let toUnit = transform.inverted()
        let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                       CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)].map { $0.applying(toUnit) }
        let u0 = max(0, min(1, corners.map(\.x).min()!)), u1 = max(0, min(1, corners.map(\.x).max()!))
        let v0 = max(0, min(1, corners.map(\.y).min()!)), v1 = max(0, min(1, corners.map(\.y).max()!))
        // The image's first row is at the top of the unit square.
        let columns = Int(u0 * CGFloat(mask.width))..<max(Int(u0 * CGFloat(mask.width)) + 1, Int((u1 * CGFloat(mask.width)).rounded(.up)))
        let rows = Int((1 - v1) * CGFloat(mask.height))..<max(Int((1 - v1) * CGFloat(mask.height)) + 1, Int(((1 - v0) * CGFloat(mask.height)).rounded(.up)))
        var low = 255, high = 0
        for row in stride(from: rows.lowerBound, to: min(rows.upperBound, mask.height), by: max(1, rows.count / 64)) {
            for column in stride(from: columns.lowerBound, to: min(columns.upperBound, mask.width), by: max(1, columns.count / 64)) {
                let value = Int(mask.values[row * mask.width + column])
                low = min(low, value)
                high = max(high, value)
            }
        }
        guard low <= high else { return nil }
        return (CGFloat(low) / 255 * image.opacity, CGFloat(high) / 255 * image.opacity)
    }

    /// A soft mask's values, decoded once. Nil for a mask the checks do not decode: not 8 or 1
    /// bits a value, or compressed as an image, as JPEG.
    func mask(_ stream: CGPDFStreamRef) -> Mask? {
        if let known = masks[unsafeBitCast(stream, to: OpaquePointer.self)] { return known }
        let decoded = Drawing.decode(stream)
        masks[unsafeBitCast(stream, to: OpaquePointer.self)] = .some(decoded)
        return decoded
    }

    static func decode(_ stream: CGPDFStreamRef) -> Mask? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0, width * height <= 25_000_000 else { return nil }
        _ = CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
        guard bits == 8 || bits == 1 else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return nil }
        let rowBytes = (width * bits + 7) / 8
        guard data.count >= rowBytes * height else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        var inverted = false
        var decode: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Decode", &decode), let decode, CGPDFArrayGetCount(decode) == 2 {
            var first: CGPDFReal = 0
            inverted = CGPDFArrayGetNumber(decode, 0, &first) && first > 0.5
        }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for row in 0..<height {
                for column in 0..<width {
                    var value: UInt8
                    if bits == 8 {
                        value = bytes[row * rowBytes + column]
                    } else {
                        value = (bytes[row * rowBytes + column / 8] >> (7 - column % 8)) & 1 == 1 ? 255 : 0
                    }
                    if inverted { value = 255 - value }
                    values[row * width + column] = value
                }
            }
        }
        return Mask(width: width, height: height, values: values)
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

    /// A string's text, its length in bytes and its spaces.
    static func string(_ string: CGPDFStringRef) -> (text: String, bytes: Int, spaces: Int) {
        let length = CGPDFStringGetLength(string)
        var spaces = 0
        if let bytes = CGPDFStringGetBytePtr(string) {
            for index in 0..<length where bytes[index] == 0x20 { spaces += 1 }
        }
        return ((CGPDFStringCopyTextString(string) as String?) ?? "", length, spaces)
    }

    static func string(_ scanner: CGPDFScannerRef) -> (text: String, bytes: Int, spaces: Int)? {
        var value: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &value), let value else { return nil }
        return string(value)
    }

    static func show(_ scanner: CGPDFScannerRef, _ drawing: Drawing) {
        guard let shown = string(scanner) else { return }
        drawing.show(shown.text, bytes: shown.bytes, spaces: shown.spaces)
    }

    /// The names a stream's Filter entry gives, one or several.
    static func filters(_ dictionary: CGPDFDictionaryRef) -> [String] {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Filter", &name), let name { return [String(cString: name)] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Filter", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var name: UnsafePointer<CChar>?
            return CGPDFArrayGetName(array, index, &name) ? name.map { String(cString: $0) } : nil
        }
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
        on("q") { _, drawing in drawing.states.append(drawing.state) }
        on("Q") { _, drawing in if drawing.states.count > 1 { drawing.states.removeLast() } }
        on("cm") { scanner, drawing in
            guard let n = numbers(scanner, 6) else { return }
            drawing.state.transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                .concatenating(drawing.state.transform)
        }
        on("gs") { scanner, drawing in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name) else { return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return }
            var alpha: CGPDFReal = 1
            if CGPDFDictionaryGetNumber(dictionary, "ca", &alpha) { drawing.state.fillAlpha = max(0, min(1, alpha)) }
            var blend: UnsafePointer<CChar>?
            var blends: CGPDFArrayRef?
            if CGPDFDictionaryGetName(dictionary, "BM", &blend), let blend {
                drawing.state.blended = !["Normal", "Compatible"].contains(String(cString: blend))
            } else if CGPDFDictionaryGetArray(dictionary, "BM", &blends), let blends {
                drawing.state.blended = !(CGPDFArrayGetName(blends, 0, &blend) && blend.map { String(cString: $0) } == "Normal")
            }
            var mask: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "SMask", &mask), let mask {
                drawing.state.softMask = CGPDFObjectGetType(mask) == .dictionary
            }
        }
        // The path, by its bounds, and the clip it makes.
        on("m") { scanner, drawing in numbers(scanner, 2).map(drawing.extend) }
        on("l") { scanner, drawing in numbers(scanner, 2).map(drawing.extend) }
        on("c") { scanner, drawing in numbers(scanner, 6).map(drawing.extend) }
        on("v") { scanner, drawing in numbers(scanner, 4).map(drawing.extend) }
        on("y") { scanner, drawing in numbers(scanner, 4).map(drawing.extend) }
        on("re") { scanner, drawing in
            guard let n = numbers(scanner, 4) else { return }
            drawing.extend([n[0], n[1], n[0] + n[2], n[1], n[0], n[1] + n[3], n[0] + n[2], n[1] + n[3]])
        }
        on("W") { _, drawing in drawing.clipNext = true }
        on("W*") { _, drawing in drawing.clipNext = true }
        let paint: (CGPDFScannerRef, Drawing) -> Void = { _, drawing in
            if drawing.clipNext { drawing.state.clip = drawing.state.clip.intersection(drawing.path) }
            drawing.path = .null
            drawing.clipNext = false
        }
        for name in ["n", "f", "F", "f*", "S", "s", "B", "B*", "b", "b*"] { on(name, paint) }
        on("BT") { _, drawing in
            drawing.textMatrix = .identity
            drawing.lineMatrix = .identity
            drawing.stretch = nil
            drawing.clipsText = false
        }
        // Text drawn in a mode that clips leaves a clip by its glyphs.
        on("ET") { _, drawing in if drawing.clipsText { drawing.state.textClip = true } }
        on("Tm") { scanner, drawing in
            guard let n = numbers(scanner, 6) else { return }
            drawing.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            drawing.textMatrix = drawing.lineMatrix
            drawing.stretch = nil
        }
        on("Td") { scanner, drawing in
            guard let n = numbers(scanner, 2) else { return }
            drawing.moveLine(n[0], n[1])
        }
        on("TD") { scanner, drawing in
            guard let n = numbers(scanner, 2) else { return }
            drawing.state.leading = -n[1]
            drawing.moveLine(n[0], n[1])
        }
        on("TL") { scanner, drawing in numbers(scanner, 1).map { drawing.state.leading = $0[0] } }
        on("Tr") { scanner, drawing in numbers(scanner, 1).map { drawing.state.mode = Int($0[0]) } }
        on("Tz") { scanner, drawing in numbers(scanner, 1).map { drawing.state.horizontalScale = $0[0] / 100 } }
        on("Tc") { scanner, drawing in numbers(scanner, 1).map { drawing.state.characterSpacing = $0[0] } }
        on("Tw") { scanner, drawing in numbers(scanner, 1).map { drawing.state.wordSpacing = $0[0] } }
        on("Tf") { scanner, drawing in numbers(scanner, 1).map { drawing.state.fontSize = $0[0] } }
        on("T*") { _, drawing in drawing.moveLine(0, -drawing.state.leading) }
        on("Tj") { scanner, drawing in show(scanner, drawing) }
        on("'") { scanner, drawing in
            drawing.moveLine(0, -drawing.state.leading)
            show(scanner, drawing)
        }
        on("\"") { scanner, drawing in
            let shown = string(scanner)
            if let n = numbers(scanner, 2) {
                drawing.state.wordSpacing = n[0]
                drawing.state.characterSpacing = n[1]
            }
            drawing.moveLine(0, -drawing.state.leading)
            if let shown { drawing.show(shown.text, bytes: shown.bytes, spaces: shown.spaces) }
        }
        on("TJ") { scanner, drawing in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            var text = "", bytes = 0, spaces = 0, spread: CGFloat = 0
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    let piece = Drawing.string(string)
                    text += piece.text
                    bytes += piece.bytes
                    spaces += piece.spaces
                } else if CGPDFArrayGetNumber(array, index, &number) {
                    // A negative number moves the next glyph on, a positive one back.
                    spread -= number
                }
            }
            drawing.show(text, bytes: bytes, spaces: spaces, spread: spread)
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
                guard !off else { return }
                // A stencil, a color key and alpha inside a JPEG 2000 image let through what
                // the checks cannot tell; a soft mask they read.
                var flag: CGPDFBoolean = 0
                var other: CGPDFObjectRef?
                var inData: CGPDFInteger = 0
                let known = !(CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &flag) && flag != 0)
                    && !CGPDFDictionaryGetObject(dictionary, "Mask", &other)
                    && !(CGPDFDictionaryGetInteger(dictionary, "SMaskInData", &inData) && inData != 0)
                    && !filters(dictionary).contains("JPXDecode")
                var mask: CGPDFStreamRef?
                _ = CGPDFDictionaryGetStream(dictionary, "SMask", &mask)
                drawing.image(known: known, mask: mask)
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
                var bounds = CGRect.infinite
                var box: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "BBox", &box), let box, CGPDFArrayGetCount(box) == 4 {
                    var n = [CGPDFReal](repeating: 0, count: 4)
                    for index in 0..<4 { _ = CGPDFArrayGetNumber(box, index, &n[index]) }
                    bounds = CGRect(x: min(n[0], n[2]), y: min(n[1], n[3]), width: abs(n[2] - n[0]), height: abs(n[3] - n[1]))
                }
                // A form without its own resources is rare, and old: it uses the page's.
                var own: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
                guard let resources = own ?? drawing.pageResources else { return }
                let inner = CGPDFContentStreamCreateWithStream(xobject, resources, stream)
                defer { CGPDFContentStreamRelease(inner) }
                // A form draws inside its own graphics state, clipped to its box, and what it
                // leaves on the stack, an unbalanced "q", ends with it.
                let saved = drawing.states.count
                let placed = matrix.concatenating(drawing.state.transform)
                var inside = drawing.state
                inside.transform = placed
                if !bounds.isInfinite { inside.clip = inside.clip.intersection(bounds.applying(placed)) }
                drawing.states.append(inside)
                let text = (drawing.textMatrix, drawing.lineMatrix, drawing.stretch, drawing.path, drawing.clipNext)
                // A form in a layer switched off is read for the text it shows, which a reader
                // does not see.
                let outer = drawing.offText
                if off && outer == nil { drawing.offText = "" }
                drawing.depth += 1
                drawing.run(inner)
                drawing.depth -= 1
                if off && outer == nil {
                    drawing.switchedOff.append((bounds.isInfinite ? .infinite : bounds.applying(placed), drawing.offText ?? ""))
                    drawing.offText = nil
                }
                drawing.states.removeLast(drawing.states.count - saved)
                (drawing.textMatrix, drawing.lineMatrix, drawing.stretch, drawing.path, drawing.clipNext) = text
            default:
                break
            }
        }
        // An image drawn inline in the content stream: what it lets through is not read.
        on("EI") { _, drawing in drawing.image(known: false) }
        CGPDFOperatorTableSetCallback(table, "q") { dispatch("q", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Q") { dispatch("Q", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "cm") { dispatch("cm", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "gs") { dispatch("gs", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "m") { dispatch("m", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "l") { dispatch("l", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "c") { dispatch("c", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "v") { dispatch("v", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "y") { dispatch("y", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "re") { dispatch("re", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "W") { dispatch("W", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "W*") { dispatch("W*", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "n") { dispatch("n", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "f") { dispatch("f", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "F") { dispatch("F", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "f*") { dispatch("f*", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "S") { dispatch("S", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "s") { dispatch("s", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "B") { dispatch("B", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "B*") { dispatch("B*", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "b") { dispatch("b", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "b*") { dispatch("b*", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "BT") { dispatch("BT", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "ET") { dispatch("ET", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tm") { dispatch("Tm", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Td") { dispatch("Td", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "TD") { dispatch("TD", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "TL") { dispatch("TL", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tr") { dispatch("Tr", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tz") { dispatch("Tz", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tc") { dispatch("Tc", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tw") { dispatch("Tw", $0, $1) }
        CGPDFOperatorTableSetCallback(table, "Tf") { dispatch("Tf", $0, $1) }
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
