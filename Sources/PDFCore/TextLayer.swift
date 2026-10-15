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
    /// Runs of the text a reader cannot see (FEATURES.md → F9).
    public var hidden: [Hidden]? = nil

    /// The text a reader can see: the block's text without its hidden runs.
    public var visibleText: String {
        guard let hidden, !hidden.isEmpty else { return text }
        var units = Array(text.utf16)
        for run in hidden.sorted(by: { $0.offset > $1.offset }) where run.offset + run.length <= units.count {
            units.removeSubrange(run.offset..<run.offset + run.length)
        }
        return String(decoding: units, as: UTF16.self).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
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
    /// Text the page places off the page, as its strings spell it. PDFKit leaves it out of the
    /// page's text, so it has no block.
    public var offPage: [String]? = nil
    /// The check for hidden text stopped at a limit on this page, as forms nested deeper than it
    /// reads, so some hidden text may read as text.
    public var hiddenCheckIncomplete: Bool? = nil

    public var text: String { blocks.map(\.text).joined(separator: "\n\n") }
}

/// What PDFKit knows of each character on a page: its box, its font size, and how far its
/// baseline is raised.
struct Glyphs {
    /// Each character's box in page space, by UTF-16 offset, or nil for a space.
    let boxes: [CGRect?]
    let sizes: [CGFloat]
    let raises: [CGFloat]
    /// Each character's text color, when PDFKit gives it.
    let colors: [Color?]

    init(boxes: [CGRect?], sizes: [CGFloat], raises: [CGFloat], colors: [Color?] = []) {
        self.boxes = boxes
        self.sizes = sizes
        self.raises = raises
        self.colors = colors
    }

    init(_ page: PDFPage, _ text: NSString) {
        boxes = Glyphs.boxes(page, text)
        var sizes = [CGFloat](repeating: 0, count: text.length)
        var raises = [CGFloat](repeating: 0, count: text.length)
        var colors = [Color?](repeating: nil, count: text.length)
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
            attributed.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                guard let rgb = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
                let color = Color(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                for index in range.location..<NSMaxRange(range) { colors[index] = color }
            }
        }
        self.sizes = sizes
        self.raises = raises
        self.colors = colors
    }

    /// The boxes of a page's characters. PDFKit's `characterBounds(at:)` counts glyphs, not
    /// characters, so after a ligature such as "fl", one glyph for two characters, it returns
    /// the box of the next character: on an arXiv title, the last letter of a line got the box
    /// of the next line's first. A selection lands in the right place across the line, but spans
    /// the line's full height.
    ///
    /// So each line is checked first: when the glyph boxes for its first and last characters,
    /// at the offset carried from the lines before, sit inside the line's selection, the line
    /// takes its glyph boxes at that offset. A ligature on the line moves its last character's
    /// box off the line, and only then does each character take the glyph box that sits where
    /// its own selection does. One selection per line costs far less than one per character.
    static func boxes(_ page: PDFPage, _ text: NSString) -> [CGRect?] {
        var boxes = [CGRect?](repeating: nil, count: text.length)
        var shift = 0
        var misses = 0
        func glyph(_ index: Int) -> CGRect? {
            index >= 0 && index < text.length ? page.characterBounds(at: index) : nil
        }
        func inside(_ box: CGRect?, _ line: CGRect) -> Bool {
            guard let box, box.width > 0 || box.height > 0 else { return false }
            return line.insetBy(dx: -1, dy: -1).contains(CGPoint(x: box.midX, y: box.midY))
        }
        var start = 0
        while start < text.length {
            var end = start
            while end < text.length, !TextLayer.isLineBreak(text.character(at: end)) { end += 1 }
            defer { start = end + 1 }
            var characters: [(index: Int, width: Int)] = []
            var index = start
            while index < end {
                let unit = text.character(at: index)
                let paired = UTF16.isLeadSurrogate(unit) && index + 1 < end && UTF16.isTrailSurrogate(text.character(at: index + 1))
                if !TextLayer.isSpace(unit) { characters.append((index, paired ? 2 : 1)) }
                index += paired ? 2 : 1
            }
            guard let first = characters.first, let last = characters.last else { continue }
            if let line = page.selection(for: NSRange(location: first.index, length: last.index + last.width - first.index))?
                .bounds(for: page), !line.isEmpty,
               inside(glyph(first.index - shift), line), inside(glyph(last.index - shift), line) {
                for character in characters { boxes[character.index] = glyph(character.index - shift) }
                continue
            }
            for (index, width) in characters {
                guard let selected = page.selection(for: NSRange(location: index, length: width))?.bounds(for: page),
                      !selected.isEmpty else { continue }
                // The nearest glyphs first. The search widens at the first character the nearest
                // ones miss, and again every eighth miss in a row, so the walk picks its place up
                // after a jump without searching wide for every letter of a line it cannot match,
                // such as arXiv's sideways margin stamp.
                let reach = misses % 8 == 0 ? 400 : 2
                var found: CGRect?
                search: for distance in 0...reach {
                    for candidate in distance == 0 ? [index - shift] : [index - shift - distance, index - shift + distance] {
                        guard let box = glyph(candidate) else { continue }
                        if abs(box.midX - selected.midX) <= max(1, selected.width / 2)
                            && abs(box.midY - selected.midY) <= selected.height {
                            found = box
                            shift = index - candidate
                            break search
                        }
                    }
                }
                misses = found == nil ? misses + 1 : 0
                boxes[index] = found ?? selected
            }
        }
        return boxes
    }

    /// The marks for a line's characters: "^" for one set smaller and raised against the line's
    /// main text, "_" for one set smaller and lowered. A run of the main size that PDFKit
    /// reports a little raised, as in a table cell, keeps no mark.
    ///
    /// `words` groups the line's characters into words. A mark sits on part of a word, as in
    /// `10^{-5}` or `LLM_{tea}`: a whole word set smaller and lower, as an old OCR layer sets
    /// some words of a scan, or an axis label beside a chart, keeps none.
    func marks(_ indices: [Int], words: [[Int]] = []) -> [Int: Character] {
        var counts: [CGFloat: Int] = [:]
        for index in indices where sizes[index] > 0 { counts[(sizes[index] * 2).rounded() / 2, default: 0] += 1 }
        guard let main = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key else { return [:] }
        let base = indices.filter { abs(sizes[$0] - main) <= 0.05 * main }.map { raises[$0] }.sorted()
        let baseline = base.isEmpty ? 0 : base[base.count / 2]
        var marks: [Int: Character] = [:]
        for index in indices where sizes[index] > 0 && sizes[index] <= 0.85 * main {
            let lift = raises[index] - baseline
            if lift >= 0.1 * main { marks[index] = "^" } else if lift <= -0.08 * main { marks[index] = "_" }
        }
        for word in words where word.allSatisfy({ marks[$0] != nil }) {
            for index in word { marks[index] = nil }
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

    /// - Parameters:
    ///   - spacesBefore: UTF-16 offsets in `page.string` where a space belongs, from the space
    ///     repair. Empty when the page needs none.
    ///   - glyphs: the page's characters, when a caller reads the page more than once: they
    ///     cost about 20 ms a page.
    ///   - visibility: what a reader can see of the page, which marks the text a reader cannot
    ///     see (FEATURES.md → F9). Nil reads every character as seen.
    static func read(_ page: PDFPage, spacesBefore: Set<Int> = [], glyphs known: Glyphs? = nil,
                     visibility: Visibility? = nil) -> PageText {
        let raw = page.string ?? ""
        let text = raw as NSString
        let crop = page.bounds(for: .cropBox)
        let glyphs = known ?? Glyphs(page, text)
        var lines: [RawLine] = []

        var start = 0
        while start <= text.length {
            var end = start
            while end < text.length, !isLineBreak(text.character(at: end)) { end += 1 }
            if let line = makeLine(text, start..<end, glyphs: glyphs, crop: crop, spacesBefore: spacesBefore,
                                   visibility: visibility) {
                lines.append(line)
            }
            start = end + 1
        }

        let blocks = group(lines, crop: crop, dehyphenator: Dehyphenator(pageText: raw))
        let joined = blocks.map(\.text).joined(separator: "\n")
        var layer = PageText(blocks: blocks, words: TextCleanup.wordCount(joined),
                             runTogether: TextCleanup.runTogetherWords(joined))
        if let offPage = visibility?.drawing.offPage.filter({ !$0.isEmpty }), !offPage.isEmpty { layer.offPage = offPage }
        if visibility?.drawing.incomplete == true { layer.hiddenCheckIncomplete = true }
        return layer
    }

    // MARK: Hidden runs

    /// Marks around a run a reader cannot see, while the lines are built: an opening mark per
    /// reason, and one closing mark. They are Unicode noncharacters, kept for a program's own
    /// use and never part of a document's text, and come out of the text again as `Hidden` spans
    /// once the block is joined.
    static func opening(_ reason: HiddenReason) -> Character { Character(Unicode.Scalar(0xFDD0 + UInt32(reason.rawValue))!) }
    static let closing = Character(Unicode.Scalar(UInt32(0xFDEF))!)

    static func isMark(_ scalar: Unicode.Scalar) -> Bool { (0xFDD0...0xFDEF).contains(scalar.value) }

    /// A block's text without the marks, and its hidden runs. Runs of one reason that only spaces
    /// part become one, and a run without 3 letters or digits in a row counts as seen: a maths
    /// symbol whose box PDFKit places off its ink, or the stray marks of a scan's old OCR layer,
    /// as "I I I", carry no instruction.
    static func hiddenRuns(_ marked: String) -> (text: String, hidden: [Hidden]) {
        guard marked.unicodeScalars.contains(where: isMark) else { return (marked, []) }
        var text = String.UnicodeScalarView()
        var length = 0
        var runs: [Hidden] = []
        var open: (reason: HiddenReason, start: Int)?
        for scalar in marked.unicodeScalars {
            if scalar == closing.unicodeScalars.first! {
                if let current = open { runs.append(Hidden(offset: current.start, length: length - current.start, reason: current.reason)) }
                open = nil
            } else if isMark(scalar), let reason = HiddenReason(rawValue: Int(scalar.value - 0xFDD0)) {
                open = (reason, length)
            } else {
                text.append(scalar)
                length += scalar.utf16.count
            }
        }
        if let current = open { runs.append(Hidden(offset: current.start, length: length - current.start, reason: current.reason)) }
        let plain = String(text)
        let units = Array(plain.utf16)
        var merged: [Hidden] = []
        for run in runs where run.length > 0 {
            if let last = merged.last, last.reason == run.reason,
               units[(last.offset + last.length)..<run.offset].allSatisfy({ $0 == 0x20 }) {
                merged[merged.count - 1].length = run.offset + run.length - last.offset
            } else {
                merged.append(run)
            }
        }
        let kept = merged.filter { run in
            String(decoding: units[run.offset..<run.offset + run.length], as: UTF16.self)
                .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains { $0.count >= 3 }
        }
        return (plain, kept)
    }

    static func withoutMarks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isMark($0) }))
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
                         spacesBefore: Set<Int>, visibility: Visibility? = nil) -> RawLine? {
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
        // Words as the line will show them: a space in the text or one the repair puts back
        // ends a word.
        var words: [[Int]] = [[]]
        for character in characters {
            if character.isSpace || spacesBefore.contains(character.index) { words.append([]) }
            if !character.isSpace { words[words.count - 1].append(character.index) }
        }
        let marks = glyphs.marks(characters.filter { !$0.isSpace }.map(\.index), words: words.filter { !$0.isEmpty })
        // Each word a reader cannot see, by its first and last character, with the reason.
        var hiddenStart: [Int: HiddenReason] = [:]
        var hiddenEnd = Set<Int>()
        if let visibility {
            let widths = Dictionary(characters.map { ($0.index, $0.width) }, uniquingKeysWith: { first, _ in first })
            // The line's usual glyph height, against which a word set at an angle stands out.
            let glyphHeight = median(characters.compactMap { glyphs.boxes[$0.index]?.height }.filter { $0 > 0 })
            var previous: HiddenReason?
            for word in words where !word.isEmpty {
                defer { previous = hiddenStart[word[0]] }
                let end = word[word.count - 1] + (widths[word[word.count - 1]] ?? 1)
                guard let rect = visibility.box(of: NSRange(location: word[0], length: end - word[0])) else { continue }
                let size = word.map { glyphs.sizes[$0] }.max() ?? 0
                let colors = word.map { glyphs.colors.indices.contains($0) ? glyphs.colors[$0] : nil }
                let spelled = word.map { text.substring(with: NSRange(location: $0, length: widths[$0] ?? 1)) }.joined()
                // Letters that run neither straight across nor straight down, as a chart's label
                // set at an angle: PDFKit's boxes for them hold other words' ink. Such a word's
                // box is several glyphs tall and wide.
                let straight = glyphHeight == 0 || min(rect.width, rect.height) <= 2.5 * glyphHeight
                // Letters squeezed into slivers by horizontal scaling, or stacked on one spot by
                // negative spacing, as each character's own box shows against the font size.
                let boxes = word.compactMap { glyphs.boxes[$0] }.filter { $0.width > 0 && $0.height > 0 }
                var squeezed = false
                if size >= 2, boxes.count >= 3 {
                    let span = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
                    let laidEnd = boxes.reduce(0) { $0 + max($1.width, $1.height) }
                    squeezed = median(boxes.map { min($0.width, $0.height) }) < 0.1 * size
                        || (boxes.count >= 4 && max(span.width, span.height) < 0.3 * laidEnd)
                }
                if let reason = visibility.reason(rect, text: spelled, size: size, color: colors.compactMap { $0 }.first,
                                                  straight: straight, squeezed: squeezed) {
                    hiddenStart[word[0]] = reason
                    hiddenEnd.insert(word[word.count - 1])
                } else if previous == .covered, spelled.filter({ $0.isLetter || $0.isNumber }).count < 3,
                          visibility.underCovering(rect) {
                    // OCR cannot vouch for a word of one or two letters, so under the same image
                    // it goes with the covered word before it.
                    hiddenStart[word[0]] = .covered
                    hiddenEnd.insert(word[word.count - 1])
                } else if Set(colors.compactMap { $0.map { "\($0.red) \($0.green) \($0.blue)" } }).count > 1,
                          let background = visibility.background(of: rect) {
                    // A word whose letters are drawn some in ink and some in the color behind
                    // them reads as its inked letters alone: the others are hidden, letter by letter.
                    // A word of one color is judged whole, above.
                    let unseen = colors.map { $0.map { $0.distance(background) < 0.2 } ?? false }
                    if unseen.contains(true) && unseen.contains(false) {
                        for (position, index) in word.enumerated() where unseen[position] {
                            if position == 0 || !unseen[position - 1] { hiddenStart[index] = .background }
                            if position == word.count - 1 || !unseen[position + 1] { hiddenEnd.insert(index) }
                        }
                    }
                }
            }
        }
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
            if let reason = hiddenStart[character.index] {
                if open != nil { piece += "}" }
                open = nil
                piece.append(opening(reason))
            }
            if mark != open {
                if open != nil { piece += "}" }
                if let mark { piece += "\(mark){" }
                open = mark
            }
            piece += withoutMarks(text.substring(with: NSRange(location: character.index, length: character.width)))
            if hiddenEnd.contains(character.index) {
                if open != nil { piece += "}" }
                open = nil
                piece.append(closing)
            }
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
            let (text, hidden) = hiddenRuns(join(current, dehyphenator))
            var block = TextBlock(text: text, box: box(area),
                                  lines: current.map { TextLine(text: withoutMarks($0.text), box: box($0.rect)) })
            if !hidden.isEmpty { block.hidden = hidden }
            blocks.append(block)
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
