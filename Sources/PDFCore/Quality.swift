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
    public static func judge(_ result: PageResult) -> PageQuality {
        guard result.status == .ok else {
            return PageQuality(status: .failed, doubts: [Doubt(kind: .failed, reason: result.reason, blocks: nil)], unsure: [])
        }
        guard let layer = result.pageText else {
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
            for (index, block) in layer.blocks.enumerated() {
                guard let agreement = block.agreement, agreement < OCR.agreementThreshold else { continue }
                doubts.append(Doubt(kind: .lowQuality, reason: "two OCR readings of this block disagree",
                                    score: agreement, blocks: [index]))
            }
        }
        let unsure = layer.unsure ?? []
        let status: PageQuality.Status = !doubts.isEmpty ? .lowQuality : unsure.isEmpty ? .ok : .unsure
        return PageQuality(status: status, doubts: doubts, unsure: unsure)
    }
}
