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

    public enum Style: String, Sendable {
        case md, text
    }

    /// One piece of output: a page's heading, a block of its text, or a block that reports a
    /// doubt. Every piece carries its page and its position (DESIGNS.md → Principles → Output).
    public struct Block: Encodable, Equatable, Sendable {
        public enum Kind: String, Encodable, Sendable {
            case page, text, failure, unsure, look
            /// The text of a block in doubt, shown with `--raw`.
            case doubtful = "low-quality-text"
            /// The text layer that OCR replaced, shown with `--raw`.
            case oldOCR = "old-ocr"
            /// Text a reader cannot see that has no block of its own, as text off the page: a
            /// marker, or its words with `--include-hidden`.
            case hidden
        }

        public var kind: Kind
        /// Counted from 1.
        public var page: Int
        /// Counted from 1. Nil for what belongs to the whole page.
        public var block: Int?
        /// x, y, width and height, as fractions of the page from its top-left corner.
        public var bbox: [Double]
        public var text: String?
        /// The number printed on the page, for a page heading, when it differs from the page's
        /// position in the file.
        public var printed: String?
        public var status: String?
        public var reason: String?
        public var score: Double?
        public var readings: [String]?
        /// Ready-to-run commands: "crop", "raw", "pick" or "look".
        public var commands: [String: String]?

        init(kind: Kind, page: Int, block: Int? = nil, box: Box = Box(x: 0, y: 0, width: 1, height: 1), text: String? = nil,
             printed: String? = nil, status: String? = nil, reason: String? = nil, score: Double? = nil,
             readings: [String]? = nil, commands: [String: String]? = nil) {
            self.kind = kind
            self.page = page
            self.block = block
            self.bbox = [box.x, box.y, box.width, box.height].map { ($0 * 10_000).rounded() / 10_000 }
            self.text = text
            self.printed = printed
            self.status = status
            self.reason = reason
            self.score = score.map { ($0 * 100).rounded() / 100 }
            self.readings = readings
            self.commands = commands
        }

        var box: Box { Box(x: bbox[0], y: bbox[1], width: bbox[2], height: bbox[3]) }
    }

    /// Blocks that go out together: a text block with the doubts that follow it, or a block that
    /// reports a doubt with the text it set aside. A budget cuts the output between units.
    struct Unit {
        var blocks: [Block]
        /// What the unit flags its page as, if anything.
        var flag: PageQuality.Status? = nil
        /// How many blocks of text the unit sets aside as doubtful.
        var doubtful = 0
        /// The unit shows text the agent can read.
        var holdsText = false
        /// How many runs of text a reader cannot see the unit marks.
        var hidden = 0
    }

    /// What one page contributes to the output.
    struct PageBlocks {
        /// The page heading, then the page's units.
        var units: [Unit]
        /// The page carries a text layer that OCR replaced, which only `--raw` shows.
        var oldLayers = 0
    }

    /// The blocks of one page, with the agent's picks applied.
    /// - Parameters:
    ///   - path: the path as a shell word, for the commands the blocks suggest.
    ///   - raw: show the text that normal output sets aside as doubtful, labelled with its reason.
    static func pageBlocks(_ page: Page, picks: [String: [Pick]], path: String, raw: Bool,
                           includeHidden: Bool = false) -> PageBlocks {
        let (quality, picked) = judge(page, picks: picks)
        let layer = page.result.pageText
        let number = page.index + 1
        var result = PageBlocks(units: [Unit(blocks: [Block(kind: .page, page: number, printed: layer?.label)])])
        let unsureByBlock = Dictionary(grouping: quality.unsure, by: \.block)
        func status(_ doubt: Doubt) -> PageQuality.Status { doubt.kind == .failed ? .failed : .lowQuality }

        if let whole = quality.doubts.first(where: { $0.blocks == nil }) {
            var unit = Unit(blocks: [failureBlock(whole, page: number, block: nil, region: nil, path: path, raw: raw)],
                            flag: status(whole))
            if whole.kind == .lowQuality, let layer {
                if raw {
                    unit.blocks += layer.blocks.enumerated().map { index, block in
                        Block(kind: .doubtful, page: number, block: index + 1, box: block.box,
                              text: shown(block.text, pick: nil, choices: [], hidden: block.hidden ?? [], includeHidden: includeHidden,
                                          path: path, page: number),
                              status: whole.kind.rawValue)
                    }
                } else {
                    unit.doubtful = layer.blocks.count
                }
            }
            result.units.append(unit)
        } else if let layer {
            for (index, block) in layer.blocks.enumerated() {
                if let doubt = quality.doubts.first(where: { $0.blocks?.contains(index) == true }) {
                    var unit = Unit(blocks: [failureBlock(doubt, page: number, block: index + 1,
                                                          region: expanded(block.box, lines: block.lines), path: path, raw: raw)],
                                    flag: status(doubt))
                    if raw {
                        unit.blocks.append(Block(kind: .doubtful, page: number, block: index + 1, box: block.box,
                                                 text: shown(block.text, pick: nil, choices: [], hidden: block.hidden ?? [],
                                                             includeHidden: includeHidden, path: path, page: number),
                                                 status: doubt.kind.rawValue))
                    } else {
                        unit.doubtful = 1
                    }
                    result.units.append(unit)
                    continue
                }
                // Unsure words inside text a reader cannot see stay hidden with it.
                let runs = block.hidden ?? []
                let spans = (unsureByBlock[index] ?? []).filter { span in
                    !runs.contains { $0.offset < span.offset + span.readings[0].utf16.count && span.offset < $0.offset + $0.length }
                }
                let choices = spans.filter(\.pickable), looks = spans.filter { !$0.pickable }
                let text = shown(block.text, pick: picked[index], choices: choices, hidden: runs, includeHidden: includeHidden,
                                 path: path, page: number)
                var unit = Unit(blocks: [Block(kind: .text, page: number, block: index + 1, box: block.box, text: text)],
                                holdsText: !block.visibleText.isEmpty)
                unit.hidden = runs.count
                if !choices.isEmpty && picked[index] == nil {
                    unit.blocks.append(unsureBlock(choices, block: block, page: number, index: index, path: path))
                    unit.flag = .unsure
                }
                if !looks.isEmpty {
                    unit.blocks.append(lookBlock(looks, block: block, page: number, index: index, path: path))
                    unit.flag = .unsure
                }
                result.units.append(unit)
            }
            // Text placed off the page has no block: PDFKit leaves it out of the page's text,
            // and only the drawing commands spell it.
            if let offPage = layer.offPage, !offPage.isEmpty {
                let words = offPage.joined(separator: " ")
                var unit = Unit(blocks: [Block(kind: .hidden, page: number,
                                               text: marker(words, reason: .offPage, includeHidden: includeHidden, path: path, page: number))])
                unit.hidden = 1
                result.units.append(unit)
            }
            if layer.hiddenCheckIncomplete == true {
                var unit = Unit(blocks: [Block(kind: .hidden, page: number, text: """
                    [hidden-text check incomplete: the page draws more than the check reads, so some hidden text may read as \
                    text · look: pdf crop \(path) --page \(number)]
                    """)])
                unit.hidden = 1
                result.units.append(unit)
            }
        }
        if let old = layer?.replacedText {
            if raw {
                // Numbered after the page's last block, so a read that goes on from it skips them.
                result.units.append(Unit(blocks: [Block(kind: .oldOCR, page: number, block: (layer?.blocks.count ?? 0) + 1, text: old)]))
            } else {
                result.oldLayers = 1
            }
        }
        return result
    }

    /// The output of a read, built page by page within a token budget.
    public struct Document {
        let file: String
        let path: String
        let pageCount: Int
        let style: Style
        let raw: Bool
        /// Show the words of text a reader cannot see, labelled, in place of their markers.
        let includeHidden: Bool
        let picks: [String: [Pick]]
        /// About how many tokens the output may take. Nil means no limit.
        let budget: Int?
        /// The command that continues the read from a page, a block and an offset in its text.
        let continuation: @Sendable (Int, Int?, Int?) -> String

        public private(set) var blocks: [Block] = []
        var rendered: [String] = []
        var used = 0
        var pagesRead: [Int] = []
        var flagged: [(page: Int, status: PageQuality.Status)] = []
        var doubtful = 0, oldLayers = 0
        var holdsText = false
        /// Runs of text a reader cannot see, by page, among the units that went out.
        var hidden: [(page: Int, count: Int)] = []
        /// The command that continues the read, once the budget stopped it.
        public private(set) var next: String?
        /// Why the read stopped before the budget did, if it did.
        var stopped: String?
        /// Where a read of one section ends: the page and block of the next section, counted
        /// from 1. The blocks from there on stay out.
        public var until: (page: Int, block: Int)?

        /// - Parameter continuation: the full command that goes on from a page, a block and a
        ///   character in the block's text, such as `pdf read paper.pdf --page 4-9 --from p4.7`.
        public init(file: String, pageCount: Int, style: Style = .md, raw: Bool = false, includeHidden: Bool = false,
                    picks: [String: [Pick]] = [:], budget: Int? = nil,
                    continuation: (@Sendable (Int, Int?, Int?) -> String)? = nil) {
            let path = quoted(file)
            self.file = file
            self.path = path
            self.pageCount = pageCount
            self.style = style
            self.raw = raw
            self.includeHidden = includeHidden
            self.picks = picks
            self.budget = budget
            self.continuation = continuation ?? { page, block, offset in
                "pdf read \(path) --from " + Output.address(page: page, block: block, offset: offset)
            }
        }

        /// Adds a page, from `block` and `offset` within it when a read goes on from there.
        /// Returns false when the budget stopped the read, which leaves `next` set.
        ///
        /// Every read moves on: the first unit after a page's heading goes out even when it
        /// alone is larger than the budget, cut inside after a word when it starts with text.
        /// Counts and flags come only from the units that go out.
        public mutating func add(_ page: Page, from block: Int? = nil, offset: Int? = nil) -> Bool {
            let content = pageBlocks(page, picks: picks, path: path, raw: raw, includeHidden: includeHidden)
            let number = page.index + 1
            for (position, var unit) in content.units.enumerated() {
                let first = unit.blocks[0]
                if position > 0, let block, (first.block ?? Int.max) < block { continue }
                if position > 0, let until, until.page == number, (first.block ?? Int.max) >= until.block { break }
                let resumed = position > 0 && offset != nil && first.block == block && first.kind == .text
                if resumed, let offset, let text = first.text { unit.blocks[0].text = "…" + String(text.dropFirst(offset)) }
                let cost = unit.blocks.reduce(0) { $0 + tokens(render($1, style: style, raw: raw)) }
                if let budget, used + cost > budget, !(position == 0 && rendered.isEmpty) {
                    // Only this page's heading is out in this read, so this unit goes out anyway.
                    guard position > 0 && rendered.count == 1 else {
                        next = continuation(number, position == 0 ? nil : first.block, nil)
                        return false
                    }
                    if first.kind == .text, let text = unit.blocks[0].text {
                        let frame = tokens(render(Block(kind: .text, page: number, block: first.block, box: first.box, text: ""),
                                                  style: style, raw: raw))
                        let kept = prefix(text, tokens: max(budget - used - frame, 20))
                        let shownHere = kept.count - (resumed ? 1 : 0)
                        if kept.count < text.count && shownHere > 0 {
                            var cut = Unit(blocks: [unit.blocks[0]], holdsText: true)
                            cut.hidden = unit.hidden
                            cut.blocks[0].text = kept + "…"
                            emit(cut, page: number)
                            next = continuation(number, first.block, (resumed ? offset ?? 0 : 0) + shownHere)
                            return false
                        }
                    }
                }
                emit(unit, page: number)
            }
            // The page is done: it counts as read even if it holds no block, and its old OCR
            // layer, which only `--raw` shows, counts as set aside.
            if pagesRead.last != number { pagesRead.append(number) }
            oldLayers += content.oldLayers
            return true
        }

        mutating func emit(_ unit: Unit, page: Int) {
            for block in unit.blocks {
                blocks.append(block)
                let text = render(block, style: style, raw: raw)
                rendered.append(text)
                used += tokens(text)
            }
            guard unit.blocks.first?.kind != .page else { return }
            if pagesRead.last != page { pagesRead.append(page) }
            if let flag = unit.flag {
                if let last = flagged.last, last.page == page {
                    flagged[flagged.count - 1].status = max(last.status, flag)
                } else {
                    flagged.append((page, flag))
                }
            }
            doubtful += unit.doubtful
            holdsText = holdsText || unit.holdsText
            if unit.hidden > 0 {
                if let last = hidden.last, last.page == page {
                    hidden[hidden.count - 1].count += unit.hidden
                } else {
                    hidden.append((page, unit.hidden))
                }
            }
        }

        /// Ends the read early, for a reason the summary gives, with the command that goes on.
        public mutating func stop(at page: Int, because reason: String) {
            stopped = reason
            next = continuation(page, nil, nil)
        }

        /// The summary line, then the blocks, then the line that continues the read.
        /// `parsed` is how many of the document's pages are cached: fewer than all makes the
        /// output provisional.
        public func report(savedByPDFKit: Bool = false, parsed: Int? = nil) -> Report {
            var summary = ["\(file) · \(pageCount) page\(pageCount == 1 ? "" : "s") · read \(ranges(pagesRead))"]
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
            if !hidden.isEmpty {
                let total = hidden.reduce(0) { $0 + $1.count }
                summary.append((includeHidden ? "showing hidden text: " : "hidden text: ") + "\(total) place\(total == 1 ? "" : "s") on "
                               + hidden.map { "p.\($0.page)" }.joined(separator: ", ") + (includeHidden ? "" : " (show: --include-hidden)"))
            }
            if let parsed, parsed < pageCount {
                summary.append("provisional: \(parsed) of \(pageCount) pages parsed so far")
            }
            if savedByPDFKit {
                summary.append("⚠ made or last saved by macOS PDFKit, as Preview saves: such a save can damage the text, "
                               + "and an earlier copy may read better")
            }
            var parts = [summary.joined(separator: " · ")] + rendered
            if let stopped { parts.append("⚠ stopped: \(stopped)") }
            if let next { parts.append("next: \(next)") }
            let exitCode: Int32 = flagged.isEmpty ? 0 : holdsText || pagesRead.isEmpty ? 2 : 3
            return Report(text: parts.joined(separator: "\n\n") + "\n", exitCode: exitCode)
        }

        /// The read as JSON: the summary's facts, every block, and the command that continues.
        public func json(savedByPDFKit: Bool = false, parsed: Int? = nil) throws -> Data {
            struct Flag: Encodable { var page: Int; var status: String }
            struct Aside: Encodable { var doubtfulBlocks: Int; var oldOCRLayers: Int }
            struct HiddenText: Encodable { var page: Int; var places: Int }
            struct Body: Encodable {
                var file: String
                var pageCount: Int
                var pagesRead: [Int]
                var flagged: [Flag]
                var setAside: Aside
                var hidden: [HiddenText]
                var provisional: Bool
                var savedByPDFKit: Bool
                var blocks: [Block]
                var stopped: String?
                var next: String?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            return try encoder.encode(Body(
                file: file, pageCount: pageCount, pagesRead: pagesRead,
                flagged: flagged.map { Flag(page: $0.page, status: $0.status.rawValue) },
                setAside: Aside(doubtfulBlocks: doubtful, oldOCRLayers: oldLayers),
                hidden: hidden.map { HiddenText(page: $0.page, places: $0.count) },
                provisional: parsed.map { $0 < pageCount } ?? false, savedByPDFKit: savedByPDFKit, blocks: blocks,
                stopped: stopped, next: next.map { $0 + " --json" }))
        }
    }

    /// Every page in full, with no budget: the hidden `pdf debug-read` and the tests use it.
    public static func render(file: String, pageCount: Int, pages: [Page], picks: [String: [Pick]] = [:],
                              savedByPDFKit: Bool = false, raw: Bool = false) -> Report {
        var document = Document(file: file, pageCount: pageCount, raw: raw, picks: picks)
        for page in pages { _ = document.add(page) }
        return document.report(savedByPDFKit: savedByPDFKit)
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

    /// A block's text as it goes out: picked readings in place of unsure words, and a marker in
    /// place of each run a reader cannot see, or the run's words, labelled, with
    /// `includeHidden` (DESIGNS.md → Decision: a marker in place of hidden text over its words
    /// with a label).
    static func shown(_ text: String, pick: Pick?, choices: [Unsure], hidden: [Hidden], includeHidden: Bool,
                      path: String, page: Int) -> String {
        var units = Array(text.utf16)
        var replacements: [(offset: Int, length: Int, text: String)] = hidden.map { run in
            let words = String(decoding: units[run.offset..<min(run.offset + run.length, units.count)], as: UTF16.self)
            return (run.offset, run.length, marker(words, reason: run.reason, includeHidden: includeHidden, path: path, page: page))
        }
        if let pick {
            let date = ISO8601DateFormatter.string(from: pick.pickedAt, timeZone: .current, formatOptions: [.withFullDate])
            for span in choices {
                let old = Array(span.readings[0].utf16)
                guard span.offset + old.count <= units.count, Array(units[span.offset..<span.offset + old.count]) == old else { continue }
                replacements.append((span.offset, old.count, span.readings[pick.chosen] + " [picked \(date)]"))
            }
        }
        for replacement in replacements.sorted(by: { $0.offset > $1.offset })
        where replacement.offset + replacement.length <= units.count {
            units.replaceSubrange(replacement.offset..<replacement.offset + replacement.length, with: Array(replacement.text.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// What stands where a reader sees nothing: the run's size, why it is hidden and the command
    /// that shows it, or, with `includeHidden`, its words, labelled.
    static func marker(_ words: String, reason: HiddenReason, includeHidden: Bool, path: String, page: Int) -> String {
        if includeHidden { return "[hidden, \(reason.words): \(words)]" }
        let count = words.split(whereSeparator: \.isWhitespace).count
        return "[hidden: \(count) word\(count == 1 ? "" : "s"), \(reason.words) · show: pdf read \(path) --page \(page) --include-hidden]"
    }

    /// The failure block: what is in doubt, why, and how to read it instead.
    static func failureBlock(_ doubt: Doubt, page: Int, block: Int?, region: Box?, path: String, raw: Bool) -> Block {
        var commands = ["crop": "pdf crop \(path) --page \(page)" + (region.map { " --bbox \(format($0))" } ?? "")]
        if doubt.kind == .lowQuality && !raw { commands["raw"] = "pdf read \(path) --page \(page) --raw" }
        return Block(kind: .failure, page: page, block: block, box: region ?? Box(x: 0, y: 0, width: 1, height: 1),
                     status: doubt.kind.rawValue, reason: doubt.reason, score: doubt.score, commands: commands)
    }

    /// The unsure block, after the paragraph that holds the words.
    static func unsureBlock(_ spans: [Unsure], block: TextBlock, page: Int, index: Int, path: String) -> Block {
        let region = expanded(spans.dropFirst().reduce(spans[0].box) { union($0, $1.box) }, lines: block.lines)
        return Block(kind: .unsure, page: page, block: index + 1, box: region, reason: "two readings differ",
                     readings: Picks.readings(of: spans),
                     commands: ["pick": "pdf pick \(path) p\(page).\(index + 1) a", "look": "pdf crop \(path) --page \(page) --bbox \(format(region))"])
    }

    /// Words that read as words run together, with no reading that splits them: the agent can
    /// only look at the image.
    static func lookBlock(_ spans: [Unsure], block: TextBlock, page: Int, index: Int, path: String) -> Block {
        let region = expanded(spans.dropFirst().reduce(spans[0].box) { union($0, $1.box) }, lines: block.lines)
        return Block(kind: .look, page: page, block: index + 1, box: region,
                     text: spans.map { $0.readings[0] }.joined(separator: " … "),
                     reason: "words run together, and no reading splits them",
                     commands: ["look": "pdf crop \(path) --page \(page) --bbox \(format(region))"])
    }

    /// A block as text. Each block's address is written by `address`, in one place, so the
    /// format can change without touching the rest.
    static func render(_ block: Block, style: Style, raw: Bool) -> String {
        let commands = block.commands ?? [:]
        switch block.kind {
        case .page:
            let heading = "p.\(block.page)" + (block.printed.map { " (printed \($0))" } ?? "")
            return style == .md ? "## \(heading)" : "=== \(heading) ==="
        case .text:
            return "\(address(block)) \(block.text ?? "")"
        case .doubtful:
            return "\(address(block)) [\(block.status ?? "low-quality")] \(block.text ?? "")"
        case .oldOCR:
            return "[old OCR] \(block.text ?? "")"
        case .hidden:
            return block.text ?? ""
        case .failure:
            let place = "p.\(block.page)" + (block.block.map { " ¶\($0)" } ?? "")
            let score = block.score.map { String(format: " (score %.2f)", $0) } ?? ""
            var lines = ["⚠ \(place) \(block.status ?? "failed"): \(block.reason ?? "")\(score)"]
            if let crop = commands["crop"] { lines.append("  read it as an image: \(crop)") }
            if let raw = commands["raw"] { lines.append("  raw: \(raw)") }
            return lines.joined(separator: "\n")
        case .unsure:
            let label = raw ? "[unsure] " : ""
            let readings = block.readings ?? ["", ""]
            return """
                ⚠ p.\(block.page) ¶\(block.block ?? 0) unsure: two readings differ
                  \(label)[a] \(readings[0])
                  \(label)[b] \(readings.count > 1 ? readings[1] : "")
                  pick: \(commands["pick"] ?? "")  (or b)
                  look: \(commands["look"] ?? "")
                """
        case .look:
            return """
                ⚠ p.\(block.page) ¶\(block.block ?? 0) unsure: \(block.reason ?? "")
                  \(block.text ?? "")
                  look: \(commands["look"] ?? "")
                """
        }
    }

    /// The address a text block starts with: its number on the page, under the page's heading.
    /// Its position stays in `--json`: the full position took about 22% of a read's tokens on
    /// the arXiv samples, and the number alone about 7% (DESIGNS.md → Decision: paragraph
    /// numbers in text, positions in JSON).
    static func address(_ block: Block) -> String {
        "¶\(block.block ?? 0)"
    }

    /// Where a read goes on from, as `--from` takes it: "p4", "p4.7", or "p4.7:120" for the
    /// 120th character of block 7.
    public static func address(page: Int, block: Int?, offset: Int?) -> String {
        "p\(page)" + (block.map { ".\($0)" } ?? "") + (offset.map { ":\($0)" } ?? "")
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

    // MARK: Budget

    /// About how many tokens a text costs: one per four characters of Latin text, and one per
    /// character of other scripts, which tokenizers split finer.
    public static func tokens(_ text: String) -> Int {
        var ascii = 0, other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return (ascii + 3) / 4 + other
    }

    /// The start of a text that fits in about `tokens` tokens, cut after a word.
    static func prefix(_ text: String, tokens limit: Int) -> String {
        var cost = 0, cut = text.startIndex, index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            cost += character.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 4) }
            if cost > limit * 4 { break }
            index = text.index(after: index)
            if character == " " { cut = index }
        }
        return index == text.endIndex ? text : String(text[..<(cut == text.startIndex ? index : cut)])
    }

    // MARK: Formatting

    /// A region as `pdf crop --bbox` takes it, rounded outward to hundredths of the page, so a
    /// crop of a block never cuts off the block's edge.
    public static func format(_ box: Box) -> String {
        let outward = box.outward
        return [outward.x, outward.y, outward.width, outward.height].map { String(format: "%.2f", $0) }.joined(separator: ",")
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
    public static func quoted(_ path: String) -> String {
        if path.hasPrefix("-") { return quoted("./" + path) }
        let plain = !path.hasPrefix("~")
            && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-~+:,@".contains($0)) }
        return plain && !path.isEmpty ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
