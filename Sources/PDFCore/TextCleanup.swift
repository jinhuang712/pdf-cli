import Foundation

/// Cleans one line of PDFKit text: ligatures spelled out, invisible and control characters
/// removed, every kind of space made plain, and accents composed.
enum TextCleanup {
    static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
        "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]

    /// Characters that draw nothing and only get in the way of search: the zero-width space,
    /// the word joiner, the byte-order mark, and the noncharacters U+FFFE and U+FFFF.
    static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{FFFE}", "\u{FFFF}"]

    static func line(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            if let spelled = ligatures[character] {
                out += spelled
                continue
            }
            for scalar in character.unicodeScalars {
                switch scalar.properties.generalCategory {
                case .spaceSeparator:
                    out.unicodeScalars.append(" ")
                case .control:
                    if scalar == "\t" { out.unicodeScalars.append(" ") }
                case .format where scalar == "\u{00AD}":
                    // A soft hyphen inside a line marks a place a word may break. It is not text.
                    break
                default:
                    if !invisible.contains(scalar) { out.unicodeScalars.append(scalar) }
                }
            }
        }
        let composed = out.precomposedStringWithCanonicalMapping
        return composed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Letter runs longer than 25 characters: words that ran together because spaces were
    /// lost (DESIGNS.md → Principles → Silent errors).
    static func runTogetherWords(_ text: String) -> Int {
        var count = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) {
                run += 1
            } else {
                if run > 25 { count += 1 }
                run = 0
            }
        }
        if run > 25 { count += 1 }
        return count
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Decides whether a hyphen at the end of a line splits one word, as in "exam-" + "ple", or
/// belongs to a hyphenated word, as in "self-" + "attention". When in doubt the hyphen stays:
/// "data-set" is still readable, and a wrongly joined word is not.
struct Dehyphenator {
    /// macOS's word list, about 236,000 English words without most inflections, held as
    /// hashes of the lowercased words. Hashes load in a few milliseconds, where a set of
    /// strings took about 140 ms in every worker.
    static let dictionary: Set<UInt64> = {
        guard let data = FileManager.default.contents(atPath: "/usr/share/dict/words") else { return [] }
        var hashes = Set<UInt64>(minimumCapacity: 240_000)
        var hash = fnvOffset
        var empty = true
        for byte in data {
            if byte == 0x0A {
                if !empty { hashes.insert(hash) }
                hash = fnvOffset
                empty = true
            } else {
                hash = (hash ^ UInt64(lowercased(byte))) &* fnvPrime
                empty = false
            }
        }
        if !empty { hashes.insert(hash) }
        return hashes
    }()

    static let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    /// The word list holds ASCII words only, so a word with other letters is never in it.
    static func hash(_ word: String) -> UInt64? {
        var hash = fnvOffset
        for byte in word.utf8 {
            guard byte < 0x80 else { return nil }
            hash = (hash ^ UInt64(lowercased(byte))) &* fnvPrime
        }
        return hash
    }

    static func inDictionary(_ word: String) -> Bool {
        hash(word).map { dictionary.contains($0) } ?? false
    }

    /// Words the page itself spells without a hyphen.
    let pageWords: Set<String>

    init(pageText: String) {
        pageWords = Set(pageText.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() })
    }

    /// True when "left-" at a line's end and "right" at the next line's start form one word.
    func joins(_ left: Substring, _ right: Substring) -> Bool {
        guard let first = right.first, first.isLowercase, let last = left.last, last.isLetter else { return false }
        let leftWord = left.reversed().prefix { $0.isLetter }.reversed()
        let rightWord = right.prefix { $0.isLetter }
        let joined = (String(leftWord) + rightWord).lowercased()
        if pageWords.contains(joined) { return true }
        if pageWords.contains(String(leftWord).lowercased() + "-" + rightWord.lowercased()) { return false }
        return Dehyphenator.known(joined)
    }

    /// A word in the dictionary, allowing the common English endings the list leaves out.
    static func known(_ word: String) -> Bool {
        if inDictionary(word) { return true }
        for (suffix, replacements) in [("s", [""]), ("es", [""]), ("ed", ["", "e"]), ("ing", ["", "e"]),
                                       ("ly", [""]), ("ies", ["y"]), ("ied", ["y"]), ("er", ["", "e"])] {
            guard word.hasSuffix(suffix), word.count > suffix.count + 2 else { continue }
            let stem = String(word.dropLast(suffix.count))
            if replacements.contains(where: { inDictionary(stem + $0) }) { return true }
        }
        return false
    }
}
