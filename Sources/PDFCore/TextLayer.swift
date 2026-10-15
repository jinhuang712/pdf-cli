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
}

/// A page's text layer, as the parse stores it.
public struct PageText: Codable, Equatable, Sendable {
    public var blocks: [TextBlock]
    public var words: Int
    /// Letter runs longer than 25 characters, a sign of lost spaces.
    public var runTogether: Int

    public var text: String { blocks.map(\.text).joined(separator: "\n\n") }
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
        var lines: [RawLine] = []

        var start = 0
        while start <= text.length {
            var end = start
            while end < text.length, !isLineBreak(text.character(at: end)) { end += 1 }
            if let line = makeLine(page, text, start..<end, crop: crop, spacesBefore: spacesBefore) {
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

    /// One line of the page string, with its rectangle from the bounds of its characters.
    static func makeLine(_ page: PDFPage, _ text: NSString, _ range: Range<Int>, crop: CGRect,
                         spacesBefore: Set<Int>) -> RawLine? {
        var piece = ""
        var bounds = CGRect.null
        var index = range.lowerBound
        while index < range.upperBound {
            let unit = text.character(at: index)
            let paired = UTF16.isLeadSurrogate(unit) && index + 1 < range.upperBound
                && UTF16.isTrailSurrogate(text.character(at: index + 1))
            let width = paired ? 2 : 1
            if spacesBefore.contains(index) { piece += " " }
            piece += text.substring(with: NSRange(location: index, length: width))
            if !isSpace(unit) {
                let rect = page.characterBounds(at: index)
                if rect.width > 0 || rect.height > 0 { bounds = bounds.union(rect) }
            }
            index += width
        }
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
