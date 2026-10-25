import Foundation

/// Writes pages for the agent, with every doubt reported three times: in place, in the summary
/// line and in the exit code (DESIGNS.md → Principles → Failure). `pdf read` builds on it.
public enum Output {
    public struct Page: Sendable {
        /// Counted from 0.
        public var index: Int
        public var result: PageResult
        public var key: String
        /// What the page's annotations show beside its text, from the file's facts: they belong
        /// to this version of the file, not to the page's parse, so highlights added to a file
        /// show without its pages read again.
        public var annotations: [FileFacts.Annotation]
        /// How many annotations the page holds past what the cache keeps for it
        /// (`FactReader.maxAnnotations`): a line says so.
        public var moreAnnotations: Int
        /// The page's running headers, footers and publisher stamps, by block, judged against
        /// the pages around it (`Furniture`).
        public var furniture: [Int: Furniture.Kind]
        /// The page's notes and the references to them, judged against the document (`Notes`).
        public var notes: PageNotes
        /// The page's citations of the list of references and its cross-references, judged
        /// against the document (`References`).
        public var citations: PageCitations

        public init(
            index: Int, result: PageResult, key: String, annotations: [FileFacts.Annotation] = [],
            moreAnnotations: Int = 0, furniture: [Int: Furniture.Kind] = [:], notes: PageNotes = PageNotes(),
            citations: PageCitations = PageCitations()
        ) {
            self.index = index
            self.result = result
            self.key = key
            self.annotations = annotations
            self.moreAnnotations = moreAnnotations
            self.furniture = furniture
            self.notes = notes
            self.citations = citations
        }
    }

    /// Whether a read lists, after its text, the entries of the list of references that the text
    /// it shows cites.
    public enum RefsMode: String, Sendable {
        case end, off
    }

    /// Where a read shows footnotes and endnotes: after the text it read, beside the paragraph
    /// that refers to each, or not at all.
    public enum NotesMode: String, Sendable {
        case end, inline, off
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
            /// The text of a block in doubt, shown with `--show raw`.
            case doubtful = "low-quality-text"
            /// The text layer that OCR replaced, shown with `--show raw`.
            case oldOCR = "old-ocr"
            /// Text a reader cannot see that has no block of its own, as text off the page: a
            /// marker, or its words with `--show hidden`.
            case hidden
            /// What an annotation shows beside the text: a comment, a note, a mark on words, a
            /// filled-in field or a link, after the block it sits on. `status` names which.
            case annotation
            /// A figure, a table or a numbered equation, in place of the text inside it: its
            /// number, its caption and the command that crops it (`Region`).
            case figure, table, equation
            /// A footnote or an endnote's text, with its id: after the text, or by the block that
            /// refers to it.
            case note
            /// An entry of the list of references that the text cites, with its id, after the
            /// text with `--refs end`.
            case reference
            /// The text inside a figure, a table or an equation, shown with `--show raw`, labelled with
            /// what it lost.
            case setAside = "set-aside-text"
        }

        /// A link inside a block's text: the words a reader clicks, and where they lead.
        public struct Link: Encodable, Equatable, Sendable {
            public var text: String
            public var target: String
            /// About where in the block's text the words stand, in UTF-16 units, from the link's
            /// place on the page, so that of several "1"s the link goes on its own.
            var at: Int? = nil

            enum CodingKeys: String, CodingKey {
                case text, target
            }
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
        /// An annotation's author, a link's target, the comment a mark carries, and a field's name.
        public var author: String?
        public var target: String?
        public var note: String?
        public var name: String?
        /// The links inside a text block's words.
        public var links: [Link]?
        /// A figure's, a table's or an equation's number, as its caption gives it.
        public var number: String?
        /// An equation's LaTeX, or a table's Markdown, as the agent read it from the crop and kept
        /// it with `pdf transcribe`, and the day it did (`Transcripts`).
        public var latex: String?
        public var markdown: String?
        public var transcribed: String?
        /// A note's id, as "7" or "3.7", and for a note listed after the text, the page it is on.
        public var id: String?
        public var place: String?

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
        /// The running headers, footers and publisher stamps the unit sets aside, or shows with
        /// `--show headers`.
        var furniture = 0
        /// The block a unit of no blocks stands for, as a running header set aside: a read cut
        /// there, a section's end and `--from` place it as they would the block.
        var number: Int? = nil
        /// How many blocks of text inside figures, tables and equations the unit sets aside.
        var inside = 0
        /// How many footnotes and endnotes the unit holds out of the text: shown after it, by the
        /// block that refers to each, or not at all.
        var notes = 0
        /// For a figure, a table or an equation, the number of its last block: a read that goes
        /// on from a block inside it, as a search hit's, shows it.
        var last: Int? = nil
        /// The ids of the entries of the list of references that the unit's text cites.
        var cites: [String] = []
    }

    /// What one page contributes to the output.
    struct PageBlocks {
        /// The page heading, then the page's units.
        var units: [Unit]
        /// The page carries a text layer that OCR replaced, which only `--show raw` shows.
        var oldLayers = 0
        /// The notes that go after the text, each with the number of the block that refers to it,
        /// or of its own first block where none does, and its own blocks' numbers: a read shows a
        /// note where it reaches that block, or where it starts inside the note, as a search hit's
        /// read does.
        var collected: [(block: Block, at: Int, own: [Int])] = []
    }

    /// The blocks of one page, with the agent's picks and transcripts applied.
    /// - Parameters:
    ///   - path: the path as a shell word, for the commands the blocks suggest.
    ///   - raw: show the text that normal output sets aside as doubtful, labelled with its reason.
    ///   - headers: show the running headers, footers and publisher stamps in place, labelled.
    static func pageBlocks(
        _ page: Page, picks: [String: [Pick]], transcripts: [String: [Transcript]] = [:], path: String, raw: Bool,
        includeHidden: Bool = false, headers: Bool = false, notesMode: NotesMode = .end
    ) -> PageBlocks {
        let (quality, picked) = judge(page, picks: picks)
        let layer = page.result.pageText
        let number = page.index + 1
        var result = PageBlocks(units: [Unit(blocks: [Block(kind: .page, page: number, printed: layer?.label)])])
        let unsureByBlock = Dictionary(grouping: quality.unsure, by: \.block)
        func status(_ doubt: Doubt) -> PageQuality.Status { doubt.kind == .failed ? .failed : .lowQuality }
        // The number of the page's last block so far: what has no block in the layer is numbered
        // after it, the same with `--show raw` or without, so a read cut there goes on past it.
        var after = layer?.blocks.count ?? 0
        // A damaged content stream: nothing of it shows, in the text or the image, so its block
        // names no command.
        let damaged = quality.doubts.first(where: { $0.reason == Quality.damagedReason }).map { doubt in
            Block(kind: .failure, page: number, status: doubt.kind.rawValue, reason: doubt.reason)
        }
        // What the page's annotations show, each after the block it sits on, with that block's
        // number, so a read cut there goes on as before.
        let notes = annotations(page, layer: layer, path: path, includeHidden: includeHidden, heldBack: quality.wholePage)
        func numbered(_ note: Note, _ block: Int) -> Block {
            var numbered = note.block
            numbered.block = block
            return numbered
        }
        // A unit goes out whole after a page's heading, so a paragraph's annotations take at most
        // about 1,000 tokens, and a line counts the rest: 300 comments on one paragraph sent a
        // read of 2,000 tokens 300 KB.
        func attach(_ notes: [Note], to unit: inout Unit, number: Int) {
            var spent = 0, left = 0
            for note in notes {
                let block = numbered(note, number)
                let cost = tokens(render(block, style: .md, raw: false))
                guard left == 0, spent + cost <= Output.annotationTokens || spent == 0 else {
                    left += 1
                    continue
                }
                spent += cost
                unit.blocks.append(block)
                if note.hidden { unit.hidden += 1 }
            }
            if left > 0 {
                unit.blocks.append(Block(kind: .annotation, page: page.index + 1, block: number,
                                         text: "\(left) more annotation\(left == 1 ? "" : "s") here, not shown", status: "more"))
            }
        }
        // The annotations with no block to go with, on a page with no text or one in doubt as a
        // whole: a unit of their own, after the page's blocks.
        func rest(_ notes: [Note]) {
            guard !notes.isEmpty else { return }
            after += 1
            var unit = Unit(blocks: [])
            attach(notes, to: &unit, number: after)
            result.units.append(unit)
        }

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
            // On a page in doubt as a whole, the damage goes with the page's failure block, with no
            // number as it has: a read that goes on from a block shows that one again each time,
            // and a block numbered after it could never be reached.
            if let damaged { unit.blocks.append(damaged) }
            result.units.append(unit)
            rest(notes)
        } else if let layer {
            // Figures, tables and equations: each goes out once, as one block where the first of
            // its blocks stands, with its caption's text. The text inside it is set aside, shown
            // with `--show raw`, unless it holds text a reader cannot see, whose markers go out as they
            // would anywhere.
            let regions = layer.regions ?? []
            var captionOf: [Int: Int] = [:], insideOf: [Int: Int] = [:], anchors: [Int: [Int]] = [:]
            for (position, region) in regions.enumerated() {
                let caption = region.caption.filter(layer.blocks.indices.contains)
                let inside = region.blocks.filter { layer.blocks.indices.contains($0) && !caption.contains($0) }
                for block in caption { captionOf[block] = position }
                for block in inside where layer.blocks[block].hidden?.isEmpty ?? true { insideOf[block] = position }
                if let first = (caption + inside).min() { anchors[first, default: []].append(position) }
            }
            func inDoubt(_ index: Int) -> Bool { quality.doubts.contains { $0.blocks?.contains(index) == true } }
            func regionUnit(_ position: Int, at index: Int) -> Unit {
                let region = regions[position]
                // Its caption's blocks, but those in doubt or set aside as running headers, which go
                // out as they would anywhere.
                let captions = region.caption.filter { layer.blocks.indices.contains($0) && !inDoubt($0) && page.furniture[$0] == nil }
                var hidden = 0
                var spans: [(index: Int, choices: [Unsure], looks: [Unsure])] = []
                let text = captions.map { caption -> String in
                    let block = layer.blocks[caption]
                    let runs = block.hidden ?? []
                    hidden += runs.count
                    let found = (unsureByBlock[caption] ?? []).filter { span in
                        !runs.contains { $0.offset < span.offset + span.readings[0].utf16.count && span.offset < $0.offset + $0.length }
                    }
                    spans.append((caption, found.filter(\.pickable), found.filter { !$0.pickable }))
                    return shown(block.text, pick: picked[caption], choices: found.filter(\.pickable), hidden: runs,
                                 includeHidden: includeHidden, path: path, page: number)
                }.joined(separator: " ")
                let kind = Block.Kind(rawValue: region.kind.rawValue) ?? .figure
                var block = Block(kind: kind, page: number, block: index + 1, box: region.box, text: text.isEmpty ? nil : Output.caption(text),
                                  commands: ["crop": "pdf crop \(path) --page \(number) --\(region.kind.rawValue) \(region.number)"])
                block.number = region.number
                // What the agent kept for an equation or a table, which goes out in place of its flat
                // text: for the first region of its number on the page, which `pdf crop` crops.
                let regionNumber = Region.normalized(region.number)
                let first = regions.firstIndex { $0.kind == region.kind && Region.normalized($0.number) == regionNumber } == position
                let kept = first ? (transcripts[page.key] ?? []).first { $0.kind == region.kind && $0.number == regionNumber } : nil
                if let kept {
                    if region.kind == .table { block.markdown = kept.text } else { block.latex = kept.text }
                    block.transcribed = kept.day
                }
                var unit = Unit(blocks: [block], holdsText: !text.isEmpty || kept != nil)
                unit.last = (region.caption + region.blocks).max().map { $0 + 1 }
                unit.hidden = hidden
                if let alt = region.alt, !alt.isEmpty {
                    unit.blocks.append(Block(kind: .hidden, page: number, block: index + 1, box: region.box,
                                             text: marker(alt, reason: .altText, includeHidden: includeHidden, path: path, page: number)))
                    unit.hidden += 1
                }
                var links: [Block.Link] = [], others: [Note] = []
                for note in notes where note.anchor.map(captions.contains) == true {
                    if let link = note.link, Self.shows(text, link.text) { links.append(link) } else { others.append(note) }
                }
                if !links.isEmpty { unit.blocks[0].links = links }
                attach(others, to: &unit, number: index + 1)
                for span in spans {
                    let block = layer.blocks[span.index]
                    if !span.choices.isEmpty && picked[span.index] == nil {
                        unit.blocks.append(unsureBlock(span.choices, block: block, page: number, index: span.index, path: path))
                        unit.flag = .unsure
                    }
                    if !span.looks.isEmpty {
                        unit.blocks.append(lookBlock(span.looks, block: block, page: number, index: span.index, path: path))
                        unit.flag = .unsure
                    }
                }
                return unit
            }
            // Notes. A footnote or an endnote goes out of the text, to follow the output, or the
            // block that refers to it, or nowhere; a margin note goes after the paragraph it stands
            // beside; a headnote stays in place, labelled. A note whose blocks are in doubt, have
            // unsure words, hold hidden text or are set aside as running headers stays text.
            var noteAt: [Int: Int] = [:]
            var firstOf: [Int: Int] = [:]
            var membersOf: [Int: [Int]] = [:]
            var marginAt = Set<Int>()
            var headnoteAt = Set<Int>()
            var noteBlocks: [Int: Block] = [:]
            var referenceOf: [Int: Int] = [:]
            var startsAt: [Int: Int] = [:]
            // The ids of the page's notes that stay text: their references stay as the PDF has them.
            var keptAsText = Set<String>()
            for (position, entry) in page.notes.entries.enumerated() {
                let members = entry.blocks.filter(layer.blocks.indices.contains)
                guard let first = members.first,
                    members.allSatisfy({
                        page.furniture[$0] == nil && !inDoubt($0) && unsureByBlock[$0] == nil
                            && captionOf[$0] == nil && insideOf[$0] == nil && (layer.blocks[$0].hidden ?? []).isEmpty
                    })
                else {
                    if let id = entry.id { keptAsText.insert(id) }
                    continue
                }
                switch entry.kind {
                case .headnote:
                    headnoteAt.insert(first)
                case .margin:
                    marginAt.insert(first)
                case .footnote, .endnote:
                    guard let id = entry.id else { continue }
                    var note = Block(
                        kind: .note, page: number, text: Notes.text(of: entry, in: layer),
                        status: entry.author ? "author note" : entry.kind.rawValue)
                    note.id = id
                    noteBlocks[position] = note
                    firstOf[position] = first
                    membersOf[position] = members
                    for member in members { noteAt[member] = position }
                    startsAt[first, default: 0] += 1
                    for (block, references) in page.notes.references where references.contains(where: { $0.ids.contains(id) }) {
                        referenceOf[position] = min(referenceOf[position] ?? Int.max, block)
                    }
                }
            }
            // A page's notes take about 4,000 tokens at most and one note 800, as a paragraph's
            // annotations are held to 1,000: a page of thousands of small blocks that start with a
            // number must not run a read over its budget. What is left out is counted, and
            // `pdf note` shows any note whole.
            var leftOut = 0
            var firstLeftOut: String?
            var spent = 0
            // In the page's order: notes that run together in one block share it.
            let noteOrder = noteBlocks.keys.sorted { (firstOf[$0]!, $0) < (firstOf[$1]!, $1) }
            for position in noteOrder {
                var note = noteBlocks[position]!
                if tokens(note.text ?? "") > Output.noteTokens {
                    note.text = prefix(note.text ?? "", tokens: Output.noteTokens) + "… (whole: pdf note \(path) \(quoted(note.id ?? "")))"
                    noteBlocks[position] = note
                }
                let cost = tokens(render(note, style: .md, raw: false))
                if spent + cost > Output.pageNoteTokens, spent > 0 {
                    noteBlocks[position] = nil
                    leftOut += 1
                    firstLeftOut = firstLeftOut ?? note.id
                } else {
                    spent += cost
                }
            }
            // A margin note goes after the block it stands level with, else the nearest above.
            var marginsAfter: [Int: [Block]] = [:]
            var marginSpent: [Int: Int] = [:]
            for index in marginAt.sorted() {
                let box = layer.blocks[index].box
                let candidates = layer.blocks.indices.filter {
                    $0 != index && page.furniture[$0] == nil && noteAt[$0] == nil && !marginAt.contains($0) && !headnoteAt.contains($0)
                        && captionOf[$0] == nil && insideOf[$0] == nil && !inDoubt($0)
                }
                func gap(_ other: Int) -> Double {
                    let found = layer.blocks[other].box
                    return max(0, found.x - (box.x + box.width), box.x - (found.x + found.width))
                }
                let level = candidates.filter {
                    layer.blocks[$0].box.y <= box.y + 0.005 && box.y <= layer.blocks[$0].box.y + layer.blocks[$0].box.height
                }
                let anchor =
                    level.min { gap($0) < gap($1) }
                    ?? candidates.filter { layer.blocks[$0].box.y <= box.y }.max { layer.blocks[$0].box.y < layer.blocks[$1].box.y }
                    ?? candidates.first
                guard let anchor else {
                    marginAt.remove(index)
                    continue
                }
                let margin = Block(
                    kind: .text, page: number, block: index + 1, box: layer.blocks[index].box,
                    text: shown(
                        layer.blocks[index].text, pick: nil, choices: [], hidden: [], includeHidden: includeHidden,
                        path: path, page: number),
                    status: "margin")
                // A paragraph's margin notes take about 1,000 tokens at most, as its annotations do,
                // since they go out with it whole: the rest reads in its place, as text, within the budget.
                let cost = tokens(render(margin, style: .md, raw: false))
                if marginSpent[anchor, default: 0] + cost > Output.annotationTokens {
                    marginAt.remove(index)
                    continue
                }
                marginSpent[anchor, default: 0] += cost
                marginsAfter[anchor, default: []].append(margin)
            }
            var inlineAt: [Int: [Block]] = [:]
            var inlineLeft: [Block] = []
            var inlinePlaced = Set<Int>()
            // With `inline`, a note goes by the block of its page that cites it, or, where none
            // does, as an endnote cited from its chapter, stays in its place.
            var inlineOwn: [Int: [Block]] = [:]
            for position in noteOrder where notesMode == .inline {
                guard var note = noteBlocks[position] else { continue }
                if let block = referenceOf[position] {
                    inlineAt[block, default: []].append(note)
                } else {
                    note.block = firstOf[position]! + 1
                    inlineOwn[firstOf[position]!, default: []].append(note)
                }
            }
            for (index, block) in layer.blocks.enumerated() {
                for position in anchors[index] ?? [] { result.units.append(regionUnit(position, at: index)) }
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
                    attach(notes.filter { $0.anchor == index }, to: &unit, number: index + 1)
                    result.units.append(unit)
                    continue
                }
                // A running header, footer or publisher stamp: unless `headers` shows it, a unit of
                // its own that shows nothing and counts it, in its place, so a read cut, a
                // section's end or `--from` there counts it once, where it stands. On the unit
                // after it, a page of nothing else or a section that ended above that unit lost
                // the count. What sits on it, as a link, still goes out, numbered as it.
                let furniture = page.furniture[index]
                if furniture != nil && !headers {
                    var unit = Unit(blocks: [], furniture: 1, number: index + 1)
                    attach(notes.filter { $0.anchor == index }, to: &unit, number: index + 1)
                    result.units.append(unit)
                    continue
                }
                // A caption's text went out with its region's block.
                if furniture == nil, captionOf[index] != nil { continue }
                // Text inside a figure, a table or an equation: a unit of its own, as a running
                // header's, that counts it, or shows it with `--show raw`.
                if furniture == nil, let position = insideOf[index] {
                    let label = Output.insideLabel(regions[position].kind)
                    var unit = Unit(blocks: [], number: index + 1)
                    if raw {
                        unit.blocks = [Block(kind: .setAside, page: number, block: index + 1, box: block.box,
                                             text: shown(block.text, pick: nil, choices: [], hidden: [], includeHidden: includeHidden,
                                                         path: path, page: number),
                                             status: label)]
                    } else {
                        unit.inside = 1
                    }
                    attach(notes.filter { $0.anchor == index }, to: &unit, number: index + 1)
                    result.units.append(unit)
                    continue
                }
                // A footnote or an endnote, which goes out of the text, and a margin note, which
                // goes after the paragraph it stands beside: a unit of its own that shows nothing.
                if furniture == nil, let position = noteAt[index] {
                    var unit = Unit(blocks: inlineOwn[index] ?? [], number: index + 1)
                    unit.notes = firstOf[position] == index ? startsAt[index] ?? 1 : 0
                    attach(notes.filter { $0.anchor == index }, to: &unit, number: index + 1)
                    result.units.append(unit)
                    continue
                }
                if furniture == nil, marginAt.contains(index) {
                    var unit = Unit(blocks: [], number: index + 1)
                    attach(notes.filter { $0.anchor == index }, to: &unit, number: index + 1)
                    result.units.append(unit)
                    continue
                }
                // Unsure words inside text a reader cannot see stay hidden with it.
                let runs = block.hidden ?? []
                let spans = (unsureByBlock[index] ?? []).filter { span in
                    !runs.contains { $0.offset < span.offset + span.readings[0].utf16.count && span.offset < $0.offset + $0.length }
                }
                let choices = spans.filter(\.pickable)
                let looks = spans.filter { !$0.pickable }
                // Notes cited as `[^7]`, and the list of references, raised, as `[12]`.
                let text = References.linked(
                    shown(
                        block.text, pick: picked[index], choices: choices, hidden: runs, includeHidden: includeHidden,
                        path: path, page: number),
                    notes: (page.notes.references[index] ?? []).filter { !$0.ids.contains(where: keptAsText.contains) },
                    raised: page.citations.raised[index] ?? [])
                var unit = Unit(
                    blocks: [
                        Block(
                            kind: .text, page: number, block: index + 1, box: block.box, text: text,
                            status: furniture?.rawValue ?? (headnoteAt.contains(index) ? "headnote" : nil))
                    ],
                    holdsText: !block.visibleText.isEmpty)
                unit.hidden = runs.count
                if furniture != nil { unit.furniture = 1 }
                // A link whose words the block shows goes inline; any other annotation follows it.
                var links: [Block.Link] = [], others: [Note] = []
                for note in notes where note.anchor == index {
                    if let link = note.link, Self.shows(text, link.text) { links.append(link) } else { others.append(note) }
                }
                // "Fig. 4" or "Section 3.2" leads to the page that holds it, as a link of the file
                // to a page does, unless the file links its words already.
                for pointer in page.citations.pointers[index] ?? [] where Self.shows(text, pointer.words) {
                    let linkedAlready = links.contains { link in
                        guard link.target.hasPrefix("p."), pointer.words.contains(link.text) else { return false }
                        guard let at = link.at else { return true }
                        return abs(at - pointer.offset) <= (pointer.words as NSString).length + 4
                    }
                    if !linkedAlready { links.append(Block.Link(text: pointer.words, target: "p.\(pointer.page)", at: pointer.offset)) }
                }
                if !links.isEmpty { unit.blocks[0].links = links }
                unit.cites = page.citations.cites[index] ?? []
                attach(others, to: &unit, number: index + 1)
                unit.blocks += marginsAfter[index] ?? []
                if let attached = inlineAt[index] {
                    unit.blocks += attached
                    inlinePlaced.insert(index)
                }
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
            // Text the page draws that PDFKit left out has no block either: a failure block for
            // each place says where to look. The image alone shows it: what its strings spell
            // never goes out, even with `--show raw`, as a string hidden in a way the place check
            // misses would go out with it.
            if let unread = layer.unread, let doubt = quality.doubts.first(where: { $0.reason == Quality.unreadReason }) {
                for (position, place) in unread.enumerated() {
                    let region = Box(x: max(0, place.box.x - 0.01), y: max(0, place.box.y - 0.01),
                                     width: min(1, place.box.width + 0.02), height: min(1, place.box.height + 0.02))
                    // Numbered after the page's last block, so a read cut here goes on past it.
                    result.units.append(Unit(blocks: [failureBlock(doubt, page: number, block: layer.blocks.count + 1 + position,
                                                                   region: region, path: path, raw: raw, offersRaw: false)],
                                             flag: .lowQuality))
                }
            }
            // Text placed off the page has no block: PDFKit leaves it out of the page's text,
            // and only the drawing commands spell it.
            after += layer.unread?.count ?? 0
            if let offPage = layer.offPage, !offPage.isEmpty {
                let words = offPage.joined(separator: " ")
                after += 1
                var unit = Unit(blocks: [Block(kind: .hidden, page: number, block: after,
                                               text: marker(words, reason: .offPage, includeHidden: includeHidden, path: path, page: number))])
                unit.hidden = 1
                result.units.append(unit)
            }
            if layer.hiddenCheckIncomplete == true {
                after += 1
                var unit = Unit(blocks: [Block(kind: .hidden, page: number, block: after, text: """
                    [hidden-text check incomplete: the page draws more than the check reads, so some hidden text may read as \
                    text · look: pdf crop \(path) --page \(number)]
                    """)])
                unit.hidden = 1
                result.units.append(unit)
            }
            if var damaged {
                after += 1
                damaged.block = after
                result.units.append(Unit(blocks: [damaged], flag: .lowQuality))
            }
            // Notes that no block of the page refers to, after its other blocks; with the notes
            // that go after the text, which the read collects.
            for block in inlineAt.keys.sorted() where !inlinePlaced.contains(block) { inlineLeft += inlineAt[block]! }
            let more =
                leftOut == 0
                ? nil
                : Block(
                    kind: .annotation, page: number,
                    text: "\(leftOut) more note\(leftOut == 1 ? "" : "s") on this page, not shown: pdf note \(path) \(quoted(firstLeftOut ?? ""))",
                    status: "more")
            if notesMode == .inline, let more { inlineLeft.append(more) }
            if !inlineLeft.isEmpty {
                after += 1
                var unit = Unit(blocks: inlineLeft)
                for position in unit.blocks.indices { unit.blocks[position].block = after }
                result.units.append(unit)
            }
            if notesMode == .end {
                for position in noteOrder {
                    guard let note = noteBlocks[position] else { continue }
                    result.collected.append((note, (referenceOf[position] ?? firstOf[position]!) + 1, membersOf[position]!.map { $0 + 1 }))
                }
                if let more { result.collected.append((more, Int.max, [])) }
            }
            rest(notes.filter { $0.anchor == nil })
        } else {
            rest(notes)
        }
        if page.moreAnnotations > 0 {
            // Numbered after the page's last block, as the annotations with no block are.
            after += 1
            let left = page.moreAnnotations
            let cap = Info.thousands(FactReader.maxAnnotations)
            result.units.append(
                Unit(blocks: [
                    Block(
                        kind: .annotation, page: number, block: after,
                        text: "\(left) more annotation\(left == 1 ? "" : "s") on this page, past \(cap) links and as many others, not shown",
                        status: "more")
                ]))
        }
        if let old = layer?.replacedText {
            if raw {
                // Numbered after the page's last block, so a read that goes on from it skips them.
                result.units.append(Unit(blocks: [Block(kind: .oldOCR, page: number, block: after + 1, text: old)]))
            } else {
                result.oldLayers = 1
            }
        }
        return result
    }

    /// An annotation as a page shows it: its block, the text block it follows, and, for a link
    /// a reader sees, its words and target, to go inline when the block shows the words.
    struct Note {
        var block: Block
        var anchor: Int?
        var hidden = false
        var link: Block.Link?
    }

    /// The page's annotations as blocks (FEATURES.md → F3). A mark's or a link's words count only
    /// where the blocks under it show them: PDFKit's selection under it takes text a reader cannot
    /// see too, as a white line under a highlight. An annotation the file hides is a marker, or
    /// its block's words with `includeHidden`.
    /// - Parameter heldBack: the page's text is set aside as a whole, so no mark shows its words.
    static func annotations(_ page: Page, layer: PageText?, path: String, includeHidden: Bool, heldBack: Bool = false) -> [Note] {
        let number = page.index + 1
        let blocks = layer?.blocks ?? []
        // The words under a mark that a reader sees there: the longest run of them that the
        // blocks under it show in the same order, one after another. Words kept one by one let
        // a hidden sentence through, made of words the page shows elsewhere.
        func seen(_ words: String?, under box: Box, anchor: Int?) -> String? {
            guard !heldBack, let words else { return nil }
            let under = blocks.indices.filter { index in
                let other = blocks[index].box
                return other.x < box.x + box.width && box.x < other.x + other.width && other.y < box.y + box.height && box.y < other.y + other.height
            }
            let picked = words.split(whereSeparator: \.isWhitespace).map(String.init)
                .filter { !Visibility.normalized($0).isEmpty }.prefix(200)
            let keys = picked.map { Visibility.normalized($0) }
            let visible = Array((under.isEmpty ? [anchor].compactMap { $0 } : under).flatMap { index in
                blocks[index].visibleText.split(whereSeparator: \.isWhitespace).map { Visibility.normalized(String($0)) }
            }.filter { !$0.isEmpty }.prefix(5_000))
            guard !keys.isEmpty, !visible.isEmpty else { return nil }
            var best = (start: 0, length: 0)
            var previous = [Int](repeating: 0, count: visible.count + 1)
            for i in 1...keys.count {
                var current = [Int](repeating: 0, count: visible.count + 1)
                for j in 1...visible.count where keys[i - 1] == visible[j - 1] {
                    current[j] = previous[j - 1] + 1
                    if current[j] > best.length { best = (i - current[j], current[j]) }
                }
                previous = current
            }
            return best.length == 0 ? nil : picked[best.start..<best.start + best.length].joined(separator: " ")
        }
        // Each image and drawing the page shows, with the command that crops it, but those inside
        // a figure or a table, whose block crops them and carries their alt text. A page in doubt
        // as a whole shows no such block, so it shows them all.
        let covered = heldBack ? [] : (layer?.regions ?? []).filter { $0.kind != .equation }.map(\.box)
        let outside = (layer?.pictures ?? []).filter { picture in !covered.contains { Output.share(of: picture.box, inside: $0) >= 0.5 } }
        let pictures = outside.map { picture -> Note in
            let box = Box(x: max(0, picture.box.x), y: max(0, picture.box.y), width: min(1, picture.box.width), height: min(1, picture.box.height))
            var block = Block(kind: .annotation, page: number, box: box, status: picture.kind)
            block.commands = ["crop": "pdf crop \(path) --page \(number) --bbox \(format(box))"]
            // Its alternate text, which a reader of the page never sees: a marker, or its words
            // with `includeHidden`, labelled.
            if let alt = picture.alt, !alt.isEmpty {
                block.text = marker(alt, reason: .altText, includeHidden: includeHidden, path: path, page: number)
                return Note(block: block, anchor: anchor(box, in: blocks), hidden: true)
            }
            return Note(block: block, anchor: anchor(box, in: blocks))
        }
        let ordered = page.annotations.filter { $0.page == page.index }.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
        let notes =
            (pictures
            + ordered.map { annotation in
                let anchor = anchor(annotation.box, in: blocks)
                var block = Block(
                    kind: .annotation, page: number, box: annotation.box,
                    status: annotation.reply == true ? "reply" : annotation.kind.rawValue)
                block.author = annotation.author
                switch annotation.kind {
                case .comment, .note:
                    block.text = annotation.text
                case .highlight, .underline, .squiggly, .strikeout:
                    block.text = seen(annotation.words, under: annotation.box, anchor: anchor)
                    block.note = annotation.text
                case .field:
                    block.name = annotation.name
                    block.text = annotation.value
                case .stamp, .ink, .shape:
                    block.text = annotation.text
                case .link:
                    block.text = seen(annotation.words, under: annotation.box, anchor: anchor)
                    block.target = annotation.target
                }
                var note = Note(block: block, anchor: anchor)
                // A link whose words a reader cannot see is no link a reader sees.
                let unseenLink = annotation.kind == .link && annotation.words != nil && block.text == nil && !heldBack
                if annotation.hidden == true || unseenLink {
                    // The marker counts the annotation's own words; shown, they come with its label.
                    let words = includeHidden ? render(block, style: .text, raw: false) : block.text ?? annotation.words ?? block.target ?? ""
                    note.block = Block(
                        kind: .hidden, page: number, box: annotation.box,
                        text: marker(words, reason: .annotation, includeHidden: includeHidden, path: path, page: number))
                    note.hidden = true
                } else if annotation.kind == .link, let words = block.text, let target = block.target {
                    note.link = Block.Link(text: words, target: target, at: anchor.map { offset(of: annotation.box, in: blocks[$0]) } ?? nil)
                } else if [.stamp, .ink, .shape].contains(annotation.kind) {
                    note.block.commands = ["crop": "pdf crop \(path) --page \(number) --bbox \(format(annotation.box))"]
                }
                return note
            }).sorted { ($0.block.box.y, $0.block.box.x) < ($1.block.box.y, $1.block.box.x) }
        // Top to bottom, and left to right along a row: those whose tops lie within a hundredth of
        // the page of the row's first. A drawing's box is half a point taller than its shapes, so
        // a chart beside an image came first.
        var rows: [[Note]] = []
        for note in notes {
            if let first = rows.last?.first, note.block.box.y - first.block.box.y <= 0.01 {
                rows[rows.count - 1].append(note)
            } else {
                rows.append([note])
            }
        }
        return rows.flatMap { $0.sorted { $0.block.box.x < $1.block.box.x } }
    }

    /// The block an annotation goes with: the one its center lies in; or else the nearest across
    /// the page of those its center's height crosses, as a field goes with its label, and a note
    /// in the margin with the paragraph beside it; or else, of the blocks above or below it, the
    /// last in reading order whose top lies above its center, those in its column first. Nil on
    /// a page with no blocks.
    static func anchor(_ box: Box, in blocks: [TextBlock]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let x = box.x + box.width / 2, y = box.y + box.height / 2
        if let inside = blocks.firstIndex(where: { $0.box.x <= x && x <= $0.box.x + $0.box.width && $0.box.y <= y && y <= $0.box.y + $0.box.height }) {
            return inside
        }
        func gap(_ block: TextBlock) -> Double { max(0, block.box.x - (box.x + box.width), box.x - (block.box.x + block.box.width)) }
        let row = blocks.indices.filter { blocks[$0].box.y <= y && y <= blocks[$0].box.y + blocks[$0].box.height }
        if let nearest = row.min(by: { gap(blocks[$0]) < gap(blocks[$1]) }) { return nearest }
        let column = blocks.indices.filter { gap(blocks[$0]) == 0 }
        return (column.isEmpty ? Array(blocks.indices) : column).last { blocks[$0].box.y <= y } ?? column.first ?? 0
    }

    /// About where in a block's text a box on the page starts, in UTF-16 units: the line it lies
    /// on, and how far along that line it starts.
    static func offset(of box: Box, in block: TextBlock) -> Int? {
        guard !block.lines.isEmpty else { return nil }
        let y = box.y + box.height / 2
        func middle(_ line: TextLine) -> Double { line.box.y + line.box.height / 2 }
        let line =
            block.lines.firstIndex { $0.box.y <= y && y <= $0.box.y + $0.box.height }
            ?? block.lines.indices.min { abs(middle(block.lines[$0]) - y) < abs(middle(block.lines[$1]) - y) }!
        let before = block.lines[..<line].reduce(0) { $0 + $1.text.utf16.count + 1 }
        let own = block.lines[line]
        let along = own.box.width > 0 ? min(max((box.x - own.box.x) / own.box.width, 0), 1) : 0
        return before + Int(along * Double(own.text.utf16.count))
    }

    /// A block's text with its links in their words. Each goes on the place of its words nearest
    /// where the link stands, a whole word where one is, never inside a note's mark, a hidden-text
    /// label or another link: a list of references whose entries each link a "1" back to page 1
    /// gave `[[[1](#p.1)](#p.1)]`.
    static func placed(_ text: String, links: [Block.Link], style: Style) -> String {
        guard !links.isEmpty else { return text }
        let ns = text as NSString
        var blocked = References.hiddenSpans(ns)
        var from = 0
        while from < ns.length {
            let open = ns.range(of: "[^", range: NSRange(location: from, length: ns.length - from))
            guard open.location != NSNotFound else { break }
            let close = ns.range(of: "]", range: NSRange(location: open.upperBound, length: ns.length - open.upperBound))
            let end = close.location == NSNotFound ? ns.length : close.upperBound
            blocked.append(NSRange(location: open.location, length: end - open.location))
            from = end
        }
        func whole(_ range: NSRange) -> Bool {
            func word(_ at: Int) -> Bool {
                guard at >= 0, at < ns.length, let scalar = Unicode.Scalar(ns.character(at: at)) else { return false }
                return CharacterSet.alphanumerics.contains(scalar)
            }
            return !word(range.location - 1) && !word(range.upperBound)
        }
        var chosen: [(range: NSRange, link: Block.Link)] = []
        for link in links where !link.text.isEmpty {
            var candidates: [NSRange] = []
            var start = 0
            while start < ns.length {
                let found = ns.range(of: link.text, range: NSRange(location: start, length: ns.length - start))
                guard found.location != NSNotFound else { break }
                start = found.location + 1
                guard !blocked.contains(where: { NSIntersectionRange($0, found).length > 0 }),
                    !chosen.contains(where: { NSIntersectionRange($0.range, found).length > 0 })
                else { continue }
                candidates.append(found)
            }
            let wholes = candidates.filter(whole)
            let pool = wholes.isEmpty ? candidates : wholes
            guard let first = pool.first else { continue }
            let pick =
                link.at.map { at in pool.min { abs($0.location - at) < abs($1.location - at) }! }
                ?? pool.first { range in chosen.allSatisfy { $0.range.location < range.location } } ?? first
            chosen.append((pick, link))
        }
        var result = ns
        for item in chosen.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: item.range, with: linked(item.link.text, to: item.link.target, style: style)) as NSString
        }
        return result as String
    }

    /// Where a block's text shows a link's words, outside a note's mark: in `Prolific[^3]`, a
    /// link on the 3 stays out of `[^3]`.
    static func place(_ words: String, in text: String) -> Range<String.Index>? {
        var from = text.startIndex
        while let range = text.range(of: words, range: from..<text.endIndex) {
            let before = text[..<range.lowerBound]
            if let open = before.range(of: "[^", options: .backwards), !before[open.upperBound...].contains("]") {
                from = range.upperBound
                continue
            }
            return range
        }
        return nil
    }

    /// Whether a block's text shows a link's words, outside a hidden-text marker.
    static func shows(_ text: String, _ words: String) -> Bool {
        guard let range = place(words, in: text) else { return false }
        let before = text[..<range.lowerBound]
        guard let open = before.range(of: "[hidden", options: .backwards) else { return true }
        return before[open.upperBound...].contains("]")
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
        /// Show the running headers, footers and publisher stamps in place, labelled.
        let headers: Bool
        /// Where footnotes and endnotes show.
        let notesMode: NotesMode
        /// Whether the entries of the list of references that the text cites follow it.
        let refsMode: RefsMode
        let picks: [String: [Pick]]
        let transcripts: [String: [Transcript]]
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
        /// Running headers, footers and publisher stamps set aside, or shown with `headers`.
        var furniture = 0
        /// Blocks of text inside figures, tables and equations set aside.
        var inside = 0
        /// Footnotes and endnotes held out of the text.
        var notesAside = 0
        /// The footnotes and endnotes that follow the output, from the pages read to their end,
        /// or as far as the references the read reached. They count against the budget, which a
        /// page's notes may pass: the read does not stop to cut a note off.
        public private(set) var endNotes: [Block] = []
        /// With `refs`, the entries of the list of references that the text shown cites, each once,
        /// after the notes. Each counts against the budget at the block that first cites it.
        public private(set) var endRefs: [Block] = []
        var refsShown = Set<String>()
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
        /// How many entries the list of references holds in the pages parsed so far, as the
        /// judged index has them; zero says no list has been seen.
        public var listEntries = 0

        /// - Parameter continuation: the full command that goes on from a page, a block and a
        ///   character in the block's text, such as `pdf read paper.pdf --page 4-9 --from p4.7`.
        public init(
            file: String, pageCount: Int, style: Style = .md, raw: Bool = false, includeHidden: Bool = false,
            headers: Bool = false, notes: NotesMode = .end, refs: RefsMode = .off, picks: [String: [Pick]] = [:],
            transcripts: [String: [Transcript]] = [:], budget: Int? = nil,
            continuation: (@Sendable (Int, Int?, Int?) -> String)? = nil
        ) {
            let path = quoted(file)
            self.file = file
            self.path = path
            self.pageCount = pageCount
            self.style = style
            self.raw = raw
            self.includeHidden = includeHidden
            self.headers = headers
            self.notesMode = notes
            self.refsMode = refs
            self.picks = picks
            self.transcripts = transcripts
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
            let content = pageBlocks(
                page, picks: picks, transcripts: transcripts, path: path, raw: raw, includeHidden: includeHidden,
                headers: headers, notesMode: notesMode)
            let number = page.index + 1
            // The notes that follow the output go out for the page read as far as the read got.
            var reached: Int?
            // What the page's notes after the output cost, by the block where the read takes each,
            // and what those the read passed so far cost: a page of endnotes, whose blocks show
            // nothing in place, stops at the budget as a page of text does.
            var noteCost: [Int: Int] = [:]
            for item in content.collected where item.at != Int.max {
                var note = item.block
                note.place = "p.\(number)"
                noteCost[item.at, default: 0] += tokens(render(note, style: style, raw: raw))
            }
            var pending = 0
            for (position, var unit) in content.units.enumerated() {
                let at = unit.blocks.first?.block ?? unit.number
                if position > 0, let block, (unit.last ?? at ?? Int.max) < block { continue }
                if position > 0, let until, until.page == number, (at ?? Int.max) >= until.block {
                    reached = until.block
                    break
                }
                let notes = position > 0 ? at.flatMap { noteCost[$0] } ?? 0 : 0
                // Only this page's heading is out in this read, so this unit goes out anyway.
                let alone = position > 0 && rendered.count == 1 && endNotes.isEmpty && pending == 0
                // A unit that shows nothing, as a running header set aside, costs nothing but its notes.
                guard let first = unit.blocks.first else {
                    if let budget, notes > 0, used + pending + notes > budget, !alone, let at {
                        next = continuation(number, at, nil)
                        collect(content, page: number, before: at, from: block)
                        return false
                    }
                    emit(unit, page: number)
                    pending += notes
                    continue
                }
                let resumed = position > 0 && offset != nil && first.block == block && first.kind == .text
                if resumed, let offset, let text = first.text { unit.blocks[0].text = "…" + String(text.dropFirst(offset)) }
                let refs = references(unit, of: page)
                let cost = unit.blocks.reduce(0) { $0 + tokens(render($1, style: style, raw: raw)) } + notes
                    + refs.reduce(0) { $0 + tokens(render($1, style: style, raw: raw)) }
                if let budget, used + pending + cost > budget, !(position == 0 && rendered.isEmpty) {
                    guard alone else {
                        next = continuation(number, position == 0 ? nil : first.block, nil)
                        collect(content, page: number, before: position == 0 ? 0 : first.block, from: block)
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
                            cut.furniture = unit.furniture
                            cut.blocks[0].text = kept + "…"
                            emit(cut, page: number)
                            next = continuation(number, first.block, (resumed ? offset ?? 0 : 0) + shownHere)
                            collect(content, page: number, before: first.block, from: block)
                            return false
                        }
                    }
                }
                emit(unit, page: number)
                for entry in refs {
                    endRefs.append(entry)
                    if let id = entry.id { refsShown.insert(id) }
                    used += tokens(render(entry, style: style, raw: raw))
                }
                pending += notes
            }
            // The page is done: it counts as read even if it holds no block, and its old OCR
            // layer, which only `--show raw` shows, counts as set aside.
            if pagesRead.last != number { pagesRead.append(number) }
            oldLayers += content.oldLayers
            collect(content, page: number, before: reached, from: block)
            return true
        }

        /// With `refs`, the entries a unit cites that the read has not listed yet, each held to
        /// about 800 tokens, a unit's to about 1,000, and a line for the rest, as notes and
        /// annotations are: a review's paragraph that cites forty papers must not pass the budget.
        func references(_ unit: Unit, of page: Page) -> [Block] {
            guard refsMode == .end, !unit.cites.isEmpty else { return [] }
            var blocks: [Block] = []
            var spent = 0
            var left: [String] = []
            for id in unit.cites where !refsShown.contains(id) && !left.contains(id) {
                guard let entry = page.citations.entries[id] else { continue }
                var text = entry.text
                if tokens(text) > Output.noteTokens {
                    text = prefix(text, tokens: Output.noteTokens) + "… (whole: pdf ref \(path) \(quoted(id)))"
                }
                var block = Block(kind: .reference, page: entry.page + 1, block: (entry.blocks.first ?? 0) + 1, text: text)
                block.id = id
                block.place = "p.\(entry.page + 1)"
                let cost = tokens(render(block, style: style, raw: raw))
                guard left.isEmpty, spent + cost <= Output.annotationTokens || spent == 0 else {
                    left.append(id)
                    continue
                }
                spent += cost
                blocks.append(block)
            }
            if let first = left.first {
                let count = left.count
                blocks.append(
                    Block(
                        kind: .annotation, page: page.index + 1, block: unit.blocks.first?.block,
                        text: "\(count) more entr\(count == 1 ? "y" : "ies") cited here, not listed: pdf ref \(path) \(quoted(first))",
                        status: "more"))
            }
            return blocks
        }

        /// Adds the page's notes that go after the output: those whose place, the block that refers
        /// to each or else its own, lies before block `limit`, or all of them where the page was
        /// read to its end, and, on a read that goes on from block `from`, those whose place lies
        /// at or after it, or whose own blocks hold it: the read before showed the others.
        mutating func collect(_ content: PageBlocks, page number: Int, before limit: Int?, from: Int?) {
            for item in content.collected {
                if let limit, item.at >= limit { continue }
                if let from, item.at < from, !item.own.contains(from) { continue }
                var note = item.block
                note.place = "p.\(number)"
                endNotes.append(note)
                used += tokens(render(note, style: style, raw: raw))
            }
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
            furniture += unit.furniture
            inside += unit.inside
            notesAside += unit.notes
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
            if oldLayers > 0 { aside.append("\(oldLayers) replaced text layer\(oldLayers == 1 ? "" : "s")") }
            if inside > 0 { aside.append("\(inside) block\(inside == 1 ? "" : "s") of text inside figures, tables and equations") }
            if raw {
                summary.append("showing the text set aside as doubtful")
            } else if !aside.isEmpty {
                summary.append("set aside: " + aside.joined(separator: ", ") + " (show: --show raw)")
            }
            if notesMode == .off, notesAside > 0 {
                summary.append("footnotes and endnotes: \(notesAside) set aside (show: --notes end)")
            }
            if furniture > 0 {
                summary.append(
                    headers
                        ? "showing running headers and footers: \(furniture)"
                        : "running headers and footers: \(furniture) set aside (show: --show headers)")
            }
            if !hidden.isEmpty {
                let total = hidden.reduce(0) { $0 + $1.count }
                summary.append(
                    (includeHidden ? "showing hidden text: " : "hidden text: ") + "\(total) place\(total == 1 ? "" : "s") on "
                        + hidden.map { "p.\($0.page)" }.joined(separator: ", ") + (includeHidden ? "" : " (show: --show hidden)"))
            }
            if let parsed, parsed < pageCount {
                summary.append("provisional: \(parsed) of \(pageCount) pages parsed so far")
                // The list may stand on a page not parsed yet: say so, not nothing.
                if refsMode == .end, endRefs.isEmpty, listEntries == 0 {
                    summary.append("references: none listed, no list seen in the pages parsed so far (pdf ref parses the whole file)")
                }
            }
            if savedByPDFKit {
                summary.append("⚠ made or last saved by macOS PDFKit, as Preview saves: such a save can damage the text, "
                               + "and an earlier copy may read better")
            }
            var parts = [summary.joined(separator: " · ")] + rendered
            if !endNotes.isEmpty {
                parts.append(style == .md ? "## Notes" : "=== Notes ===")
                parts += endNotes.map { render($0, style: style, raw: raw) }
            }
            if !endRefs.isEmpty {
                parts.append(style == .md ? "## References" : "=== References ===")
                parts += endRefs.map { render($0, style: style, raw: raw) }
            }
            if let stopped { parts.append("⚠ stopped: \(stopped)") }
            if let next { parts.append("next: \(next)") }
            let exitCode: Int32 = flagged.isEmpty ? 0 : holdsText || pagesRead.isEmpty ? 2 : 3
            return Report(text: parts.joined(separator: "\n\n") + "\n", exitCode: exitCode)
        }

        /// The read as JSON: the summary's facts, every block, and the command that continues.
        public func json(savedByPDFKit: Bool = false, parsed: Int? = nil) throws -> Data {
            struct Flag: Encodable {
                var page: Int
                var status: String
            }
            struct Aside: Encodable {
                var doubtfulBlocks: Int
                var oldOCRLayers: Int
                var runningHeaders: Int
                var textInsideFigures: Int
                var notes: Int
            }
            struct HiddenText: Encodable {
                var page: Int
                var places: Int
            }
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
            return try encoder.encode(
                Body(
                    file: file, pageCount: pageCount, pagesRead: pagesRead,
                    flagged: flagged.map { Flag(page: $0.page, status: $0.status.rawValue) },
                    setAside: Aside(
                        doubtfulBlocks: doubtful, oldOCRLayers: oldLayers, runningHeaders: headers ? 0 : furniture,
                        textInsideFigures: inside, notes: notesMode == .off ? notesAside : 0),
                    hidden: hidden.map { HiddenText(page: $0.page, places: $0.count) },
                    provisional: parsed.map { $0 < pageCount } ?? false, savedByPDFKit: savedByPDFKit, blocks: blocks + endNotes + endRefs,
                    stopped: stopped, next: next.map { $0 + " --json" }))
        }
    }

    /// Every page in full, with no budget: the hidden `pdf debug-read` and the tests use it.
    public static func render(
        file: String, pageCount: Int, pages: [Page], picks: [String: [Pick]] = [:], transcripts: [String: [Transcript]] = [:],
        savedByPDFKit: Bool = false, raw: Bool = false, style: Style = .md,
        includeHidden: Bool = false, headers: Bool = false, notes: NotesMode = .end
    ) -> Report {
        var document = Document(
            file: file, pageCount: pageCount, style: style, raw: raw, includeHidden: includeHidden,
            headers: headers, notes: notes, picks: picks, transcripts: transcripts)
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

    /// Why a file failed, with the command that opens a locked one. It reads the password from
    /// standard input, asking on a terminal, so the password stays out of the list of running
    /// commands that `--password` would put it in.
    public static func failure(_ reason: String, file: String, command: String = "add") -> String {
        reason.hasPrefix(OpenFailure.locked)
            ? "\(reason) · open it with: pdf \(command) \(quoted(file)) --password-stdin"
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
        return "[hidden: \(count) word\(count == 1 ? "" : "s"), \(reason.words) · show: pdf read \(path) --page \(page) --show hidden]"
    }

    /// The failure block: what is in doubt, why, and how to read it instead.
    /// - Parameter offersRaw: `--show raw` has text of the doubt's to show.
    static func failureBlock(_ doubt: Doubt, page: Int, block: Int?, region: Box?, path: String, raw: Bool,
                             offersRaw: Bool = true) -> Block {
        var commands = ["crop": "pdf crop \(path) --page \(page)" + (region.map { " --bbox \(format($0))" } ?? "")]
        if doubt.kind == .lowQuality && !raw && offersRaw { commands["raw"] = "pdf read \(path) --page \(page) --show raw" }
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
            let text = placed(block.text ?? "", links: block.links ?? [], style: style)
            // A running header, footer or publisher stamp, shown with `--show headers`.
            let label =
                block.status.flatMap(Furniture.Kind.init(rawValue:)).map { "[\($0.label)] " }
                ?? (block.status == "headnote" || block.status == "margin" ? "[\(block.status!)] " : "")
            return "\(address(block)) \(label)\(text)"
        case .note:
            return "[^\(block.id ?? "")]" + (block.place.map { " (\($0))" } ?? "") + " " + (block.text ?? "")
        case .reference:
            return "[\(block.id ?? "")]" + (block.place.map { " (\($0))" } ?? "") + " " + (block.text ?? "")
        case .annotation:
            let kind = block.status ?? "comment"
            let by = block.author.map { " · \($0)" } ?? ""
            switch kind {
            case "field":
                return "[field: \(block.name ?? "") = \(block.text ?? "")]"
            case "link":
                return "[link] " + linked(block.text ?? block.target ?? "", to: block.target ?? "", style: style)
            case "comment", "reply", "note":
                return "[\(kind)\(by)] \(block.text ?? "")"
            case "more":
                return "[\(block.text ?? "")]"
            case "image", "drawing":
                return "[\(kind)] crop: \(block.commands?["crop"] ?? "")" + (block.text.map { " · \($0)" } ?? "")
            case "stamp", "ink", "shape":
                return "[\(kind)\(by)]" + (block.text.map { " \($0)" } ?? "") + (block.commands?["crop"].map { " · crop: \($0)" } ?? "")
            default:
                return "[\(kind)\(by)]" + (block.text.map { " \($0)" } ?? "") + (block.note.map { " · comment: \($0)" } ?? "")
            }
        case .figure, .table, .equation:
            let text = placed(block.text ?? "", links: block.links ?? [], style: style)
            let label = "\(address(block)) [\(block.kind.rawValue) \(block.number ?? "")]"
            let crop = "crop: \(commands["crop"] ?? "")"
            // The agent's LaTeX or Markdown, labelled as its reading, its lines indented four
            // spaces, below the block's own command lines and inert in Markdown, so that none reads
            // as a page, a block, a command or a fence of its own; the crop stays, to check it by.
            if let kept = block.latex.map(Self.displayed) ?? block.markdown {
                let head = "\(address(block)) [\(block.kind.rawValue) \(block.number ?? ""), transcribed \(block.transcribed ?? "")]"
                return head + (text.isEmpty ? "" : " \(text)") + "\n" + Self.indented(kept) + "\n  \(crop)"
            }
            return text.isEmpty ? "\(label) \(crop)" : "\(label) \(text)\n  \(crop)"
        case .setAside:
            return "\(address(block)) [\(block.status ?? "")] \(block.text ?? "")"
        case .doubtful:
            return "\(address(block)) [\(block.status ?? "low-quality")] \(block.text ?? "")"
        case .oldOCR:
            return "[PDF text layer] \(block.text ?? "")"
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

    /// About how many tokens one paragraph's annotations may take.
    static let annotationTokens = 1_000

    /// About how many tokens one note may take, and the notes of one page.
    static let noteTokens = 800
    static let pageNoteTokens = 4_000

    /// What `--show raw` labels the text inside a region with: what it lost.
    static func insideLabel(_ kind: Region.Kind) -> String {
        switch kind {
        case .table: return "table text: rows and columns lost"
        case .figure: return "figure text"
        case .equation: return "equation text: its layout lost"
        }
    }

    /// A caption's text without its label, as "Table 3:", which the block's own label gives.
    static func caption(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = Regions.captionPattern.firstMatch(in: text, range: range) else { return text }
        let rest = (text as NSString).substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? text : rest
    }

    /// How much of a box lies inside another, from 0 to 1.
    static func share(of box: Box, inside other: Box) -> Double {
        let width = min(box.x + box.width, other.x + other.width) - max(box.x, other.x)
        let height = min(box.y + box.height, other.y + other.height) - max(box.y, other.y)
        guard width > 0, height > 0, box.width * box.height > 0 else { return 0 }
        return width * height / (box.width * box.height)
    }

    /// Words that lead somewhere: `[words](https://…)` in Markdown, `words <https://…>` in plain
    /// text. A page of the file is "p.12", as `--from` writes it.
    static func linked(_ words: String, to target: String, style: Style) -> String {
        guard style == .md else { return "\(words) <\(target.replacingOccurrences(of: ">", with: "%3E"))>" }
        let label = words.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let address = target.hasPrefix("p.") ? "#" + target
            : target.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
        return "[\(label)](\(address))"
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

    /// The agent's LaTeX as display maths: as written when it is a display of its own, as an
    /// `align` environment, or holds its own signs, as `$a$ and $b$`; else between `$$` lines,
    /// which a `%` comment on its last line leaves closed.
    static func displayed(_ latex: String) -> String {
        let environments = "equation|align|alignat|gather|multline|flalign|xalignat|eqnarray|subequations|math|displaymath"
        let whole = latex.range(of: #"^\\begin\{("# + environments + #")\*?\}[\s\S]*\\end\{\1\*?\}$"#, options: .regularExpression) != nil
        let signs = latex.replacingOccurrences(of: "\\$", with: "").contains("$") || latex.contains("\\(") || latex.contains("\\[")
        return whole || signs ? latex : "$$\n\(latex)\n$$"
    }

    /// Text the agent gave, each line four spaces in.
    public static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
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
