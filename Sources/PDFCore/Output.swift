import Foundation

/// Writes pages for the agent, with every doubt reported three times: in place, in the summary
/// line and in the exit code (DESIGNS.md → Principles → Failure). `pdf read` builds on it.
public enum Output {
    public struct Page: Sendable {
        /// Counted from 0.
        public var index: Int
        public var result: PageResult
        public var key: String

        public init(index: Int, result: PageResult, key: String) {
            self.index = index
            self.result = result
            self.key = key
        }
    }

    public struct Report: Equatable, Sendable {
        public var text: String
        /// 0 when every page read well, 2 when some pages are flagged, 3 when no page holds
        /// text that can be shown (FEATURES.md → F8).
        public var exitCode: Int32
    }

    /// - Parameters:
    ///   - file: the path as the agent typed it, for the commands the output suggests.
    ///   - raw: show the text that normal output sets aside as doubtful, labelled with its reason.
    public static func render(file: String, pageCount: Int, pages: [Page], picks: [String: [Pick]] = [:],
                              savedByPDFKit: Bool = false, raw: Bool = false) -> Report {
        let path = quoted(file)
        var body: [String] = []
        var flagged: [(page: Int, status: PageQuality.Status)] = []
        var doubtful = 0, oldLayers = 0
        var holdsText = false

        for page in pages {
            let (quality, picked) = judge(page, picks: picks)
            let layer = page.result.pageText
            let number = page.index + 1
            var lines = ["## p.\(number)"]
            let unsureByBlock = Dictionary(grouping: quality.unsure, by: \.block)
            if quality.status != .ok { flagged.append((number, quality.status)) }

            if let whole = quality.doubts.first(where: { $0.blocks == nil }) {
                lines.append(failureBlock(whole, page: number, address: "p.\(number)", region: nil, path: path, raw: raw))
                if whole.kind == .lowQuality, let layer {
                    if raw {
                        lines += layer.blocks.enumerated().map { index, block in
                            "\(address(number, index, block.box))\n[low-quality] \(block.text)"
                        }
                    } else {
                        doubtful += layer.blocks.count
                    }
                }
            } else if let layer {
                for (index, block) in layer.blocks.enumerated() {
                    if let doubt = quality.doubts.first(where: { $0.blocks?.contains(index) == true }) {
                        lines.append(failureBlock(doubt, page: number, address: "p.\(number) ¶\(index + 1)",
                                                  region: expanded(block.box, lines: block.lines), path: path, raw: raw))
                        if raw { lines.append("[low-quality] \(block.text)") } else { doubtful += 1 }
                        continue
                    }
                    holdsText = true
                    let spans = unsureByBlock[index] ?? []
                    let choices = spans.filter(\.pickable), looks = spans.filter { !$0.pickable }
                    let text = picked[index].map { applying($0, to: block.text, spans: choices) } ?? block.text
                    lines.append("\(address(number, index, block.box))\n\(text)")
                    if !choices.isEmpty && picked[index] == nil {
                        lines.append(unsureBlock(choices, block: block, page: number, index: index, path: path, raw: raw))
                    }
                    if !looks.isEmpty { lines.append(lookBlock(looks, block: block, page: number, index: index, path: path)) }
                }
            }
            if let old = layer?.replacedText {
                if raw { lines.append("[old OCR] \(old)") } else { oldLayers += 1 }
            }
            body.append(lines.joined(separator: "\n\n"))
        }

        var summary = ["\(file) · \(pageCount) page\(pageCount == 1 ? "" : "s") · read \(ranges(pages.map { $0.index + 1 }))"]
        summary.append(flagged.isEmpty ? "flagged: none"
                       : "flagged: " + flagged.map { "p.\($0.page) (\($0.status.rawValue))" }.joined(separator: ", "))
        var aside: [String] = []
        if doubtful > 0 { aside.append("\(doubtful) doubtful block\(doubtful == 1 ? "" : "s")") }
        if oldLayers > 0 { aside.append("\(oldLayers) old OCR layer\(oldLayers == 1 ? "" : "s")") }
        if raw {
            summary.append("showing the text set aside as doubtful")
        } else if !aside.isEmpty {
            summary.append("set aside: " + aside.joined(separator: ", ") + " (show: --raw)")
        }
        if savedByPDFKit {
            summary.append("⚠ made or last saved by macOS PDFKit, as Preview saves: such a save can damage the text, "
                           + "and an earlier copy may read better")
        }

        let exitCode: Int32 = flagged.isEmpty ? 0 : holdsText || pages.isEmpty ? 2 : 3
        return Report(text: ([summary.joined(separator: " · ")] + body).joined(separator: "\n\n") + "\n",
                      exitCode: exitCode)
    }

    /// A page's verdict with the agent's picks applied, and the picks that apply, by block.
    /// Picks resolve the unsure words of their blocks; words with no second reading stay in
    /// doubt.
    public static func judge(_ page: Page, picks: [String: [Pick]]) -> (quality: PageQuality, picked: [Int: Pick]) {
        var quality = Quality.judge(page.result)
        let unsureByBlock = Dictionary(grouping: quality.unsure, by: \.block)
        var picked: [Int: Pick] = [:]
        for pick in picks[page.key] ?? [] {
            let choices = unsureByBlock[pick.block]?.filter(\.pickable) ?? []
            if !choices.isEmpty, Picks.readings(of: choices) == pick.readings { picked[pick.block] = pick }
        }
        let resolved = unsureByBlock.allSatisfy { block, spans in spans.allSatisfy(\.pickable) && picked[block] != nil }
        if quality.status == .unsure && resolved { quality.status = .ok }
        return (quality, picked)
    }

    /// The flagged pages, as the summary line lists them: "p.2 (unsure), p.7 (low-quality)".
    public static func flagged(_ pages: [Page], picks: [String: [Pick]]) -> String? {
        let flags = pages.compactMap { page -> String? in
            let status = judge(page, picks: picks).quality.status
            return status == .ok ? nil : "p.\(page.index + 1) (\(status.rawValue))"
        }
        return flags.isEmpty ? nil : flags.joined(separator: ", ")
    }

    /// Why a file failed, with the command that opens a locked one.
    public static func failure(_ reason: String, file: String) -> String {
        reason.hasPrefix(OpenFailure.locked)
            ? "\(reason) · open it with: pdf add \(quoted(file)) --password <password>"
            : reason
    }

    // MARK: Blocks

    static func address(_ page: Int, _ index: Int, _ box: Box) -> String {
        "p.\(page) ¶\(index + 1) · \(format(box))"
    }

    /// The failure block: what is in doubt, why, and how to read it instead.
    static func failureBlock(_ doubt: Doubt, page: Int, address: String, region: Box?, path: String, raw: Bool) -> String {
        let score = doubt.score.map { String(format: " (score %.2f)", $0) } ?? ""
        var lines = ["⚠ \(address) \(doubt.kind.rawValue): \(doubt.reason)\(score)"]
        let crop = "pdf crop \(path) --page \(page)" + (region.map { " --bbox \(format($0))" } ?? "")
        lines.append("  read it as an image: \(crop)")
        if doubt.kind == .lowQuality && !raw { lines.append("  raw: pdf read \(path) --page \(page) --raw") }
        return lines.joined(separator: "\n")
    }

    /// The unsure block, after the paragraph that holds the words.
    static func unsureBlock(_ spans: [Unsure], block: TextBlock, page: Int, index: Int, path: String, raw: Bool) -> String {
        let readings = Picks.readings(of: spans)
        let label = raw ? "[unsure] " : ""
        let region = spans.dropFirst().reduce(spans[0].box) { union($0, $1.box) }
        return """
            ⚠ p.\(page) ¶\(index + 1) unsure: two readings differ
              \(label)[a] \(readings[0])
              \(label)[b] \(readings[1])
              pick: pdf pick \(path) p\(page).\(index + 1) a  (or b)
              look: pdf crop \(path) --page \(page) --bbox \(format(expanded(region, lines: block.lines)))
            """
    }

    /// Words that read as words run together, with no reading that splits them: the agent can
    /// only look at the image.
    static func lookBlock(_ spans: [Unsure], block: TextBlock, page: Int, index: Int, path: String) -> String {
        let region = spans.dropFirst().reduce(spans[0].box) { union($0, $1.box) }
        return """
            ⚠ p.\(page) ¶\(index + 1) unsure: words run together, and no reading splits them
              \(spans.map { $0.readings[0] }.joined(separator: " … "))
              look: pdf crop \(path) --page \(page) --bbox \(format(expanded(region, lines: block.lines)))
            """
    }

    /// The block's text with the picked reading in place of each unsure word, labelled.
    static func applying(_ pick: Pick, to text: String, spans: [Unsure]) -> String {
        let date = ISO8601DateFormatter.string(from: pick.pickedAt, timeZone: .current, formatOptions: [.withFullDate])
        var units = Array(text.utf16)
        for span in spans.sorted(by: { $0.offset > $1.offset }) {
            let old = Array(span.readings[0].utf16)
            guard span.offset + old.count <= units.count, Array(units[span.offset..<span.offset + old.count]) == old
            else { continue }
            let new = Array((span.readings[pick.chosen] + " [picked \(date)]").utf16)
            units.replaceSubrange(span.offset..<span.offset + old.count, with: new)
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Formatting

    static func format(_ box: Box) -> String {
        [box.x, box.y, box.width, box.height].map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    /// A region grown by a line above and below, so a crop shows the lines around the doubt.
    /// A line is the block's line spacing: PDFKit's line boxes take a font's full height and
    /// overlap their neighbours.
    static func expanded(_ box: Box, lines: [TextLine]) -> Box {
        let tops = lines.map(\.box.y).sorted()
        let steps = zip(tops.dropFirst(), tops).map { $0 - $1 }.filter { $0 > 0.002 }.sorted()
        let heights = lines.map(\.box.height).sorted()
        let line = steps.isEmpty ? (heights.isEmpty ? 0.015 : heights[heights.count / 2] * 0.6) : steps[steps.count / 2]
        let x = max(0, box.x - 0.01), y = max(0, box.y - line)
        return Box(x: x, y: y, width: min(1, box.x + box.width + 0.01) - x, height: min(1, box.y + box.height + line) - y)
    }

    static func union(_ a: Box, _ b: Box) -> Box {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return Box(x: x, y: y, width: max(a.x + a.width, b.x + b.width) - x, height: max(a.y + a.height, b.y + b.height) - y)
    }

    /// Page numbers as ranges, such as "p.1–3, p.7".
    static func ranges(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        while index < numbers.count {
            var end = index
            while end + 1 < numbers.count && numbers[end + 1] == numbers[end] + 1 { end += 1 }
            parts.append(end > index ? "p.\(numbers[index])–\(numbers[end])" : "p.\(numbers[index])")
            index = end + 1
        }
        return parts.isEmpty ? "no pages" : parts.joined(separator: ", ")
    }

    /// The path as a shell word, quoted when it needs to be. A path that starts with "-" gets
    /// "./" in front, so no command reads it as an option, and one that starts with "~" is
    /// quoted, so no shell reads it as a home folder.
    static func quoted(_ path: String) -> String {
        if path.hasPrefix("-") { return quoted("./" + path) }
        let plain = !path.hasPrefix("~")
            && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-~+:,@".contains($0)) }
        return plain && !path.isEmpty ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
