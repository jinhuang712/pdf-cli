import CoreGraphics
import Foundation
import NaturalLanguage
import PDFKit
import Vision

/// The space repair for a file at risk (DESIGNS.md → Decision: Apple OCR word breaks over
/// PDFium for fonts that hide spaces). PDFKit's characters stay; Apple OCR reads the rendered
/// page, and only its word breaks are taken, where the two texts agree on the characters
/// around them.
enum SpaceRepair {
    /// Where OCR breaks words that PDFKit runs together, as UTF-16 offsets in `page.string`
    /// before which a space belongs.
    struct Breaks: Equatable {
        /// Breaks inside runs where both texts agree. The repair applies them.
        var spaces: Set<Int> = []
        /// Breaks at the first character of a run, just after the texts disagree. The alignment
        /// there may be off by a character, so these go to the agent as a second reading.
        var unsure: Set<Int> = []
    }

    /// Nil when OCR could not read the page.
    static func breaks(_ page: PDFPage) async -> Breaks? {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let image = OCR.render(page, dpi: 200) else { return nil }
        let rendered = DispatchTime.now().uptimeNanoseconds
        guard let paragraphs = await OCR.recognize(image) else { return nil }
        let recognized = DispatchTime.now().uptimeNanoseconds
        let breaks = align(kit: page.string ?? "", ocr: paragraphs.map(\.text).joined(separator: "\n"))
        let aligned = DispatchTime.now().uptimeNanoseconds
        Env.log("space repair: render \((rendered - start) / 1_000_000) ms, OCR \((recognized - rendered) / 1_000_000) ms, "
                + "align \((aligned - recognized) / 1_000_000) ms, \(breaks.spaces.count) spaces, \(breaks.unsure.count) unsure")
        return breaks
    }

    /// Finds where OCR puts a space that PDFKit lacks. The two texts are aligned character by
    /// character, whitespace left out. A space counts only inside a run where both sides agree:
    /// the first character of a run has no reliable neighbour, as the spike's method had it.
    static func align(kit: String, ocr: String) -> Breaks {
        var kitScalars: [Unicode.Scalar] = []
        var kitOffsets: [Int] = []
        var kitGap: [Bool] = []
        var offset = 0
        var gap = false
        for scalar in kit.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
            } else {
                kitScalars.append(scalar)
                kitOffsets.append(offset)
                kitGap.append(gap)
                gap = false
            }
            offset += scalar.utf16.count
        }
        var ocrScalars: [Unicode.Scalar] = []
        var ocrGap: [Bool] = []
        gap = false
        for scalar in ocr.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
            } else {
                ocrScalars.append(scalar)
                ocrGap.append(gap)
                gap = false
            }
        }

        var removed = Set<Int>(), inserted = Set<Int>()
        for change in ocrScalars.difference(from: kitScalars) {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var breaks = Breaks()
        var i = 0, j = 0
        var inRun = false
        while i < kitScalars.count, j < ocrScalars.count {
            if removed.contains(i) {
                i += 1
                inRun = false
            } else if inserted.contains(j) {
                j += 1
                inRun = false
            } else {
                if ocrGap[j], !kitGap[i] {
                    if inRun { breaks.spaces.insert(kitOffsets[i]) } else { breaks.unsure.insert(kitOffsets[i]) }
                }
                inRun = true
                i += 1
                j += 1
            }
        }
        relocate(&breaks, kit: (kitScalars, kitOffsets, kitGap), ocr: (ocrScalars, ocrGap))
        return breaks
    }

    /// Repairs words still run together that the alignment left unmatched, as when PDFKit and
    /// OCR read a line in a different order. A word whose letters, more than 25 in a row, occur
    /// exactly once in OCR's text takes OCR's breaks from there.
    static func relocate(_ breaks: inout Breaks, kit: ([Unicode.Scalar], [Int], [Bool]), ocr: ([Unicode.Scalar], [Bool])) {
        let (scalars, offsets, gaps) = kit
        let (ocrScalars, ocrGaps) = ocr
        func latin(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) }
        var start = 0
        while start < scalars.count {
            var end = start + 1
            while end < scalars.count && !gaps[end] && !breaks.spaces.contains(offsets[end]) { end += 1 }
            defer { start = end }
            let word = Array(scalars[start..<end])
            var run = 0, longest = 0
            for scalar in word {
                run = latin(scalar) ? run + 1 : 0
                longest = max(longest, run)
            }
            guard longest > 25, word.count <= ocrScalars.count else { continue }
            var found: [Int] = []
            for position in 0...(ocrScalars.count - word.count) where ocrScalars[position] == word[0] {
                if ocrScalars[position..<position + word.count].elementsEqual(word) { found.append(position) }
                if found.count > 1 { break }
            }
            guard found.count == 1, let position = found.first else { continue }
            for k in 1..<word.count where ocrGaps[position + k] {
                breaks.spaces.insert(offsets[start + k])
                breaks.unsure.remove(offsets[start + k])
            }
        }
    }

    /// The words that a second reading, with the unsure breaks applied too, splits apart: each
    /// becomes an unsure span for the agent to pick from (DESIGNS.md → Principles → Failure).
    /// `relaxed` is the same page read with every break, so its blocks match `strict`'s.
    ///
    /// Most unsure breaks are wrong, a character off after a misread, as in "T able", so a
    /// break counts only where macOS's word list backs it (see `supported`).
    static func unsureSpans(strict: PageText, relaxed: PageText) -> [Unsure] {
        guard strict.blocks.count == relaxed.blocks.count else { return [] }
        var spans: [Unsure] = []
        for (index, (block, other)) in zip(strict.blocks, relaxed.blocks).enumerated() where block.text != other.text {
            var pieces = other.text.split(separator: " ")[...]
            var offset = 0
            for word in block.text.split(separator: " ", omittingEmptySubsequences: false) {
                defer { offset += word.utf16.count + 1 }
                // The relaxed reading only adds spaces, so its pieces join back into this word.
                var joined = "", parts: [Substring] = []
                while joined.count < word.count, let piece = pieces.popFirst() {
                    joined += piece
                    parts.append(piece)
                }
                guard joined == word else { break }
                guard parts.count > 1 else { continue }
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                guard !trimmed.isEmpty, let range = word.range(of: trimmed) else { continue }
                // Where the relaxed reading breaks the word, counted inside the trimmed word.
                let lead = word.distance(from: word.startIndex, to: range.lowerBound)
                let letters = Array(trimmed)
                var cut = 0
                let cuts = Set(parts.dropLast().map { part -> Int in
                    cut += part.count
                    return cut - lead
                }.filter { $0 > 0 && $0 < letters.count && supported(letters, cut: $0) })
                guard !cuts.isEmpty else { continue }
                var split = ""
                for (position, character) in trimmed.enumerated() {
                    if cuts.contains(position) { split += " " }
                    split.append(character)
                }
                let start = offset + word[..<range.lowerBound].utf16.count
                let line = block.lines.first { $0.text.contains(trimmed) }
                spans.append(Unsure(block: index, offset: start, readings: [trimmed, split], box: line?.box ?? block.box))
            }
        }
        return spans
    }

    /// Whether macOS's word list backs a break before `cut` in `word`:
    /// - between two Latin letters, the letters around it form no word of their own, and the
    ///   letters on each side do, as "overall" and "shift" in "overallshift";
    /// - between a Latin letter and another letter, such as a maths symbol in "𝑁test", the
    ///   Latin letters on their side form a word.
    ///
    /// The list holds English only, so text in other languages gets no second reading.
    static func supported(_ word: [Character], cut: Int) -> Bool {
        func latin(_ character: Character) -> Bool { character.isASCII && character.isLetter }
        let left = word[cut - 1], right = word[cut]
        guard latin(left) || latin(right) else { return false }
        var start = cut, end = cut
        if latin(left) { while start > 0 && latin(word[start - 1]) { start -= 1 } }
        if latin(right) { while end < word.count && latin(word[end]) { end += 1 } }
        let before = String(word[start..<cut]), after = String(word[cut..<end])
        if latin(left) && latin(right) {
            return !wordLike(before + after) && wordLike(before) && wordLike(after)
        }
        if !left.isLetter || !right.isLetter { return false }
        return wordLike(latin(left) ? before : after)
    }

    /// Second readings for words that both PDFKit and OCR run together, as in
    /// "singledatasetperconditionandshouldbetreated": each run of Latin letters in such a word
    /// that is no word itself is split into common words (see `segment`). Words that the space
    /// repair already offers a reading for are left out.
    static func splitSpans(_ page: PageText, besides existing: [Unsure]) -> [Unsure] {
        var spans: [Unsure] = []
        for (index, block) in page.blocks.enumerated() {
            var offset = 0
            for word in block.text.split(separator: " ", omittingEmptySubsequences: false) {
                defer { offset += word.utf16.count + 1 }
                guard TextCleanup.runTogetherWords(String(word)) > 0 else { continue }
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                guard let range = word.range(of: trimmed) else { continue }
                let start = offset + word[..<range.lowerBound].utf16.count
                guard !existing.contains(where: { $0.block == index && $0.offset == start }) else { continue }
                var split = "", run = ""
                func flush() {
                    if run.count > 1, !wordLike(run), let words = segment(run), words.count > 1 {
                        split += words.joined(separator: " ")
                    } else {
                        split += run
                    }
                    run = ""
                }
                for character in trimmed {
                    if character.isASCII && character.isLetter {
                        run.append(character)
                    } else {
                        flush()
                        split.append(character)
                    }
                }
                flush()
                guard split != trimmed else { continue }
                let line = block.lines.first { $0.text.contains(trimmed) }
                spans.append(Unsure(block: index, offset: start, readings: [trimmed, split], box: line?.box ?? block.box))
            }
        }
        return spans
    }

    /// Common English words, from the word embedding macOS ships: about 57,000 words. The word
    /// list holds rare words too, such as "sare" and "ora", which split "datasetsare" wrongly.
    nonisolated(unsafe) static let common: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)

    /// Splits a run of Latin letters into the fewest words that are common, acronyms such as
    /// "TREND", or capitalised names in the word list. Among those, it prefers splits that leave
    /// a capital before small letters to start the next word, as in "EN Emotion" over
    /// "ENE motion", then the fewest words of two letters or less. Nil when no split covers
    /// every letter.
    static func segment(_ run: String) -> [String]? {
        guard let common else { return nil }
        let letters = Array(run)
        let count = letters.count
        guard count > 0 else { return nil }
        func fits(_ word: String) -> Bool {
            if common.contains(word.lowercased()) { return true }
            if word.count >= 2 && word.allSatisfy({ $0.isUppercase }) { return true }
            return word.count >= 3 && word.first!.isUppercase && Dehyphenator.known(word)
        }
        // best[i]: the split of the first i letters, as (words, capitals taken from the next
        // word, short words, start of the last word).
        var best: [(words: Int, taken: Int, short: Int, from: Int)?] = Array(repeating: nil, count: count + 1)
        best[0] = (0, 0, 0, 0)
        for end in 1...count {
            let takes = end < count && letters[end - 1].isUppercase && letters[end].isLowercase ? 1 : 0
            for start in max(0, end - 24)..<end {
                guard let before = best[start], fits(String(letters[start..<end])) else { continue }
                let candidate = (words: before.words + 1, taken: before.taken + takes,
                                 short: before.short + (end - start <= 2 ? 1 : 0), from: start)
                if let current = best[end],
                   (current.words, current.taken, current.short) <= (candidate.words, candidate.taken, candidate.short) { continue }
                best[end] = candidate
            }
        }
        guard best[count] != nil else { return nil }
        var words: [String] = []
        var end = count
        while end > 0, let step = best[end] {
            words.insert(String(letters[step.from..<end]), at: 0)
            end = step.from
        }
        return words
    }

    /// A word in macOS's word list, two letters or longer, or an acronym such as "CTRL" or "LLMs".
    static func wordLike(_ text: String) -> Bool {
        guard text.count >= 2 else { return false }
        let capitals = text.hasSuffix("s") ? text.dropLast() : text[...]
        if capitals.count >= 2 && capitals.allSatisfy({ $0.isUppercase }) { return true }
        return Dehyphenator.known(text)
    }
}
