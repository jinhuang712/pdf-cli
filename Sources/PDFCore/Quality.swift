import Foundation

/// A part of a page whose text is in doubt, and why.
public struct Doubt: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case failed
        case lowQuality = "low-quality"
    }

    public var kind: Kind
    public var reason: String
    /// From 0 to 1, higher is better. Nil when the check gives no number.
    public var score: Double?
    /// The blocks in doubt, counted from 0. Nil means the whole page.
    public var blocks: [Int]?
}

/// The verdict on one page (DESIGNS.md → Principles → Failure).
public struct PageQuality: Equatable, Sendable {
    public enum Status: String, Sendable, Comparable {
        case ok
        case unsure
        case lowQuality = "low-quality"
        case failed

        static let order: [Status] = [.ok, .unsure, .lowQuality, .failed]
        public static func < (lhs: Status, rhs: Status) -> Bool { order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)! }
    }

    public var status: Status
    public var doubts: [Doubt]
    /// Words with two readings, for the agent to pick from.
    public var unsure: [Unsure]

    /// The page holds no text that can be shown: it failed, or all of it is in doubt.
    public var wholePage: Bool { doubts.contains { $0.blocks == nil } }
}

/// Judges each page from the measures its parse stored. The judgment runs at read time, so a
/// threshold tuned later applies to every cached page without parsing it again.
public enum Quality {
    static let unreadReason = "the page draws text here that PDFKit left out of its text"
    static let damagedReason = "part of the page's drawing commands is damaged and could not be read, "
        + "so what it draws is missing here and from the page's image"

    public static func judge(_ result: PageResult) -> PageQuality {
        guard result.status == .ok else {
            return PageQuality(status: .failed, doubts: [Doubt(kind: .failed, reason: result.reason, blocks: nil)], unsure: [])
        }
        guard let layer = result.measures else {
            return PageQuality(status: .failed,
                               doubts: [Doubt(kind: .failed, reason: "the cached page could not be read", blocks: nil)],
                               unsure: [])
        }
        var doubts: [Doubt] = []
        if let score = layer.layerScore {
            doubts.append(Doubt(kind: .lowQuality,
                                reason: "the text layer looks garbled or disagrees with the page image, and OCR could not read the page",
                                score: score, blocks: nil))
        }
        if layer.spacesLost == true {
            doubts.append(Doubt(kind: .lowQuality,
                                reason: "the fonts hide the spaces between words, and OCR could not read the page to restore them",
                                blocks: nil))
        }
        if layer.checkFailed == true {
            // OCR's own confidence does not track its accuracy, so unchecked OCR text is in doubt
            // (DESIGNS.md → Decision: two OCR readings compared, over OCR's own confidence).
            doubts.append(Doubt(kind: .lowQuality,
                                reason: "OCR read the page, but its second reading, which checks the first, failed",
                                blocks: nil))
        } else if let agreement = layer.agreement, agreement < OCR.agreementThreshold {
            doubts.append(Doubt(kind: .lowQuality, reason: "two OCR readings of the page disagree", score: agreement, blocks: nil))
        } else {
            for (index, agreement) in (layer.blockAgreements ?? []).enumerated() {
                guard let agreement, agreement < OCR.agreementThreshold else { continue }
                doubts.append(Doubt(kind: .lowQuality, reason: "two OCR readings of this block disagree",
                                    score: agreement, blocks: [index]))
            }
        }
        // Text the page draws that PDFKit left out: no block holds it, so the doubt names none,
        // and the output gives each place its own failure block.
        if let unread = layer.unread, unread > 0 {
            doubts.append(Doubt(kind: .lowQuality, reason: unreadReason, blocks: []))
        }
        // A damaged content stream draws nothing, in the text or the image: the output says so in
        // a block of its own, after the page's blocks.
        if layer.damaged == true {
            doubts.append(Doubt(kind: .lowQuality, reason: damagedReason, blocks: []))
        }
        let unsure = layer.unsure ?? []
        let status: PageQuality.Status = !doubts.isEmpty ? .lowQuality : unsure.isEmpty ? .ok : .unsure
        return PageQuality(status: status, doubts: doubts, unsure: unsure)
    }
}

/// What the verdict reads of a page's text layer. The cache stores it beside the layer, so a
/// listing of many files judges their pages without decoding a layer (`Store.verdicts`).
public struct PageMeasures: Codable, Equatable, Sendable {
    public var layerScore: Double?
    public var spacesLost: Bool?
    public var checkFailed: Bool?
    public var agreement: Double?
    /// Each block's agreement, in block order, where OCR's two readings were compared block by
    /// block.
    public var blockAgreements: [Double?]?
    public var unsure: [Unsure]?
    /// How many places the page draws text that PDFKit left out.
    public var unread: Int?
    /// One of the page's content streams could not be decoded.
    public var damaged: Bool?

    public init() {}

    public init(_ layer: PageText) {
        layerScore = layer.layerScore
        spacesLost = layer.spacesLost
        checkFailed = layer.checkFailed
        agreement = layer.agreement
        let blocks = layer.blocks.map(\.agreement)
        blockAgreements = blocks.contains { $0 != nil } ? blocks : nil
        // Words inside a figure, a table or an equation go aside with its text, which the agent
        // reads from the image: their doubt flags no page.
        let inside = Set((layer.regions ?? []).flatMap { region in region.blocks.filter { !region.caption.contains($0) } })
        let spans = (layer.unsure ?? []).filter { !inside.contains($0.block) }
        unsure = spans.isEmpty ? nil : spans
        unread = layer.unread.map(\.count)
        damaged = layer.damaged
    }

    /// The measures as the cache stores them.
    var stored: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Measures as the cache stored them: "{}" for a page with nothing to note, the most common,
    /// and an empty string for a layer that could not be read.
    static func decode(_ stored: String) -> PageMeasures? {
        if stored == "{}" { return PageMeasures() }
        return try? JSONDecoder().decode(PageMeasures.self, from: Data(stored.utf8))
    }
}
