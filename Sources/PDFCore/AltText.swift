import CoreGraphics
import Foundation

/// A picture's alternate text: the words a tagged PDF gives for readers who cannot see it, in
/// its structure tree (FEATURES.md → F3). A reader of the page never sees them, so they are
/// hidden text: `pdf read` counts them and shows them only with `--show hidden`, labelled,
/// as a stamp's name stays out since M1.14 (DESIGNS.md → Decision: a marker in place of hidden
/// text over its words with a label).
///
/// The page's marked content numbers what it draws (`Drawing.contentMarks`); the structure
/// tree's parent tree maps each number on the page to its element, whose `/Alt`, or its
/// nearest parent's, is the text.
enum AltText {
    /// At most this many characters of one picture's text.
    static let limit = 1_000

    /// The alternate text of each marked-content ID on the page that has one.
    static func lookup(_ page: CGPDFPage, ids: Set<Int>) -> [Int: String] {
        guard !ids.isEmpty, let dictionary = page.dictionary else { return [:] }
        return alts(dictionary, catalog: page.document?.catalog, ids: ids)
    }

    /// What the parse can read of the structure tree for a page, for its cache key
    /// (`PageKeyer`): the alternate text of every ID on it, so a file that gains alt text, or
    /// another file with the same page, is parsed again.
    static func digest(_ dictionary: CGPDFDictionaryRef, catalog: CGPDFDictionaryRef?) -> String {
        var parents: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "StructParents", &parents) else { return "none" }
        let found = alts(dictionary, catalog: catalog, ids: nil).sorted { $0.key < $1.key }
        return "parents \(parents)" + found.map { "\u{0}\($0.key) \($0.value)" }.joined()
    }

    /// The alternate text of each ID in `ids` that has one, or of every ID on the page, at most
    /// 10,000, with `ids` nil.
    static func alts(_ dictionary: CGPDFDictionaryRef, catalog: CGPDFDictionaryRef?, ids: Set<Int>?) -> [Int: String] {
        guard let catalog else { return [:] }
        var seen = Set<CGPDFDictionaryRef>()
        var parents: CGPDFInteger = 0
        var root: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetInteger(dictionary, "StructParents", &parents),
              CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &root), let root,
              CGPDFDictionaryGetDictionary(root, "ParentTree", &tree), let tree,
              let elements = entry(tree, key: Int(parents), seen: &seen)
        else { return [:] }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(elements, .array, &array), let array else { return [:] }
        var found: [Int: String] = [:]
        let all = 0..<min(CGPDFArrayGetCount(array), 10_000)
        for id in ids.map({ $0.filter { all.contains($0) }.sorted() }) ?? Array(all) {
            var element: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, id, &element), var current = element else { continue }
            // The element's own text, or its nearest parent's, as a figure whose parts are each
            // marked.
            for _ in 0..<8 {
                var alt: CGPDFStringRef?
                if CGPDFDictionaryGetString(current, "Alt", &alt), let alt, let text = CGPDFStringCopyTextString(alt) as String? {
                    let clean = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
                        .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                    let words = String(String.UnicodeScalarView(clean))
                    if !words.isEmpty { found[id] = words.count > limit ? String(words.prefix(limit)) + "…" : words }
                    break
                }
                var parent: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(current, "P", &parent), let parent, parent != root else { break }
                current = parent
            }
        }
        return found
    }

    /// A number tree's value for a key: its `/Nums`, or the kid whose `/Limits` hold the key, at
    /// most 32 levels down, each node once, 10,000 nodes at most: a node listed as its own kid
    /// twice would otherwise take 2^32 visits.
    static func entry(_ node: CGPDFDictionaryRef, key: Int, depth: Int = 0, seen: inout Set<CGPDFDictionaryRef>) -> CGPDFObjectRef? {
        guard depth < 32, seen.count < 10_000, seen.insert(node).inserted else { return nil }
        var nums: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Nums", &nums), let nums {
            let count = CGPDFArrayGetCount(nums)
            var index = 0
            while index + 1 < count && index < 200_000 {
                var number: CGPDFInteger = 0
                if CGPDFArrayGetInteger(nums, index, &number), Int(number) == key {
                    var value: CGPDFObjectRef?
                    return CGPDFArrayGetObject(nums, index + 1, &value) ? value : nil
                }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(node, "Kids", &kids), let kids else { return nil }
        for index in 0..<min(CGPDFArrayGetCount(kids), 10_000) {
            var kid: CGPDFDictionaryRef?, limits: CGPDFArrayRef?
            guard CGPDFArrayGetDictionary(kids, index, &kid), let kid else { continue }
            var low: CGPDFInteger = 0, high: CGPDFInteger = 0
            if CGPDFDictionaryGetArray(kid, "Limits", &limits), let limits, CGPDFArrayGetInteger(limits, 0, &low),
               CGPDFArrayGetInteger(limits, 1, &high), key < Int(low) || key > Int(high) {
                continue
            }
            if let found = entry(kid, key: key, depth: depth + 1, seen: &seen) { return found }
            if seen.count >= 10_000 { return nil }
        }
        return nil
    }
}
