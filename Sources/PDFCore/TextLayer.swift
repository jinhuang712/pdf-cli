import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// A rectangle as fractions of the page's crop box, measured from the top-left corner of the
/// unrotated page: [x, y, width, height].
public struct Box: Codable, Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        width = try values.decode(Double.self)
        height = try values.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        for value in [x, y, width, height] { try values.encode((value * 10_000).rounded() / 10_000) }
    }
}

public struct TextLine: Codable, Equatable, Sendable {
    public var text: String
    public var box: Box
}

/// A paragraph-like run of lines. Its text joins the lines, with line-end hyphens resolved.
public struct TextBlock: Codable, Equatable, Sendable {
    public var text: String
    public var box: Box
    public var lines: [TextLine]
    /// For a block read by OCR with enough words to judge: the share of its words that a second
    /// OCR reading of the page also finds (see `OCR.agreement(units:check:)`).
    public var agreement: Double? = nil
}

/// A word that two readings of the page spell with the same letters but break differently, as
/// when PDFKit loses spaces. The agent picks one reading with `pdf pick`.
public struct Unsure: Codable, Equatable, Sendable {
    /// The block that holds the word, counted from 0.
    public var block: Int
    /// Where the word starts in the block's text, in UTF-16 units.
    public var offset: Int
    /// The readings: first the text layer's, as the block's text holds it, then the one with
    /// OCR's word breaks or common words. A word that reads as words run together but splits no
    /// clean way has the first alone, so the agent knows to look at the image.
    public var readings: [String]

    /// The span offers two readings to pick from.
    public var pickable: Bool { readings.count == 2 }
    /// The line that holds the word.
    public var box: Box
}

/// A page's text layer, as the parse stores it.
public struct PageText: Codable, Equatable, Sendable {
    public var blocks: [TextBlock]
    public var words: Int
    /// Letter runs longer than 25 characters, a sign of lost spaces.
    public var runTogether: Int
    /// The mean confidence of OCR's lines, from 0 to 1. Nil for a page read from its text layer.
    /// The two engines score differently: on clean text, macOS 26's document recognizer gives
    /// about 0.5–0.7 and the older text recognizer 1.0, so a threshold must know the engine.
    public var confidence: Double? = nil
    /// The OCR engine that read the page: "document recognizer" or "text recognizer".
    public var ocrEngine: String? = nil
    /// The text layer that OCR replaced, kept so `--raw` can show it. Nothing goes missing
    /// without a trace (PHILOSOPHY.md).
    public var replacedText: String? = nil
    /// For a page read by OCR: the share of its words that a second OCR reading also finds. Nil
    /// when the page has too few words to judge, or the second reading failed.
    public var agreement: Double? = nil
    /// Words whose two readings differ in their breaks.
    public var unsure: [Unsure]? = nil
    /// For a text layer that looked garbled, so OCR was asked to read the page and could not:
    /// the share of the layer's characters that are letters or digits.
    public var layerScore: Double? = nil
    /// The page's fonts hide the spaces between words, and OCR could not read the page to
    /// restore them.
    public var spacesLost: Bool? = nil
    /// The number printed on the page, from the file's page labels, such as "237" or "iv",
    /// when it differs from the page's position in the file.
    public var label: String? = nil

    public var text: String { blocks.map(\.text).joined(separator: "\n\n") }
}

/// What PDFKit knows of each character on a page: its box, its font size, and how far its
/// baseline is raised.
struct Glyphs {
    /// Each character's box in page space, by UTF-16 offset, or nil for a space.
    let boxes: [CGRect?]
    let sizes: [CGFloat]
    let raises: [CGFloat]

    init(boxes: [CGRect?], sizes: [CGFloat], raises: [CGFloat]) {
        self.boxes = boxes
        self.sizes = sizes
        self.raises = raises
    }

    init(_ page: PDFPage, _ text: NSString) {
        boxes = Glyphs.boxes(page, text)
        var sizes = [CGFloat](repeating: 0, count: text.length)
        var raises = [CGFloat](repeating: 0, count: text.length)
        if let attributed = page.attributedString, attributed.length == text.length {
            let whole = NSRange(location: 0, length: attributed.length)
            attributed.enumerateAttribute(.font, in: whole) { value, range, _ in
                let size = (value as? NSFont)?.pointSize ?? 0
                for index in range.location..<NSMaxRange(range) { sizes[index] = size }
            }
            attributed.enumerateAttribute(NSAttributedString.Key("CTBaselineOffset"), in: whole) { value, range, _ in
                let raise = CGFloat((value as? NSNumber)?.doubleValue ?? 0)
                for index in range.location..<NSMaxRange(range) { raises[index] = raise }
            }
        }
        self.sizes = sizes
        self.raises = raises
    }

    /// The boxes of a page's characters. PDFKit's `characterBounds(at:)` counts glyphs, not
    /// characters, so after a ligature such as "fl", one glyph for two characters, it returns
    /// the box of the next character: on an arXiv title, the last letter of a line got the box
    /// of the next line's first. A selection of one character lands in the right place across
    /// the line, but spans the line's full height, so each character takes the glyph box that
    /// sits where its selection does, and the offset carries on to the next character.
    static func boxes(_ page: PDFPage, _ text: NSString) -> [CGRect?] {
        var boxes = [CGRect?](repeating: nil, count: text.length)
        var shift = 0
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            let paired = UTF16.isLeadSurrogate(unit) && index + 1 < text.length
                && UTF16.isTrailSurrogate(text.character(at: index + 1))
            let width = paired ? 2 : 1
            defer { index += width }
            guard !TextLayer.isSpace(unit),
                  let selected = page.selection(for: NSRange(location: index, length: width))?.bounds(for: page),
                  !selected.isEmpty else { continue }
            var found: CGRect?
            for candidate in [index - shift, index - shift - 1, index - shift + 1, index - shift - 2, index - shift + 2]
            where candidate >= 0 && candidate < text.length {
                let box = page.characterBounds(at: candidate)
                if abs(box.midX - selected.midX) <= max(1, selected.width / 2) && abs(box.midY - selected.midY) <= selected.height {
                    found = box
                    shift = index - candidate
                    break
                }
            }
            boxes[index] = found ?? selected
        }
        return boxes
    }

    /// The marks for a line's characters: "^" for one set smaller and raised against the line's
    /// main text, "_" for one set smaller and lowered. A run of the main size that PDFKit
    /// reports a little raised, as in a table cell, keeps no mark.
    func marks(_ indices: [Int]) -> [Int: Character] {
        var counts: [CGFloat: Int] = [:]
        for index in indices where sizes[index] > 0 { counts[(sizes[index] * 2).rounded() / 2, default: 0] += 1 }
        guard let main = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key else { return [:] }
        let base = indices.filter { abs(sizes[$0] - main) <= 0.05 * main }.map { raises[$0] }.sorted()
        let baseline = base.isEmpty ? 0 : base[base.count / 2]
        var marks: [Int: Character] = [:]
        for index in indices where sizes[index] > 0 && sizes[index] <= 0.85 * main {
            let lift = raises[index] - baseline
            if lift >= 0.1 * main { marks[index] = "^" } else if lift <= -0.04 * main { marks[index] = "_" }
        }
        return marks
    }
}

/// Builds a page's text layer from PDFKit: lines with their positions, grouped into blocks.
/// Block grouping uses positions only; columns, headers and footnotes come in milestone M2.
enum TextLayer {
    /// A line while the page is read, in points from the crop box's top-left corner.
    struct RawLine {
        var text: String
        var rect: CGRect
        /// The line ended with a soft hyphen: the word goes on in the next line.
        var softBreak: Bool
    }

    /// - Parameter spacesBefore: UTF-16 offsets in `page.string` where a space belongs, from
    ///   the space repair. Empty when the page needs none.
    static func read(_ page: PDFPage, spacesBefore: Set<Int> = []) -> PageText {
        let raw = page.string ?? ""
        let text = raw as NSString
        let crop = page.bounds(for: .cropBox)
        let glyphs = Glyphs(page, text)
        var lines: [RawLine] = []

        var start = 0
        while start <= text.length {
            var end = start
            while end < text.length, !isLineBreak(text.character(at: end)) { end += 1 }
            if let line = makeLine(text, start..<end, glyphs: glyphs, crop: crop, spacesBefore: spacesBefore) {
                lines.append(line)
            }
            start = end + 1
        }

        let blocks = group(lines, crop: crop, dehyphenator: Dehyphenator(pageText: raw))
        let joined = blocks.map(\.text).joined(separator: "\n")
        return PageText(blocks: blocks, words: TextCleanup.wordCount(joined),
                        runTogether: TextCleanup.runTogetherWords(joined))
    }

    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0 || isLineBreak(unit)
    }

    /// One line of the page string, with its rectangle from the boxes of its characters.
    /// Characters set smaller and raised or lowered, against the line's main text, get the
    /// marks `^{…}` and `_{…}`, as in `10^{-5}` and `x_{2}` (DESIGNS.md → Principles → Silent
    /// errors).
    static func makeLine(_ text: NSString, _ range: Range<Int>, glyphs: Glyphs, crop: CGRect,
                         spacesBefore: Set<Int>) -> RawLine? {
        var characters: [(index: Int, width: Int, isSpace: Bool)] = []
        var bounds = CGRect.null
        var index = range.lowerBound
        while index < range.upperBound {
            let unit = text.character(at: index)
            let paired = UTF16.isLeadSurrogate(unit) && index + 1 < range.upperBound
                && UTF16.isTrailSurrogate(text.character(at: index + 1))
            let width = paired ? 2 : 1
            characters.append((index, width, isSpace(unit)))
            if !isSpace(unit), let rect = glyphs.boxes[index], rect.width > 0 || rect.height > 0 {
                bounds = bounds.union(rect)
            }
            index += width
        }
        let marks = glyphs.marks(characters.filter { !$0.isSpace }.map(\.index))
        var piece = ""
        var open: Character?
        for character in characters {
            let mark = character.isSpace ? nil : marks[character.index]
            if spacesBefore.contains(character.index) {
                // A space the repair puts back ends a mark, as a space in the text does.
                if open != nil { piece += "}" }
                open = nil
                piece += " "
            }
            if mark != open {
                if open != nil { piece += "}" }
                if let mark { piece += "\(mark){" }
                open = mark
            }
            piece += text.substring(with: NSRange(location: character.index, length: character.width))
        }
        if open != nil { piece += "}" }
        let trimmed = piece.trimmingCharacters(in: .whitespaces)
        let softBreak = trimmed.hasSuffix("\u{00AD}")
        var cleaned = TextCleanup.line(piece)
        if softBreak { cleaned += "-" }
        guard !cleaned.isEmpty, !bounds.isNull else { return nil }
        let rect = CGRect(x: bounds.minX - crop.minX, y: crop.maxY - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        return RawLine(text: cleaned, rect: rect, softBreak: softBreak)
    }

    /// Groups lines into blocks. A new block starts where the next line moves up or sideways
    /// into another column, leaves a gap wider than about two thirds of a line, changes size
    /// by more than 30%, or starts an indented paragraph after a short line.
    static func group(_ lines: [RawLine], crop: CGRect, dehyphenator: Dehyphenator) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var current: [RawLine] = []
        var area = CGRect.null

        // A crop box with no area gives boxes in points rather than lose the text.
        let pageWidth = max(crop.width, 1), pageHeight = max(crop.height, 1)

        func flush() {
            guard !current.isEmpty else { return }
            let box = { (rect: CGRect) in
                Box(x: Double(rect.minX / pageWidth), y: Double(rect.minY / pageHeight),
                    width: Double(rect.width / pageWidth), height: Double(rect.height / pageHeight))
            }
            blocks.append(TextBlock(text: join(current, dehyphenator), box: box(area),
                                    lines: current.map { TextLine(text: $0.text, box: box($0.rect)) }))
            current = []
            area = .null
        }

        for line in lines {
            if let last = current.last {
                let height = median(current.map(\.rect.height))
                let next = line.rect, previous = last.rect
                let movedUp = next.midY < previous.minY
                let gap = next.minY - previous.maxY
                let sideBySide = next.minX >= previous.maxX || next.maxX <= previous.minX
                let resized = abs(next.height - height) > 0.3 * height
                let indented = next.minX - area.minX > 0.8 * height && previous.maxX < area.maxX - 2 * height
                if movedUp || sideBySide || gap > 0.7 * height || resized || indented { flush() }
            }
            current.append(line)
            area = area.union(line.rect)
        }
        flush()
        return blocks
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Joins a block's lines into one string: a space between lines, or nothing where a
    /// line-end hyphen splits one word.
    static func join(_ lines: [RawLine], _ dehyphenator: Dehyphenator) -> String {
        var text = ""
        var softBreak = false
        for line in lines {
            defer { softBreak = line.softBreak }
            guard !text.isEmpty else {
                text = line.text
                continue
            }
            let left = text.dropLast()
            if let last = text.last, "-\u{2010}".contains(last), left.last?.isLetter == true {
                text = softBreak || dehyphenator.joins(left[...], line.text[...])
                    ? String(left) + line.text
                    : text + line.text
            } else {
                // A line that ends in a dash on its own, as in "from 3 to -", ends a word.
                text += " " + line.text
            }
        }
        return text
    }
}
