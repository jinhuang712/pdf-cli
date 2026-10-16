import CoreGraphics
import CoreText
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

    /// Whether a reader tells the color from another, by the test the ink count uses.
    func stands(apartFrom other: Color) -> Bool {
        func part(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        let (red, green, blue) = (part(red), part(green), part(blue))
        let (otherRed, otherGreen, otherBlue) = (part(other.red), part(other.green), part(other.blue))
        if max(abs(red - otherRed), abs(green - otherGreen), abs(blue - otherBlue)) > Visibility.hueStep { return true }
        let first = Visibility.luminance(red, green, blue), second = Visibility.luminance(otherRed, otherGreen, otherBlue)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05) >= Visibility.minContrast
    }
}

/// What a reader can see of a page (DESIGNS.md → Decision: hidden text found by ink, with the
/// drawing commands for what ink cannot tell). The page is drawn in color, with its annotations,
/// and a word with no ink in its box is not drawn, or drawn in the color behind it. The page's
/// drawing commands add what ink cannot tell: where and when each piece of text is drawn, images
/// and shapes drawn over text after it, text placed off the page, text in a layer switched off,
/// and a scan's own image under its text layer.
struct Visibility {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat
    let crop: CGRect
    let drawing: Drawing
    let page: PDFPage
    /// The page's document, held while the check runs: CGPDF names an object by the same
    /// reference only while its document is open, and the layers switched off are found so.
    let document: PDFDocument?
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
    static let ocrCalls = 24
    /// ... and stops once it and the page's own drawing have spent this long: each call draws
    /// its area again, which a page of huge images makes slow.
    static let ocrSeconds = 3.0
    /// The ink count reads at most about this many pixels of a box; a larger box is read every
    /// few pixels each way.
    static let inkSamples = 60_000
    /// Annotations a reader sees through or that draw nothing over the page: text markup, which
    /// viewers draw blending into the page, links and pop-up notes.
    static let seeThrough: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly", "Link", "Popup"]

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

    /// A coordinate as a whole number of pixels, a huge or broken one held to a range any page
    /// fits in.
    static func pixel(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(-1e9, min(1e9, value)))
    }

    /// What OCR reads where images cover text, read once per area, when a word under it is first
    /// checked, the areas, what OCR has spent, and a table the ink test counts colors in, kept
    /// for the page.
    final class OCRCache: @unchecked Sendable {
        /// The lines OCR read in each area, in page space, as letters and digits run together.
        var lines: [Int: [(rect: CGRect, text: String)]] = [:]
        /// The areas OCR reads: images drawn after text whose surroundings meet, read together.
        var areas: [CGRect] = []
        /// Which area each image drawn after text belongs to.
        var area: [Int: Int] = [:]
        var calls = 0
        var spent: CGFloat = 0
        var seconds: Double = 0
        /// The areas OCR could not read.
        var failed = Set<Int>()
        var counts = [Int32](repeating: 0, count: 1 << 15)
        var sums = [Int32](repeating: 0, count: 3 << 15)
        /// Whether each band along a line holds ink, by its edges in half points.
        var bandInk: [Int: Bool] = [:]
    }

    /// The ink in a word's box.
    struct Ink {
        /// The pixels whose color a reader tells from the color behind them, rules aside, among
        /// those read.
        var count: Int
        var share: Double
        /// The color behind the word.
        var background: Color
        /// The ink in each column of pixels read, from the box's left edge.
        var columns: [Int]
        /// The box's left edge, in pixels of the drawn page.
        var left: Int
        /// Every how many pixels the count read, each way.
        var step: Int
    }

    /// What the check found about a word: hidden, and why, or seen, with its ink when ink judged it.
    enum Verdict {
        case hidden(HiddenReason)
        case seen(Ink?)
    }

    init?(page: PDFPage) {
        guard let reference = page.pageRef else { return nil }
        let crop = page.bounds(for: .cropBox)
        // A poster-sized page is checked by its drawing commands alone, and a page too large to
        // draw not at all.
        let area = crop.width * Visibility.scale * crop.height * Visibility.scale
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0, area <= 25_000_000 else { return nil }
        let width = Int(crop.width * Visibility.scale), height = Int(crop.height * Visibility.scale)
        guard width > 0, height > 0 else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
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
            // Readers draw annotations over the page, and CoreGraphics leaves them out: a white
            // square annotation hides the text under it.
            // PDFKit draws an annotation as the page is shown, from the media box's corner and
            // turned by the page's rotation; the drawing here is in the page's own space.
            let shown = page.transform(for: .mediaBox).inverted()
            for annotation in page.annotations where annotation.shouldDisplay && !Visibility.seeThrough.contains(annotation.type ?? "") {
                context.saveGState()
                context.concatenate(shown)
                annotation.draw(with: .mediaBox, in: context)
                context.restoreGState()
            }
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
        self.width = width
        self.height = height
        self.scale = Visibility.scale
        self.crop = crop
        self.document = page.document
        self.drawing = Drawing(page: reference, crop: crop)
        self.page = page
        // A page slow to draw is slow to draw again for OCR: its drawing counts against OCR's time.
        ocr.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
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
    ///   - squeezed: its letters' boxes are slivers, by horizontal scaling or negative spacing.
    ///   - stacked: its letters' boxes barely move on from one to the next, which counts where no
    ///     string is found for the word: PDFKit gives the letters of a short slanted label nearly
    ///     the same box.
    func check(_ rect: CGRect, text: String, size: CGFloat, color: Color?, straight: Bool, squeezed: Bool = false,
               stacked: Bool = false) -> Verdict {
        let spelled = Visibility.normalized(text)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // The strings drawn where the word is, looked up only when a check below needs them: a
        // page can hold tens of thousands.
        let needed = stacked || !straight || drawing.anyOff || drawing.anyCrushed || drawing.underlay || drawing.overlay != nil
            || drawing.coverings.contains { $0.rect.intersection(rect).area >= 0.5 * rect.area }
            || drawing.coverings.lazy.filter { $0.rect.intersects(rect) }.prefix(2).count == 2
        let here = needed ? drawing.runs(at: center) : []
        // Text in a layer switched off, which CoreGraphics draws in some cases all the same: only
        // such text is drawn where the word is. Its strings need not spell the word: a CID font's
        // do not, nor a line drawn one glyph at a time.
        if here.contains(where: { $0.kind == .off }), !here.contains(where: { $0.kind != .off }) {
            return .hidden(.invisible)
        }
        // Type under 2 pt. The box must be small too: some files set text at 1 pt and scale it
        // up, and PDFKit gives the size before the scaling.
        if size > 0 && size < 2 && min(rect.height, rect.width) < 2 { return .hidden(.tiny) }
        // A scan's text layer reads as text (DESIGNS.md → Principles → Safety): its words can sit
        // a little off the image's, and the image shows them. It is drawn in a mode that paints
        // nothing over images that cover most of the page, or under such images. The word's own
        // strings decide, as a watermark's string drawn across the layer does not. Text drawn to
        // show on such a page, as a slide's over its background image, gets every check.
        let own = drawing.plausible(here, for: rect, spelled: spelled)
        let drawn = own.isEmpty ? here : own
        if drawing.underlay, !drawn.isEmpty, drawn.allSatisfy({ $0.kind == .invisible }),
           scanShows(rect, here: here, own: drawn, after: nil) { return .seen(nil) }
        // Under a scan's image, a word no string is found for, as one PDFKit gives a box off its
        // place, reads as text too.
        if let overlay = drawing.overlay, drawn.allSatisfy({ $0.order < overlay }),
           scanShows(rect, here: here, own: drawn, after: overlay) { return .seen(nil) }
        // Letters squeezed or stacked into a smudge, as the drawing commands set them: strings
        // that move the pen on by under 40% of their glyphs' widths. Where no string is found for
        // the word, its boxes tell. A scan's OCR layer squeezes and stretches its words to fit the
        // image, so this comes after the scan's tests.
        if squeezed || (own.isEmpty ? stacked : own.allSatisfy(\.crushed)) { return .hidden(.tiny) }
        // Letters set at an angle: PDFKit's boxes for them miss their ink, so ink cannot judge them.
        // A word whose own strings run along the page's axes is set straight all the same, though
        // PDFKit's box for it grows too tall for a straight line, as beside a glyph twice its size:
        // there ink judges the word as a whole, as PDFKit's boxes for its letters may lie a letter
        // off, on another line even.
        let alongAxes = !own.isEmpty && own.allSatisfy { $0.toText.axisAligned }
        guard straight || alongAxes else {
            // An opaque rectangle drawn after the word over most of its box hides it all the same.
            if let last = drawn.map(\.order).max(), drawing.coverings.contains(where: { cover in
                cover.shape && cover.exact && cover.order > last && cover.rect.intersection(rect).area >= 0.5 * rect.area
            }) { return .hidden(.invisible) }
            return .seen(nil)
        }
        // A point above and below the box, where PDFKit places some glyphs' boxes a little off
        // their ink; none to the sides, where the next word's ink starts.
        guard let ink = ink(in: rect.insetBy(dx: 0, dy: -1)) else { return .seen(nil) }
        if ink.count < 2 || ink.share < 0.005 {
            if let color, color.distance(ink.background) < 0.2 { return .hidden(.background) }
            return .hidden(.invisible)
        }
        switch covered(rect, text: text, own: own) {
        case .hidden(let reason): return .hidden(reason)
        // A word an image over it shows, as a scan's picture of the layer drawn under it, is
        // judged by the image, not letter by letter against the layer's places.
        case .shown: return .seen(nil)
        // A word in the invisible mode has no ink of its own to check letter by letter: what
        // shows there is the scan's, as where a note in the layer's size stood beside it.
        case nil: return .seen(straight && !(!drawn.isEmpty && drawn.allSatisfy { $0.kind == .invisible }) ? ink : nil)
        }
    }

    /// Whether a scan's image shows a line of its text layer, on or under the image: the band
    /// along the line around the word, three times its width each side, holds ink, as the image's
    /// picture of the line puts there, and no string drawn to show, about the size of the word's
    /// own, lies in the band to put the ink there instead, or to show the reader something else.
    /// The band, not the word's box: a scan's layer can sit a word off its picture, 23 pt on the
    /// OCR sample. A blank
    /// page-size image shows no line, and a string in a font that does not spell the word, drawn
    /// over an invisible one that does, is no scan's layer. A watermark's larger string across the
    /// layer leaves it a scan's.
    /// - Parameter after: the scan's image, for a layer drawn under it: only strings drawn after
    ///   it show.
    func scanShows(_ rect: CGRect, here: [Drawing.TextRun], own: [Drawing.TextRun], after image: Int?) -> Bool {
        let heights = own.map(\.height).sorted()
        let height = heights.isEmpty ? rect.height : heights[heights.count / 2]
        let reach = 3 * max(rect.width, rect.height)
        let band = CGRect(x: rect.minX - reach, y: rect.minY - 1, width: rect.width + 2 * reach, height: rect.height + 2).intersection(crop)
        guard !band.isNull, band.width > 0 else { return false }
        let rival = drawing.shownRuns(across: band).contains { run in
            (image.map { run.order > $0 } ?? true) && run.height >= 0.67 * height && run.height <= 1.5 * height
                && !own.contains { $0.order == run.order }
        }
        guard !rival else { return false }
        let key = [band.minX, band.minY, band.maxX, band.maxY].reduce(0) { $0 &* 65_537 &+ Visibility.pixel(($1 * 2).rounded()) }
        if let known = ocr.bandInk[key] { return known }
        let inked = ink(in: band).map { $0.count >= 2 && $0.share >= 0.005 } ?? false
        ocr.bandInk[key] = inked
        return inked
    }

    /// Strings the page draws to show, with ink, where PDFKit has no text: no box of a character
    /// of PDFKit's near them, and no text of the page's that spells them, as when its text map
    /// leaves out a Type 3 font's glyphs. Strings of at least 3 glyphs, along the page's axes,
    /// on the page; those on one line join. At most 20 places a page, each with what its
    /// strings spell, which for a font without a text map may not be what it shows.
    /// - Parameters:
    ///   - boxes: PDFKit's boxes of the page's characters, in page space, those of use: PDFKit gives
    ///     some a box a line long, whose center lies between lines.
    ///   - text: PDFKit's text of the page.
    /// - Returns: the places, and the share of the glyphs the page draws to show that they hold.
    func unread(near boxes: [CGRect], in text: String) -> (places: [(rect: CGRect, text: String)], share: Double) {
        let cell: CGFloat = 12
        func key(_ x: CGFloat, _ y: CGFloat) -> Int {
            Visibility.pixel(((x - crop.minX) / cell).rounded(.down)) &* 100_003 &+ Visibility.pixel(((y - crop.minY) / cell).rounded(.down))
        }
        var centers: [Int: [CGPoint]] = [:]
        for box in boxes {
            centers[key(box.midX, box.midY), default: []].append(CGPoint(x: box.midX, y: box.midY))
        }
        func pdfKitHasText(in area: CGRect) -> Bool {
            let x0 = Int(((area.minX - crop.minX) / cell).rounded(.down)), x1 = Int(((area.maxX - crop.minX) / cell).rounded(.down))
            let y0 = Int(((area.minY - crop.minY) / cell).rounded(.down)), y1 = Int(((area.maxY - crop.minY) / cell).rounded(.down))
            guard x1 - x0 < 400, y1 - y0 < 400 else { return true }
            for x in x0...x1 {
                for y in y0...y1 where centers[x &* 100_003 &+ y]?.contains(where: { area.contains($0) }) == true { return true }
            }
            return false
        }
        let spelled = Visibility.normalized(text)
        var found: [(rect: CGRect, text: String)] = []
        var drawn = 0, missing = 0
        for run in drawing.runs where run.kind == .shown && crop.contains(CGPoint(x: run.bounds.midX, y: run.bounds.midY)) {
            drawn += run.glyphs
        }
        for run in drawing.runs where run.kind == .shown && run.glyphs >= 3 && run.toText.axisAligned {
            let rect = run.bounds.intersection(crop)
            guard !rect.isNull, rect.width > 0, rect.height > 0, crop.contains(CGPoint(x: run.bounds.midX, y: run.bounds.midY)),
                  !pdfKitHasText(in: run.bounds.insetBy(dx: -0.5 * run.height, dy: -0.5 * run.height)) else { continue }
            let own = Visibility.normalized(run.shown)
            if own.count >= 3, spelled.contains(own) { continue }
            guard let ink = ink(in: rect), ink.count >= 2, ink.share >= 0.005 else { continue }
            missing += run.glyphs
            let line = TextCleanup.line(run.shown)
            if let last = found.last, last.rect.insetBy(dx: -run.height, dy: -0.3 * run.height).intersects(rect) {
                found[found.count - 1] = (last.rect.union(rect), String((last.text + " " + line).prefix(300)))
            } else if found.count < 20 {
                found.append((rect, String(line.prefix(300))))
            }
        }
        return (found, drawn > 0 ? Double(missing) / Double(drawn) : 0)
    }

    /// What an image or shape over a word does to it: hides it, or shows it, as a scan's picture
    /// of its text layer does.
    enum Under: Equatable {
        case hidden(HiddenReason)
        case shown
    }

    /// Whether an image or a shape drawn after a word hides it. Ink cannot tell: under an image,
    /// the ink may be the image's own, and labels drawn over a black box put ink in the box. The
    /// drawing commands tell when the word was drawn and how much each image lets through: an
    /// image that lets most through hides nothing, and an opaque one, drawn after the word and
    /// exactly over it, hides it, as does an opaque rectangle or shading. Between the two, and
    /// where the commands cannot tell, as for a blend mode, a stencil or a picture turned or
    /// clipped to a curve, OCR reads what shows there, for a word in a script it reads.
    /// - Parameter own: the runs of text that may have drawn the word.
    func covered(_ rect: CGRect, text: String, own: [Drawing.TextRun]) -> Under? {
        let over = drawing.coverings.indices.filter { drawing.coverings[$0].rect.intersection(rect).area >= 0.5 * rect.area }
        guard !over.isEmpty else { return union(rect, text: text, own: own) }
        // With no run found for the word, an image drawn after any text may cover it, and OCR
        // decides.
        let first = own.map(\.order).min() ?? -1
        let last = own.map(\.order).max()
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        for index in over where drawing.coverings[index].order > first {
            let cover = drawing.coverings[index]
            let after = last.map { cover.order > $0 } ?? false
            if cover.shape {
                if cover.exact && after { return .hidden(.invisible) }
                continue
            }
            let alpha = drawing.alpha(of: cover, over: rect)
            if let alpha, alpha.high <= 0.35 { continue }
            // An opaque image drawn exactly over the word hides it, unless it shows the word, as a
            // scan's picture of a text layer drawn under it does, over part of the page or all of
            // it: OCR tells, for a word it can read. Past OCR's cap, or for a word OCR cannot
            // vouch for, the image hides it.
            if let alpha, alpha.low >= 0.9, cover.exact, after {
                guard letters >= 3, Visibility.ocrReads(text), let seen = ocrText(index, near: rect) else { return .hidden(.covered) }
                return Visibility.read(Visibility.normalized(text), in: seen) ? .shown : .hidden(.covered)
            }
            guard letters >= 3, let seen = ocrText(index, near: rect) else { continue }
            if Visibility.read(Visibility.normalized(text), in: seen) { return .shown }
            // OCR cannot vouch for a script it does not read, as Greek: the word reads as seen.
            if Visibility.ocrReads(text) { return .hidden(.covered) }
        }
        return union(rect, text: text, own: own)
    }

    /// Opaque images and shapes drawn exactly over a word after it, each over less than half of
    /// it, that together cover most of it, as two pictures over a column of CJK, one word: they
    /// hide it, unless OCR reads it there.
    func union(_ rect: CGRect, text: String, own: [Drawing.TextRun]) -> Under? {
        guard let last = own.map(\.order).max(), rect.width > 0, rect.height > 0 else { return nil }
        let pieces = drawing.coverings.indices.filter { index in
            let cover = drawing.coverings[index]
            guard cover.order > last, cover.exact, cover.rect.intersects(rect) else { return false }
            if cover.shape { return true }
            return (drawing.alpha(of: cover, over: rect)?.low ?? 0) >= 0.9
        }
        guard pieces.count >= 2 else { return nil }
        // An 8 by 8 grid of points over the word.
        var inside = 0
        for row in 0..<8 {
            for column in 0..<8 {
                let point = CGPoint(x: rect.minX + (CGFloat(column) + 0.5) / 8 * rect.width,
                                    y: rect.minY + (CGFloat(row) + 0.5) / 8 * rect.height)
                if pieces.contains(where: { drawing.coverings[$0].rect.contains(point) }) { inside += 1 }
            }
        }
        guard inside * 10 >= 64 * 8 else { return nil }
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        let images = pieces.filter { !drawing.coverings[$0].shape }
        guard let image = images.first, letters >= 3, Visibility.ocrReads(text), let seen = ocrText(image, near: rect) else {
            return .hidden(images.isEmpty ? .invisible : .covered)
        }
        return Visibility.read(Visibility.normalized(text), in: seen) ? .shown : .hidden(.covered)
    }

    /// Whether OCR read a word: whole, or, for a word of 4 letters or more, with one letter
    /// missed, as OCR reads a comic font's "XSports" as "sports"; letters that look alike, as
    /// I, l and 1, O and 0, or rn and m, count as one.
    static func read(_ word: String, in seen: String) -> Bool {
        guard !word.isEmpty else { return true }
        func folded(_ text: String) -> String {
            String(text.replacingOccurrences(of: "rn", with: "m").map { character -> Character in
                switch character {
                case "i", "1": return "l"
                case "0": return "o"
                case "5": return "s"
                case "2": return "z"
                default: return character
                }
            })
        }
        let (word, seen) = (folded(word), folded(seen))
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
        drawing.coverings.contains { !$0.shape && $0.rect.intersection(rect).area >= 0.5 * rect.area }
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
        let joinable = drawing.coverings.indices.prefix(2_000).filter { ocr.area[$0] == nil && !drawing.coverings[$0].shape }
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

    /// What OCR reads near a word in the area of an image drawn over it: the lines that overlap
    /// a quarter of the word's box, as letters and digits run together, so a word is found inside
    /// whatever OCR joins it with, as "Reasoning(RDR)". The same words elsewhere in the area, as
    /// in a caption, do not count. Read at 300 dpi, upright. Nil past the page's cap, or when OCR
    /// could not read the area, and the page then says its check is incomplete.
    func ocrText(_ index: Int, near rect: CGRect) -> String? {
        let id = area(of: index)
        guard !ocr.failed.contains(id) else { return nil }
        if ocr.lines[id] == nil {
            let area = ocr.areas[id]
            guard ocr.calls < Visibility.ocrCalls, ocr.spent + area.area <= 2 * crop.area, ocr.seconds < Visibility.ocrSeconds else {
                drawing.incomplete = true
                return nil
            }
            ocr.calls += 1
            ocr.spent += area.area
            let started = DispatchTime.now().uptimeNanoseconds
            let lines = read(area)
            ocr.seconds += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            guard let lines else {
                ocr.failed.insert(id)
                drawing.incomplete = true
                return nil
            }
            ocr.lines[id] = lines
        }
        return (ocr.lines[id] ?? []).filter { $0.rect.intersection(rect).area >= 0.25 * rect.area }.map(\.text).joined()
    }

    /// The lines OCR reads in an area of the page, each with its box in page space. OCR draws the
    /// page as it is shown, turned by its rotation, so the area goes there and the lines come
    /// back. Nil when the area could not be drawn or read.
    func read(_ area: CGRect) -> [(rect: CGRect, text: String)]? {
        guard !area.isNull, !area.isEmpty else { return [] }
        let shown = page.transform(for: .cropBox)
        let region = area.applying(shown)
        guard let picture = OCR.render(page, dpi: 300, region: region), let lines = OCR.textRecognizerLines(picture) else { return nil }
        let back = shown.inverted()
        return lines.map { line in
            // A box normalized to the picture, its origin at the lower left.
            let box = CGRect(x: region.minX + line.box.minX * region.width, y: region.minY + line.box.minY * region.height,
                             width: line.box.width * region.width, height: line.box.height * region.height)
            return (box.applying(back), Visibility.normalized(line.text))
        }
    }

    /// The ink in a box: the pixels whose color differs from the box's most common color, by
    /// column, and that color. A row inked from side to side in one color is a rule, as a table's
    /// or an underline, or a strip of a shape, not letters, and does not count: two grey rules
    /// along white text's box would otherwise read as its ink. A box of more than
    /// `inkSamples` pixels is read every few pixels each way.
    func ink(in rect: CGRect) -> Ink? {
        let left = max(0, Visibility.pixel(((rect.minX - crop.minX) * scale).rounded(.down)))
        let right = min(width, Visibility.pixel(((rect.maxX - crop.minX) * scale).rounded(.up)))
        let top = max(0, Visibility.pixel(((crop.maxY - rect.maxY) * scale).rounded(.down)) - 1)
        let bottom = min(height, Visibility.pixel(((crop.maxY - rect.minY) * scale).rounded(.up)) + 1)
        guard right > left, bottom > top else { return nil }
        let step = max(1, Int((Double((right - left) * (bottom - top)) / Double(Visibility.inkSamples)).squareRoot().rounded(.up)))
        // The color behind the word: the most common one in the box, from every other pixel read
        // each way, by 5 bits a part, with the sums of its pixels' parts, counted in tables kept
        // for the page. Letters never fill most of their box; rules along its border can fill
        // most of the border.
        var common = 0, most = 0
        var touched: [Int] = []
        var base = (0, 0, 0)
        pixels.withUnsafeBufferPointer { pixels in
            ocr.counts.withUnsafeMutableBufferPointer { counts in
                ocr.sums.withUnsafeMutableBufferPointer { sums in
                    for row in stride(from: top, to: bottom, by: bottom - top > 4 ? 2 * step : step) {
                        for column in stride(from: left, to: right, by: right - left > 4 ? 2 * step : step) {
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
        let span = (right - left + step - 1) / step
        var columns = [Int](repeating: 0, count: span)
        var inked = [Int](repeating: 0, count: span)
        var count = 0, rows = 0
        pixels.withUnsafeBufferPointer { pixels in
            for row in stride(from: top, to: bottom, by: step) {
                rows += 1
                var found = 0, key = -1, oneColor = true
                for (index, column) in stride(from: left, to: right, by: step).enumerated() {
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
                    inked[found] = index
                    found += 1
                }
                if span >= 8 && oneColor && found * 10 >= span * 9 { continue }
                count += found
                for index in 0..<found { columns[inked[index]] += 1 }
            }
        }
        return Ink(count: count, share: Double(count) / Double(span * max(1, rows)),
                   background: Color(red: CGFloat(base.0) / 255, green: CGFloat(base.1) / 255, blue: CGFloat(base.2) / 255),
                   columns: columns, left: left, step: step)
    }

    /// Whether a word's ink leaves a stretch of its box as wide as a narrow letter without ink,
    /// as where its letters are hidden one by one, so they are checked one by one.
    func gapped(_ ink: Ink, height: CGFloat) -> Bool {
        let limit = max(3, Visibility.pixel(0.2 * height * scale) / ink.step)
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
        let start = (Visibility.pixel(((letter.minX - crop.minX) * scale).rounded(.down)) - ink.left) / ink.step
        let end = (Visibility.pixel(((letter.maxX - crop.minX) * scale).rounded(.up)) - ink.left) / ink.step
        let trim = (end - start) / 5
        let from = max(0, start + trim), to = min(ink.columns.count, max(start + trim + 1, end - trim))
        guard from < to else { return true }
        return ink.columns[from..<to].reduce(0, +) >= 2
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension CGAffineTransform {
    /// Turns nothing but by quarter turns: a rectangle stays a rectangle along the page's axes.
    var axisAligned: Bool { (abs(b) < 1e-9 && abs(c) < 1e-9) || (abs(a) < 1e-9 && abs(d) < 1e-9) }
    var invertible: Bool { abs(a * d - b * c) > 1e-12 }
}

/// What a page's drawing commands tell about its text, read with CGPDFScanner: where each piece
/// of text is drawn, in what mode, layer and order, the images and shapes drawn after text, with
/// how much they let through, text placed off the page, and images that together cover most of
/// the page, as a scan's.
final class Drawing {
    /// Where one string of text is drawn: from where it starts as far as its glyphs move the pen,
    /// by the font's widths, and a little more. A word drawn by it lies within. Text space here is
    /// the string's own, where its glyphs are the font size tall.
    struct TextRun {
        enum Kind { case shown, invisible, off }

        /// When it was drawn, among the page's text, images and shapes.
        var order: Int
        /// From page space to the string's text space.
        var toText: CGAffineTransform
        /// How far the pen moves: across, or, for a font set down the page, down.
        var reach: CGFloat
        var vertical: Bool
        var size: CGFloat
        /// Shown; drawn in a mode that paints nothing, or with no opacity, as a scan's text
        /// layer; or in a layer switched off.
        var kind: Kind
        /// Its spacing pulls its letters back over most of their widths, or its scaling squeezes
        /// them to under a quarter: a smudge.
        var crushed: Bool
        /// What the text since the pen last moved by a command spells, this string included, as
        /// letters and digits, as far as its strings spell it: a CID font's may not.
        var text: String
        /// How tall its glyphs are in page space, and whether it runs across the page rather
        /// than down it.
        var height: CGFloat
        var across: Bool
        /// Its bounds in page space, for a quick test.
        var bounds: CGRect
        /// How many glyphs this string draws, and its own text, as its codes spell it.
        var glyphs: Int = 0
        var shown: String = ""

        func holds(_ point: CGPoint) -> Bool {
            guard bounds.contains(point) else { return false }
            let local = point.applying(toText)
            let margin = 0.3 * size
            if vertical {
                return abs(local.x) <= 0.8 * size && local.y >= min(0, reach) - margin && local.y <= max(0, reach) + margin
            }
            return local.x >= min(0, reach) - margin && local.x <= max(0, reach) + margin && local.y >= -0.5 * size && local.y <= 1.2 * size
        }
    }

    /// How far each code of a font moves the pen, in thousandths of the font size: from the
    /// font's widths, from CoreText for a standard font that gives none, or 600, about an average
    /// letter's, when neither tells.
    final class Widths {
        var table = [CGFloat](repeating: 600, count: 256)
        var cid: [Int: CGFloat] = [:]
        var fallback: CGFloat = 600
        var twoBytes = false
        var vertical = false

        nonisolated(unsafe) static let unknown = Widths()

        /// How far a string moves the pen, in thousandths of the font size, how many glyphs it
        /// draws, and how many of its codes are single-byte spaces, which word spacing moves.
        func measure(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> (width: CGFloat, glyphs: Int, spaces: Int) {
            var width: CGFloat = 0, glyphs = 0, spaces = 0
            if twoBytes {
                for index in stride(from: 0, to: count - 1, by: 2) {
                    width += cid[Int(bytes[index]) << 8 | Int(bytes[index + 1])] ?? fallback
                    glyphs += 1
                }
            } else {
                for index in 0..<count {
                    width += table[Int(bytes[index])]
                    if bytes[index] == 0x20 { spaces += 1 }
                }
                glyphs = count
            }
            return (width, glyphs, spaces)
        }

        /// Calls `body` with each glyph's width, in thousandths of the font size, and whether its
        /// code is a single-byte space.
        func each(_ bytes: UnsafePointer<UInt8>, _ count: Int, _ body: (CGFloat, Bool) -> Void) {
            if twoBytes {
                for index in stride(from: 0, to: count - 1, by: 2) { body(cid[Int(bytes[index]) << 8 | Int(bytes[index + 1])] ?? fallback, false) }
            } else {
                for index in 0..<count { body(table[Int(bytes[index])], bytes[index] == 0x20) }
            }
        }

        /// A font's widths, from its dictionary.
        static func read(_ font: CGPDFDictionaryRef) -> Widths {
            let widths = Widths()
            var name: UnsafePointer<CChar>?
            let subtype = CGPDFDictionaryGetName(font, "Subtype", &name) ? name.map(String.init(cString:)) : nil
            if subtype == "Type0" {
                // Two bytes a code; widths by CID, read where the codes are the CIDs.
                widths.twoBytes = true
                let encoding = CGPDFDictionaryGetName(font, "Encoding", &name) ? name.map(String.init(cString:)) : nil
                widths.vertical = encoding?.hasSuffix("-V") == true
                widths.fallback = 1000
                var descendants: CGPDFArrayRef?, descendant: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                      CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return widths }
                var standard: CGPDFReal = 1000
                if CGPDFDictionaryGetNumber(descendant, "DW", &standard) { widths.fallback = standard }
                var list: CGPDFArrayRef?
                guard encoding == "Identity-H" || encoding == "Identity-V", !widths.vertical,
                      CGPDFDictionaryGetArray(descendant, "W", &list), let list else { return widths }
                // CIDs run from 0 to 65,535; a list that writes more than 200,000 widths in all, as
                // the same ranges over and over, stops there.
                var index = 0, written = 0
                let count = min(CGPDFArrayGetCount(list), 20_000)
                while index + 1 < count, written < 200_000 {
                    var first: CGPDFInteger = 0, last: CGPDFInteger = 0, width: CGPDFReal = 0
                    var each: CGPDFArrayRef?
                    guard CGPDFArrayGetInteger(list, index, &first), first >= 0, first <= 65_535 else { break }
                    if CGPDFArrayGetArray(list, index + 1, &each), let each {
                        for offset in 0..<min(CGPDFArrayGetCount(each), 65_536 - first) where CGPDFArrayGetNumber(each, offset, &width) {
                            widths.cid[first + offset] = width
                            written += 1
                        }
                        index += 2
                    } else if index + 2 < count, CGPDFArrayGetInteger(list, index + 1, &last), CGPDFArrayGetNumber(list, index + 2, &width) {
                        // A last CID far below the first, as a hostile file writes, stops at the first.
                        let top = max(first, min(last, 65_535))
                        for code in first...top { widths.cid[code] = width }
                        written += top - first + 1
                        index += 3
                    } else {
                        break
                    }
                }
                return widths
            }
            // A Type 3 font's widths are in its glyph space, which its matrix scales.
            var scale: CGFloat = 1
            var matrix: CGPDFArrayRef?, first: CGPDFReal = 0.001
            if subtype == "Type3", CGPDFDictionaryGetArray(font, "FontMatrix", &matrix), let matrix,
               CGPDFArrayGetNumber(matrix, 0, &first) {
                scale = abs(first) * 1000
            }
            var list: CGPDFArrayRef?, firstCode: CGPDFInteger = 0
            if CGPDFDictionaryGetArray(font, "Widths", &list), let list {
                // A simple font's codes run from 0 to 255: a first code far outside, as only a
                // broken or hostile file has, cannot overflow the sums below.
                _ = CGPDFDictionaryGetInteger(font, "FirstChar", &firstCode)
                firstCode = max(-256, min(256, firstCode))
                var given: [CGFloat] = []
                for index in 0..<min(CGPDFArrayGetCount(list), 256) {
                    var width: CGPDFReal = 0
                    given.append(CGPDFArrayGetNumber(list, index, &width) ? width * scale : 0)
                }
                // Codes the widths leave out move by the font's missing width, or else by the
                // average of those given.
                var descriptor: CGPDFDictionaryRef?, missing: CGPDFReal = 0
                let nonzero = given.filter { $0 > 0 }
                var other = nonzero.isEmpty ? 600 * scale : nonzero.reduce(0, +) / CGFloat(nonzero.count)
                if CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor,
                   CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing), missing > 0 {
                    other = missing * scale
                }
                widths.table = (0..<256).map { code in
                    let index = code - firstCode
                    return index >= 0 && index < given.count ? given[index] : other
                }
                return widths
            }
            // A standard font gives no widths: CoreText has them, in the Windows encoding.
            var base: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(font, "BaseFont", &base), let base {
                let named = String(cString: base).split(separator: "+").last.map(String.init) ?? ""
                if ["Helvetica", "Times", "Courier", "Arial"].contains(where: { named.hasPrefix($0) }) {
                    let face = CTFontCreateWithName(named as CFString, 1000, nil)
                    widths.table = (0..<256).map { code in
                        guard code >= 32, let character = String(bytes: [UInt8(code)], encoding: .windowsCP1252)?.utf16.first else { return 600 }
                        var unit = character, glyph: CGGlyph = 0
                        guard CTFontGetGlyphsForCharacters(face, &unit, &glyph, 1) else { return 600 }
                        return CTFontGetAdvancesForGlyphs(face, .horizontal, [glyph], nil, 1)
                    }
                }
            }
            return widths
        }
    }

    /// An image or an opaque shape as drawn: where, when, and how much it lets through.
    struct Placed {
        var order: Int
        /// Its bounds in page space, within the clip's bounds.
        var rect: CGRect
        /// From the unit square to page space.
        var transform: CGAffineTransform
        /// The fill opacity it is drawn with, groups around it included.
        var opacity: CGFloat
        var mask: CGPDFStreamRef?
        /// How much it lets through is known: no stencil, color key, blend mode, soft mask in
        /// the state or clip by text.
        var known: Bool
        /// It lies exactly over its bounds: turned only by quarter turns, and clipped, if at
        /// all, to one rectangle along the page's axes.
        var exact: Bool
        /// An opaque filled rectangle or shading, not an image.
        var shape = false
        /// It fills its bounds, tilted a little at most, and clipped, if at all, to one rectangle
        /// along the page's axes: a hairline image along the page's diagonal does not.
        var fills = false
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
        /// The clip's bounds in page space, and whether the clip is exactly one rectangle along
        /// the page's axes, or none.
        var clip = CGRect.infinite
        var clipExact = true
        var mode = 0
        var fontSize: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var characterSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var leading: CGFloat = 0
        var font = Widths.unknown
        var fillAlpha: CGFloat = 1
        /// A blend mode other than Normal, a soft mask, or a clip by text: what an image lets
        /// through is unknown.
        var blended = false
        var softMask = false
        var textClip = false
        /// The fill color is a pattern, which may let what lies under it through.
        var patternFill = false
        /// What the transparency groups around the state add: their opacity, blend mode and soft
        /// mask, which a group's own content does not see (PDF 32000, 11.6.6).
        var groupAlpha: CGFloat = 1
        var groupBlended = false
        var groupSoftMask = false

        var opacity: CGFloat { fillAlpha * groupAlpha }
        var seeThrough: Bool { blended || softMask || textClip || groupBlended || groupSoftMask }
    }

    /// Where each piece of text is drawn, and whether any is in a layer switched off or crushed.
    var runs: [TextRun] = []
    var anyOff = false
    var anyCrushed = false
    /// The runs by band of the page, and those taller than 200 bands.
    var bands: [Int: [Int]]?
    var wide: [Int] = []
    /// Images and opaque shapes drawn after some text, which may cover it.
    var coverings: [Placed] = []
    /// Text placed off the page, as far as its strings spell it. PDFKit leaves it out of the
    /// page's text, so only the drawing commands know it is there.
    var offPage: [String] = []
    /// Images cover most of the page, as a scan's.
    var underlay = false
    /// Images drawn after text cover most of the page from this point in the drawing on, as a
    /// scan's image drawn over its text layer: text drawn before it is the scan's own.
    var overlay: Int?
    /// The check stopped at a limit, so what it did not read is unknown.
    var incomplete = false
    /// Every image the page draws, in page space.
    var images: [CGRect] = []

    let crop: CGRect
    var states = [State()]
    /// How deep `Q` may pop: a form's own states end with it, so it cannot pop its caller's.
    var floors = [1]
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    /// What the text drawn since the pen last moved by a command spells, as letters and digits.
    var spelling: String?
    var clipsText = false
    /// Each font's widths, read once, by its dictionary.
    var fonts: [OpaquePointer: Widths] = [:]
    /// The path being built, by its bounds in page space; whether it is one rectangle along the
    /// page's axes; and whether it then clips.
    /// Visibility expressions told so far.
    var told: [OpaquePointer: Bool?] = [:]
    var path = CGRect.null
    var rectangles = 0
    var curved = false
    /// The corners of a path of straight lines, in page space, and how many times it moved to a
    /// new start: four corners along the page's axes, from one start, are a rectangle too.
    var corners: [CGPoint] = []
    var starts = 0
    var clipNext = false
    var textSeen = false
    /// Marked content open on the page, each level switched off or not, and how many are off.
    var marked: [Bool] = []
    var offDepth = 0
    var depth = 0
    var operations = 0
    var order = 0
    var pageResources: CGPDFDictionaryRef?
    /// The layers the file switches off, by their dictionaries.
    var layersOff = Set<OpaquePointer>()
    /// The soft mask decoded last, by its stream: an image covers many words.
    var lastMask: (stream: OpaquePointer, mask: Mask?)?

    static let operationLimit = 200_000
    static let depthLimit = 8
    static let runLimit = 50_000
    /// The largest soft mask the checks decode, in values: a larger one goes to OCR.
    static let maskLimit = 4_000_000

    init(page: CGPDFPage, crop: CGRect) {
        self.crop = crop
        if let dictionary = page.dictionary, let object = PageKeyer.inherited(dictionary, "Resources") {
            var resources: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &resources) { pageResources = resources }
        }
        // The layers off by default: those listed off, and with a base state of off, every
        // layer not listed on.
        if let catalog = page.document?.catalog {
            var properties: CGPDFDictionaryRef?, defaults: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties), let properties,
               CGPDFDictionaryGetDictionary(properties, "D", &defaults), let defaults {
                func layers(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [OpaquePointer] {
                    var array: CGPDFArrayRef?
                    guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
                    return (0..<min(CGPDFArrayGetCount(array), 1_000)).compactMap { index in
                        var layer: CGPDFDictionaryRef?
                        return CGPDFArrayGetDictionary(array, index, &layer) ? layer.map(FactReader.identity) : nil
                    }
                }
                var base: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(defaults, "BaseState", &base), let base, String(cString: base) == "OFF" {
                    layersOff = Set(layers(properties, "OCGs")).subtracting(layers(defaults, "ON"))
                }
                layersOff.formUnion(layers(defaults, "OFF"))
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        run(stream)
        // Opaque images along the page's axes that together cover most of the page, counted on a
        // grid so overlaps count once: all of them, as a scan's under its text layer, and those
        // drawn after text, latest first, as a scan's over a text layer drawn under it.
        let cells = 40
        func add(_ rect: CGRect, to covered: inout Set<Int>) {
            let area = rect.intersection(crop)
            guard !area.isNull, area.width > 0, area.height > 0 else { return }
            func cell(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> Int {
                Visibility.pixel((value * CGFloat(cells)).rounded(rule))
            }
            let x0 = cell((area.minX - crop.minX) / crop.width, .down), x1 = cell((area.maxX - crop.minX) / crop.width, .up)
            let y0 = cell((area.minY - crop.minY) / crop.height, .down), y1 = cell((area.maxY - crop.minY) / crop.height, .up)
            for x in max(0, x0)..<min(cells, max(x1, x0 + 1)) {
                for y in max(0, y0)..<min(cells, max(y1, y0 + 1)) { covered.insert(y * cells + x) }
            }
        }
        var covered = Set<Int>()
        for rect in images { add(rect, to: &covered) }
        underlay = covered.count * 10 >= cells * cells * 8
        // Opaque ones only: a page-size watermark drawn last that lets the page through is no scan.
        var over = Set<Int>()
        for cover in coverings.reversed() where !cover.shape && cover.fills && cover.known && cover.mask == nil && cover.opacity >= 1 {
            add(cover.rect, to: &over)
            if over.count * 10 >= cells * cells * 8 {
                overlay = cover.order
                break
            }
        }
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

    /// The runs drawn to show whose bounds meet a band across the page, found through the bands
    /// `runs(at:)` makes.
    func shownRuns(across band: CGRect) -> [TextRun] {
        func index(_ y: CGFloat) -> Int { Visibility.pixel(((y - crop.minY) / 24).rounded(.down)) }
        _ = runs(at: CGPoint(x: crop.minX, y: band.midY))
        var seen = Set<Int>()
        var found: [TextRun] = []
        for each in index(band.minY)...max(index(band.minY), index(band.maxY)) {
            for at in (bands?[each] ?? []) + wide where seen.insert(at).inserted {
                let run = runs[at]
                if run.kind == .shown, run.bounds.intersects(band) { found.append(run) }
            }
        }
        return found
    }

    /// The runs of text that may hold a point, found through bands of the page 24 pt tall, made
    /// when first asked: a page can hold tens of thousands of runs and of words.
    func runs(at point: CGPoint) -> [TextRun] {
        func band(_ y: CGFloat) -> Int { Visibility.pixel(((y - crop.minY) / 24).rounded(.down)) }
        if bands == nil {
            var made: [Int: [Int]] = [:]
            for (index, run) in runs.enumerated() {
                let low = band(run.bounds.minY), high = band(run.bounds.maxY)
                guard high - low <= 200 else {
                    wide.append(index)
                    continue
                }
                for each in low...high { made[each, default: []].append(index) }
            }
            bands = made
        }
        return ((bands?[band(point.y)] ?? []) + wide).compactMap { runs[$0].holds(point) ? runs[$0] : nil }
    }

    /// The runs that may have drawn a word, of those that hold its center: the ones whose glyphs
    /// are about as tall as its box, across the page or down it as the run goes, and of those the
    /// ones that spell the word, when any does. A label drawn over the word reaches over it too.
    func plausible(_ runs: [TextRun], for rect: CGRect, spelled: String) -> [TextRun] {
        let sized = runs.filter { run in
            let extent = run.across ? rect.height : rect.width
            return extent >= 0.4 * run.height && extent <= 3 * run.height
        }
        let spelling = spelled.isEmpty ? [] : sized.filter { $0.text.contains(spelled) }
        return spelling.isEmpty ? sized : spelling
    }

    /// Whether a layer, or a membership dictionary over layers, is switched off.
    func off(_ properties: CGPDFDictionaryRef) -> Bool {
        var type: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(properties, "Type", &type), let type, String(cString: type) == "OCMD" else {
            return layersOff.contains(FactReader.identity(properties))
        }
        // A visibility expression, when the membership has one, decides before its layers and
        // policy (PDF 32000, 8.11.2.2).
        var expression: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(properties, "VE", &expression), let expression, let shown = shows(expression, depth: 0) {
            return !shown
        }
        var members: [Bool] = []
        var one: CGPDFDictionaryRef?, many: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(properties, "OCGs", &one), let one {
            members = [layersOff.contains(FactReader.identity(one))]
        } else if CGPDFDictionaryGetArray(properties, "OCGs", &many), let many {
            members = (0..<min(CGPDFArrayGetCount(many), 1_000)).compactMap { index in
                var layer: CGPDFDictionaryRef?
                return CGPDFArrayGetDictionary(many, index, &layer) ? layer.map { layersOff.contains(FactReader.identity($0)) } : nil
            }
        }
        guard !members.isEmpty else { return false }
        // Whether the membership shows, by its policy over its layers: any on, by default.
        var policy: UnsafePointer<CChar>?
        let named = CGPDFDictionaryGetName(properties, "P", &policy) ? policy.map(String.init(cString:)) : nil
        switch named {
        case "AllOn": return members.contains(true)
        case "AnyOff": return !members.contains(true)
        case "AllOff": return !members.allSatisfy { $0 }
        default: return members.allSatisfy { $0 }
        }
    }

    /// Whether a visibility expression shows: /Not, /And or /Or over layers and expressions,
    /// nested at most 8 deep. Nil when it is malformed.
    func shows(_ expression: CGPDFArrayRef, depth: Int) -> Bool? {
        // Each expression is told once: one whose operands share deeper expressions would
        // otherwise take twice as long a level, 30 s at 30 levels in the sixth review.
        let identity = unsafeBitCast(expression, to: OpaquePointer.self)
        if let known = told[identity] { return known }
        let shown = tell(expression, depth: depth)
        told[identity] = .some(shown)
        return shown
    }

    func tell(_ expression: CGPDFArrayRef, depth: Int) -> Bool? {
        var name: UnsafePointer<CChar>?
        guard depth < 32, CGPDFArrayGetName(expression, 0, &name), let name else { return nil }
        var operands: [Bool] = []
        for index in 1..<max(1, min(CGPDFArrayGetCount(expression), 1_000)) {
            var layer: CGPDFDictionaryRef?, inner: CGPDFArrayRef?
            if CGPDFArrayGetDictionary(expression, index, &layer), let layer {
                operands.append(!layersOff.contains(FactReader.identity(layer)))
            } else if CGPDFArrayGetArray(expression, index, &inner), let inner {
                // An operand that cannot be told, as one nested past the limit, leaves the whole
                // expression untold: dropping it could turn "and" into "on".
                guard let shown = shows(inner, depth: depth + 1) else { return nil }
                operands.append(shown)
            }
        }
        switch String(cString: name) {
        case "Not": return operands.count == 1 ? !operands[0] : nil
        case "And": return operands.isEmpty ? nil : operands.allSatisfy { $0 }
        case "Or": return operands.isEmpty ? nil : operands.contains(true)
        default: return nil
        }
    }

    /// A string's text, its length in bytes and glyphs, how far it moves the pen in text space,
    /// how far its glyphs' own widths would, spacing and scaling aside, and whether most of its
    /// letters are set on one spot, word by word (`Smudge`).
    typealias Measured = (text: String, bytes: Int, glyphs: Int, advance: CGFloat, nominal: CGFloat, smudged: Bool)

    /// Letters set on one spot within a string, word by word: a run of letters, between spaces or
    /// moves of the pen past a glyph's width, whose glyphs' places span under 40% of their widths.
    /// A string whose letters mostly fall in such runs is a smudge, though moves between its
    /// words carry the pen on past 40% of its glyphs' widths. Letters placed right to left, or
    /// mirrored, span their widths.
    struct Smudge {
        private var pen: CGFloat = 0, low: CGFloat = 0, high: CGFloat = 0, widths: CGFloat = 0, run = 0
        private var letters = 0, smudged = 0

        /// A glyph `width` wide, as scaling turns it, that moves the pen by `step`.
        mutating func glyph(step: CGFloat, width: CGFloat, space: Bool) {
            if space {
                end()
            } else {
                if run == 0 { (low, high) = (pen, pen) }
                low = min(low, pen, pen + width)
                high = max(high, pen, pen + width)
                widths += abs(width)
                run += 1
            }
            pen += step
        }

        /// The pen moved by a TJ array's number.
        mutating func move(_ amount: CGFloat) {
            if run > 0, abs(amount) > widths / CGFloat(run) { end() }
            pen += amount
        }

        mutating func end() {
            if run >= 2, high - low < 0.4 * widths { smudged += run }
            letters += run
            (run, widths) = (0, 0)
        }

        var isSmudge: Bool { letters >= 3 && smudged * 2 > letters }
    }

    func measure(_ string: CGPDFStringRef) -> Measured {
        var smudge = Smudge()
        let measured = measure(string, smudge: &smudge)
        smudge.end()
        return (measured.text, measured.bytes, measured.glyphs, measured.advance, measured.nominal, smudge.isSmudge)
    }

    func measure(_ string: CGPDFStringRef, smudge: inout Smudge) -> Measured {
        let length = CGPDFStringGetLength(string)
        let text = (CGPDFStringCopyTextString(string) as String?) ?? ""
        guard length > 0, let pointer = CGPDFStringGetBytePtr(string) else { return (text, length, 0, 0, 0, false) }
        let current = state
        let (width, glyphs, spaces) = current.font.measure(pointer, length)
        let size = current.fontSize
        // A font set down the page moves the pen down by the font size a glyph.
        if current.font.vertical {
            return (text, length, glyphs, CGFloat(glyphs) * (current.characterSpacing - size), CGFloat(glyphs) * abs(size), false)
        }
        let scale = current.horizontalScale
        current.font.each(pointer, length) { glyph, space in
            smudge.glyph(step: (glyph / 1000 * size + current.characterSpacing + (space ? current.wordSpacing : 0)) * scale,
                         width: glyph / 1000 * size * scale, space: space)
        }
        let advance = (width / 1000 * size + CGFloat(glyphs) * current.characterSpacing + CGFloat(spaces) * current.wordSpacing) * scale
        return (text, length, glyphs, advance, abs(width / 1000 * size * scale), false)
    }

    /// A string drawn: where the pen is, as far as it moves the pen, which then moves on.
    func show(_ shown: Measured) {
        let current = state
        let placed = textMatrix.concatenating(current.transform)
        let vertical = current.font.vertical
        textMatrix = CGAffineTransform(translationX: vertical ? 0 : shown.advance, y: vertical ? shown.advance : 0).concatenating(textMatrix)
        // Empty strings draw nothing, and do not count against the limit; a TJ array of numbers
        // alone moves the pen, above.
        guard shown.bytes > 0 else { return }
        operations += 1
        textSeen = true
        // Off the page when the point where the string starts is.
        let point = CGPoint.zero.applying(placed)
        if offDepth == 0, !crop.insetBy(dx: -1, dy: -1).contains(point), offPage.count < 100 {
            offPage.append(TextCleanup.line(shown.text))
        }
        if current.mode >= 4 { clipsText = true }
        spelling = (spelling ?? "") + Visibility.normalized(shown.text)
        defer { order += 1 }
        guard runs.count < Drawing.runLimit, placed.invertible else { return }
        let size = max(abs(current.fontSize), 0.5)
        let margin = 0.3 * size, low = min(0, shown.advance) - margin, high = max(0, shown.advance) + margin
        let local = vertical ? CGRect(x: -0.8 * size, y: low, width: 1.6 * size, height: high - low)
            : CGRect(x: low, y: -0.5 * size, width: high - low, height: 1.7 * size)
        let kind: TextRun.Kind = offDepth > 0 ? .off
            : current.mode == 3 || current.mode == 7 || (current.opacity == 0 && (current.mode == 0 || current.mode == 4)) ? .invisible
            : .shown
        // Glyphs that move the pen by under 40% of their widths, on or back, overlap into a
        // smudge; condensed type moves it by all of theirs, and so do letters placed right to
        // left, or mirrored.
        let crushed = abs(current.horizontalScale) < 0.25 || (!vertical && shown.glyphs >= 2 && abs(shown.advance) < 0.4 * shown.nominal)
            || shown.smudged
        // The way the text runs on the page, and how tall its glyphs stand across that way.
        let direction = vertical ? CGPoint(x: -placed.c, y: -placed.d) : CGPoint(x: placed.a, y: placed.b)
        let height = size * (vertical ? hypot(placed.a, placed.b) : hypot(placed.c, placed.d))
        anyOff = anyOff || kind == .off
        anyCrushed = anyCrushed || crushed
        runs.append(TextRun(order: order, toText: placed.inverted(), reach: shown.advance, vertical: vertical, size: size, kind: kind,
                            crushed: crushed, text: spelling ?? "", height: height,
                            across: abs(direction.x) >= abs(direction.y), bounds: local.applying(placed),
                            glyphs: shown.glyphs, shown: shown.text))
    }

    func image(known: Bool, mask: CGPDFStreamRef? = nil) {
        operations += 1
        // An image in a layer switched off covers nothing.
        guard offDepth == 0 else { return }
        defer { order += 1 }
        let current = state
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(current.transform).intersection(current.clip)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        let exact = current.transform.axisAligned && current.clipExact
        let transform = current.transform
        let spanned = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform)
        let fills = current.clipExact && spanned.width * spanned.height > 0
            && abs(transform.a * transform.d - transform.b * transform.c) >= 0.9 * spanned.width * spanned.height
        let placed = Placed(order: order, rect: rect, transform: transform, opacity: current.opacity, mask: mask,
                            known: known && !current.seeThrough, exact: exact, fills: fills)
        // A scan's image of the page fills its bounds and shows: a hairline image along the
        // diagonal, one clipped to two dots, or one drawn with no opacity, or with a soft mask
        // clear all over, spans the page by its bounds alone. Images whose opacity the commands
        // cannot read, as a stencil, a JPEG 2000 or an inline image, count, as scans are kept so:
        // until the sixth review they did not, and their text layers got 150 marks a page.
        let clear = mask != nil && (alpha(of: placed, over: rect)?.high ?? 1) < 0.5
        if fills, current.opacity >= 0.5, !clear { images.append(rect) }
        guard textSeen else { return }
        coverings.append(placed)
    }

    /// A shape filled after text: an opaque rectangle along the page's axes, or a shading over
    /// such a clip, covers what lies under it.
    func fill(_ rect: CGRect?) {
        let current = state
        guard textSeen, offDepth == 0, let rect, current.opacity >= 1, !current.seeThrough, !current.patternFill else { return }
        let area = rect.intersection(current.clip).intersection(crop)
        guard !area.isNull, area.width > 0, area.height > 0 else { return }
        coverings.append(Placed(order: order, rect: area, transform: .identity, opacity: 1, mask: nil, known: true,
                                exact: current.clipExact, shape: true))
        order += 1
    }

    /// Text placed at a new position starts a new run.
    func moveLine(_ x: CGFloat, _ y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
        spelling = nil
    }

    /// Points of the path being built, in page space.
    func extend(_ numbers: [CGFloat]) {
        curved = true
        add(numbers)
    }

    /// A straight line to a point, or a move to a new start.
    func line(_ numbers: [CGFloat], start: Bool) {
        if start { starts += 1 }
        corners.append(CGPoint(x: numbers[0], y: numbers[1]).applying(state.transform))
        add(numbers)
    }

    /// Whether the straight lines drawn make one rectangle along the page's axes.
    var linesMakeRectangle: Bool {
        var points: [CGPoint] = []
        for point in corners where points.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.01 }) ?? true { points.append(point) }
        if points.count == 5, let first = points.first, let last = points.last, hypot(first.x - last.x, first.y - last.y) <= 0.01 {
            points.removeLast()
        }
        guard starts == 1, points.count == 4 else { return false }
        return (0..<4).allSatisfy { index in
            let from = points[index], to = points[(index + 1) % 4]
            return (abs(from.x - to.x) <= 0.01) != (abs(from.y - to.y) <= 0.01)
        }
    }

    func add(_ numbers: [CGFloat]) {
        for index in stride(from: 0, to: numbers.count - 1, by: 2) {
            let point = CGPoint(x: numbers[index], y: numbers[index + 1]).applying(state.transform)
            path = path.union(CGRect(origin: point, size: .zero))
        }
    }

    /// The path ends: it clips if `W` asked, and a fill may cover text. Nil when the path is not
    /// one rectangle along the page's axes.
    func endPath(fills: Bool) {
        let rectangle = !curved && ((rectangles == 1 && corners.isEmpty) || (rectangles == 0 && linesMakeRectangle)) ? path : nil
        if fills { fill(rectangle) }
        if clipNext {
            state.clip = state.clip.intersection(path)
            state.clipExact = state.clipExact && rectangle != nil
        }
        path = .null
        rectangles = 0
        curved = false
        corners = []
        starts = 0
        clipNext = false
    }

    /// How much of an image lets through over a box, from least to most: its opacity times its
    /// soft mask's values there. Nil when the drawing commands cannot tell.
    func alpha(of image: Placed, over rect: CGRect) -> (low: CGFloat, high: CGFloat)? {
        guard image.known else { return nil }
        guard let stream = image.mask else { return (image.opacity, image.opacity) }
        let transform = image.transform
        guard transform.invertible, let mask = mask(stream) else { return nil }
        let area = rect.intersection(image.rect)
        guard !area.isNull else { return nil }
        let toUnit = transform.inverted()
        let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                       CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)].map { $0.applying(toUnit) }
        func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, min(1, value)) : 0 }
        let u0 = unit(corners.map(\.x).min()!), u1 = unit(corners.map(\.x).max()!)
        let v0 = unit(corners.map(\.y).min()!), v1 = unit(corners.map(\.y).max()!)
        // The image's first row is at the top of the unit square.
        let firstColumn = min(mask.width - 1, Int(u0 * CGFloat(mask.width)))
        let lastColumn = max(firstColumn + 1, min(mask.width, Int((u1 * CGFloat(mask.width)).rounded(.up))))
        let firstRow = min(mask.height - 1, Int((1 - v1) * CGFloat(mask.height)))
        let lastRow = max(firstRow + 1, min(mask.height, Int(((1 - v0) * CGFloat(mask.height)).rounded(.up))))
        var low = 255, high = 0
        for row in stride(from: firstRow, to: lastRow, by: max(1, (lastRow - firstRow) / 64)) {
            for column in stride(from: firstColumn, to: lastColumn, by: max(1, (lastColumn - firstColumn) / 64)) {
                let value = Int(mask.values[row * mask.width + column])
                low = min(low, value)
                high = max(high, value)
            }
        }
        guard low <= high else { return nil }
        return (CGFloat(low) / 255 * image.opacity, CGFloat(high) / 255 * image.opacity)
    }

    /// A soft mask's values, decoded when asked for, the last one kept. Nil for a mask the checks
    /// do not decode: larger than `maskLimit`, not 8 or 1 bits a value, or compressed as an
    /// image, as JPEG.
    func mask(_ stream: CGPDFStreamRef) -> Mask? {
        let key = unsafeBitCast(stream, to: OpaquePointer.self)
        if let last = lastMask, last.stream == key { return last.mask }
        let decoded = Drawing.decode(stream)
        lastMask = (key, decoded)
        return decoded
    }

    static func decode(_ stream: CGPDFStreamRef) -> Mask? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0, width <= maskLimit, height <= maskLimit, width * height <= maskLimit else { return nil }
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

    static func string(_ scanner: CGPDFScannerRef) -> CGPDFStringRef? {
        var value: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &value), let value else { return nil }
        return value
    }

    static func show(_ scanner: CGPDFScannerRef, _ drawing: Drawing) {
        guard let string = string(scanner) else { return }
        drawing.show(drawing.measure(string))
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
        on("Q") { _, drawing in if drawing.states.count > drawing.floors[drawing.floors.count - 1] { drawing.states.removeLast() } }
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
        // The fill color: a pattern may let what lies under it through.
        on("cs") { scanner, drawing in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            var pattern = String(cString: name) == "Pattern"
            var array: CGPDFArrayRef?
            if !pattern, let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ColorSpace", name),
               CGPDFObjectGetValue(object, .array, &array), let array {
                var first: UnsafePointer<CChar>?
                pattern = CGPDFArrayGetName(array, 0, &first) && first.map { String(cString: $0) } == "Pattern"
            }
            drawing.state.patternFill = pattern
        }
        for name in ["g", "rg", "k"] { on(name) { _, drawing in drawing.state.patternFill = false } }
        // The path, by its bounds, and the clip it makes.
        on("m") { scanner, drawing in numbers(scanner, 2).map { drawing.line($0, start: true) } }
        on("l") { scanner, drawing in numbers(scanner, 2).map { drawing.line($0, start: false) } }
        on("c") { scanner, drawing in numbers(scanner, 6).map(drawing.extend) }
        on("v") { scanner, drawing in numbers(scanner, 4).map(drawing.extend) }
        on("y") { scanner, drawing in numbers(scanner, 4).map(drawing.extend) }
        on("re") { scanner, drawing in
            guard let n = numbers(scanner, 4) else { return }
            drawing.rectangles += 1
            if !drawing.state.transform.axisAligned { drawing.curved = true }
            drawing.add([n[0], n[1], n[0] + n[2], n[1], n[0], n[1] + n[3], n[0] + n[2], n[1] + n[3]])
        }
        on("W") { _, drawing in drawing.clipNext = true }
        on("W*") { _, drawing in drawing.clipNext = true }
        for name in ["n", "S", "s"] { on(name) { _, drawing in drawing.endPath(fills: false) } }
        for name in ["f", "F", "f*", "B", "B*", "b", "b*"] { on(name) { _, drawing in drawing.endPath(fills: true) } }
        // An axial shading extended both ways, with no box of its own, fills the clip; others,
        // as a radial one, paint only part of it.
        on("sh") { scanner, drawing in
            var name: UnsafePointer<CChar>?
            var shading: CGPDFDictionaryRef?, extend: CGPDFArrayRef?, box: CGPDFArrayRef?
            var type: CGPDFInteger = 0
            var first: CGPDFBoolean = 0, second: CGPDFBoolean = 0
            guard drawing.state.clipExact, CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Shading", name),
                  CGPDFObjectGetValue(object, .dictionary, &shading), let shading,
                  CGPDFDictionaryGetInteger(shading, "ShadingType", &type), type == 2,
                  !CGPDFDictionaryGetArray(shading, "BBox", &box),
                  CGPDFDictionaryGetArray(shading, "Extend", &extend), let extend,
                  CGPDFArrayGetBoolean(extend, 0, &first), CGPDFArrayGetBoolean(extend, 1, &second), first != 0, second != 0
            else { return }
            drawing.fill(drawing.state.clip.isInfinite ? drawing.crop : drawing.state.clip)
        }
        // Marked content, which a layer switched off hides.
        on("BMC") { _, drawing in drawing.marked.append(false) }
        on("BDC") { scanner, drawing in
            // The properties: a dictionary in place, or the name of one in the resources.
            var properties: CGPDFDictionaryRef?
            var name: UnsafePointer<CChar>?
            var operand: CGPDFObjectRef?
            if CGPDFScannerPopObject(scanner, &operand), let operand, !CGPDFObjectGetValue(operand, .dictionary, &properties),
               CGPDFObjectGetValue(operand, .name, &name), let name,
               let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Properties", name) {
                _ = CGPDFObjectGetValue(object, .dictionary, &properties)
            }
            var tag: UnsafePointer<CChar>?
            let layered = CGPDFScannerPopName(scanner, &tag) && tag.map { String(cString: $0) } == "OC"
            let off = layered && properties.map(drawing.off) == true
            drawing.marked.append(off)
            if off { drawing.offDepth += 1 }
        }
        on("EMC") { _, drawing in
            if let off = drawing.marked.popLast(), off { drawing.offDepth -= 1 }
        }
        on("BT") { _, drawing in
            drawing.textMatrix = .identity
            drawing.lineMatrix = .identity
            drawing.spelling = nil
            drawing.clipsText = false
        }
        // Text drawn in a mode that clips leaves a clip by its glyphs.
        on("ET") { _, drawing in if drawing.clipsText { drawing.state.textClip = true } }
        on("Tm") { scanner, drawing in
            guard let n = numbers(scanner, 6) else { return }
            drawing.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            drawing.textMatrix = drawing.lineMatrix
            drawing.spelling = nil
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
        on("Tr") { scanner, drawing in numbers(scanner, 1).map { drawing.state.mode = Int(max(-1, min(8, $0[0]))) } }
        on("Tz") { scanner, drawing in numbers(scanner, 1).map { drawing.state.horizontalScale = $0[0] / 100 } }
        on("Tc") { scanner, drawing in numbers(scanner, 1).map { drawing.state.characterSpacing = $0[0] } }
        on("Tw") { scanner, drawing in numbers(scanner, 1).map { drawing.state.wordSpacing = $0[0] } }
        on("Tf") { scanner, drawing in
            guard let n = numbers(scanner, 1) else { return }
            drawing.state.fontSize = n[0]
            var name: UnsafePointer<CChar>?
            var font: CGPDFDictionaryRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name),
                  CGPDFObjectGetValue(object, .dictionary, &font), let font else {
                drawing.state.font = .unknown
                return
            }
            let key = FactReader.identity(font)
            if drawing.fonts[key] == nil { drawing.fonts[key] = Widths.read(font) }
            drawing.state.font = drawing.fonts[key] ?? .unknown
        }
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
            if let shown { drawing.show(drawing.measure(shown)) }
        }
        on("TJ") { scanner, drawing in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            var whole: Measured = ("", 0, 0, 0, 0, false)
            var smudge = Drawing.Smudge()
            let current = drawing.state
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    let piece = drawing.measure(string, smudge: &smudge)
                    whole = (whole.text + piece.text, whole.bytes + piece.bytes, whole.glyphs + piece.glyphs,
                             whole.advance + piece.advance, whole.nominal + piece.nominal, false)
                } else if CGPDFArrayGetNumber(array, index, &number) {
                    // A number moves the pen back by thousandths of the font size, a negative one on.
                    let move = -number / 1000 * current.fontSize * (current.font.vertical ? 1 : current.horizontalScale)
                    whole.advance += move
                    smudge.move(move)
                }
            }
            smudge.end()
            whole.smudged = !current.font.vertical && smudge.isSmudge
            drawing.show(whole)
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
            // draws some.
            var layer: CGPDFDictionaryRef?
            let off = CGPDFDictionaryGetDictionary(dictionary, "OC", &layer) && layer.map(drawing.off) == true
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
                // Each form drawn counts against the limit, as forms that each draw ten more
                // multiply fast.
                drawing.operations += 1
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
                // leaves on the stack, an unbalanced "q", ends with it; an unbalanced "Q" cannot
                // pop past it.
                let saved = drawing.states.count
                let placed = matrix.concatenating(drawing.state.transform)
                var inside = drawing.state
                inside.transform = placed
                if !bounds.isInfinite {
                    inside.clip = inside.clip.intersection(bounds.applying(placed))
                    inside.clipExact = inside.clipExact && placed.axisAligned
                }
                // A transparency group starts at full opacity, in Normal and with no soft mask,
                // and is drawn as a whole with what the state outside it holds.
                var group: CGPDFDictionaryRef?, kind: UnsafePointer<CChar>?
                if CGPDFDictionaryGetDictionary(dictionary, "Group", &group), let group,
                   CGPDFDictionaryGetName(group, "S", &kind), let kind, String(cString: kind) == "Transparency" {
                    inside.groupAlpha *= inside.fillAlpha
                    inside.groupBlended = inside.groupBlended || inside.blended
                    inside.groupSoftMask = inside.groupSoftMask || inside.softMask
                    inside.fillAlpha = 1
                    inside.blended = false
                    inside.softMask = false
                }
                drawing.states.append(inside)
                drawing.floors.append(drawing.states.count)
                let text = (drawing.textMatrix, drawing.lineMatrix, drawing.spelling, drawing.path, drawing.rectangles,
                            drawing.curved, drawing.clipNext, drawing.marked.count)
                if off { drawing.offDepth += 1 }
                drawing.depth += 1
                drawing.run(inner)
                drawing.depth -= 1
                if off { drawing.offDepth -= 1 }
                // Marked content a form leaves open ends with it.
                while drawing.marked.count > text.7 {
                    if drawing.marked.removeLast() { drawing.offDepth -= 1 }
                }
                drawing.floors.removeLast()
                drawing.states.removeLast(max(0, drawing.states.count - saved))
                (drawing.textMatrix, drawing.lineMatrix, drawing.spelling, drawing.path, drawing.rectangles,
                 drawing.curved, drawing.clipNext, _) = text
            default:
                break
            }
        }
        // An image drawn inline in the content stream: what it lets through is not read.
        on("EI") { _, drawing in drawing.image(known: false) }
        for (name, callback) in callbacks { CGPDFOperatorTableSetCallback(table, name, callback) }
        return table
    }()

    /// The C callback for each operator: each names its operator, since a C callback captures
    /// nothing.
    static let callbacks: [String: CGPDFOperatorCallback] = [
        "q": { dispatch("q", $0, $1) }, "Q": { dispatch("Q", $0, $1) }, "cm": { dispatch("cm", $0, $1) },
        "gs": { dispatch("gs", $0, $1) }, "cs": { dispatch("cs", $0, $1) }, "g": { dispatch("g", $0, $1) },
        "rg": { dispatch("rg", $0, $1) }, "k": { dispatch("k", $0, $1) }, "m": { dispatch("m", $0, $1) },
        "l": { dispatch("l", $0, $1) }, "c": { dispatch("c", $0, $1) }, "v": { dispatch("v", $0, $1) },
        "y": { dispatch("y", $0, $1) }, "re": { dispatch("re", $0, $1) }, "W": { dispatch("W", $0, $1) },
        "W*": { dispatch("W*", $0, $1) }, "n": { dispatch("n", $0, $1) }, "S": { dispatch("S", $0, $1) },
        "s": { dispatch("s", $0, $1) }, "f": { dispatch("f", $0, $1) }, "F": { dispatch("F", $0, $1) },
        "f*": { dispatch("f*", $0, $1) }, "B": { dispatch("B", $0, $1) }, "B*": { dispatch("B*", $0, $1) },
        "b": { dispatch("b", $0, $1) }, "b*": { dispatch("b*", $0, $1) }, "sh": { dispatch("sh", $0, $1) },
        "BMC": { dispatch("BMC", $0, $1) }, "BDC": { dispatch("BDC", $0, $1) }, "EMC": { dispatch("EMC", $0, $1) },
        "BT": { dispatch("BT", $0, $1) }, "ET": { dispatch("ET", $0, $1) }, "Tm": { dispatch("Tm", $0, $1) },
        "Td": { dispatch("Td", $0, $1) }, "TD": { dispatch("TD", $0, $1) }, "TL": { dispatch("TL", $0, $1) },
        "Tr": { dispatch("Tr", $0, $1) }, "Tz": { dispatch("Tz", $0, $1) }, "Tc": { dispatch("Tc", $0, $1) },
        "Tw": { dispatch("Tw", $0, $1) }, "Tf": { dispatch("Tf", $0, $1) }, "T*": { dispatch("T*", $0, $1) },
        "Tj": { dispatch("Tj", $0, $1) }, "'": { dispatch("'", $0, $1) }, "\"": { dispatch("\"", $0, $1) },
        "TJ": { dispatch("TJ", $0, $1) }, "Do": { dispatch("Do", $0, $1) }, "EI": { dispatch("EI", $0, $1) },
    ]
}
