import CoreGraphics
import Foundation

/// A picture's alternate text: the words a tagged PDF gives for readers who cannot see it, in
/// its structure tree (FEATURES.md → F3). A reader of the page never sees them, so they are
/// hidden text: `pdf read` counts them and shows them only with `--include-hidden`, labelled,
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
        guard !ids.isEmpty, let dictionary = page.dictionary, let catalog = page.document?.catalog else { return [:] }
        var parents: CGPDFInteger = 0
        var root: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetInteger(dictionary, "StructParents", &parents),
              CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &root), let root,
              CGPDFDictionaryGetDictionary(root, "ParentTree", &tree), let tree,
              let elements = entry(tree, key: Int(parents))
        else { return [:] }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(elements, .array, &array), let array else { return [:] }
        var found: [Int: String] = [:]
        for id in ids where id >= 0 && id < CGPDFArrayGetCount(array) {
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
    /// most 32 levels down.
    static func entry(_ node: CGPDFDictionaryRef, key: Int, depth: Int = 0) -> CGPDFObjectRef? {
        guard depth < 32 else { return nil }
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
            if let found = entry(kid, key: key, depth: depth + 1) { return found }
        }
        return nil
    }
}
