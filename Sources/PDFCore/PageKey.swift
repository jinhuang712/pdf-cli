import CoreGraphics
import CryptoKit
import Foundation

enum Hashing {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256 {
    /// Adds a length before the bytes, so two different sequences never hash alike.
    mutating func add(_ string: String) {
        add(Data(string.utf8))
    }

    mutating func add(_ data: Data) {
        var length = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &length) { update(bufferPointer: $0) }
        update(data: data)
    }

    mutating func add(_ digest: SHA256.Digest) {
        add(Data(digest))
    }
}

/// Hashes what a page draws: its boxes, its rotation, its content streams and the resources
/// they use, such as fonts and images, and the alt text the file's structure tree gives what it
/// draws (`AltText`). Annotations, such as highlights and comments, stay out, so adding one
/// leaves the key unchanged (DESIGNS.md → Principles → Cache).
///
/// One keyer serves one document. It remembers the hash of each shared object, such as a font
/// that every page uses, so the object is read once.
struct PageKeyer {
    static let version = "pdf-cli page key 2"
    /// Bounds the work on a hostile file whose objects nest without end.
    static let nodeBudget = 2_000_000
    static let maxDepth = 64

    /// The document's catalog, which holds its structure tree.
    private let catalog: CGPDFDictionaryRef?
    private var memo: [UnsafeRawPointer: SHA256.Digest] = [:]
    private var active: Set<UnsafeRawPointer> = []
    private var budget = 0
    /// How many times a hash was cut short by the budget, the depth limit or a loop. Such a
    /// hash depends on reading order, so it is never remembered.
    private var cuts = 0

    init(catalog: CGPDFDictionaryRef? = nil) {
        self.catalog = catalog
    }

    mutating func key(for page: CGPDFPage) -> String {
        key(PageGeometry(page), page.dictionary)
    }

    /// The key of the page whose dictionary is `dictionary`, the same as `key(for:)` gives the
    /// page, or nil where its boxes or rotation take CGPDF to read (`PageGeometry`).
    mutating func key(forDictionary dictionary: CGPDFDictionaryRef) -> String? {
        PageGeometry(dictionary: dictionary).map { key($0, dictionary) }
    }

    private mutating func key(_ geometry: PageGeometry, _ dictionary: CGPDFDictionaryRef?) -> String {
        budget = PageKeyer.nodeBudget
        var hasher = SHA256()
        hasher.add(PageKeyer.version)
        for rect in [geometry.mediaBox, geometry.cropBox] {
            for value in [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height] {
                hasher.add(String(Double(value).bitPattern))
            }
        }
        hasher.add("rotate \(geometry.rotation)")
        guard let dictionary else {
            hasher.add("no dictionary")
            return Hashing.hex(hasher.finalize())
        }
        for name in ["Contents", "Group", "UserUnit"] {
            hasher.add(name)
            if let object = PageKeyer.object(dictionary, name) {
                feed(object, into: &hasher, depth: 0)
            }
        }
        hasher.add("Resources")
        if let resources = PageKeyer.inherited(dictionary, "Resources") {
            feed(resources, into: &hasher, depth: 0)
        }
        hasher.add("Structure")
        hasher.add(AltText.digest(dictionary, catalog: catalog))
        return Hashing.hex(hasher.finalize())
    }

    static func object(_ dictionary: CGPDFDictionaryRef, _ name: String) -> CGPDFObjectRef? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, name, &object) else { return nil }
        return object
    }

    /// A page can take its resources from the page tree above it.
    static func inherited(_ dictionary: CGPDFDictionaryRef, _ name: String) -> CGPDFObjectRef? {
        var current: CGPDFDictionaryRef? = dictionary
        for _ in 0..<32 {
            guard let node = current else { return nil }
            if let object = object(node, name) { return object }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(node, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    private mutating func feed(_ object: CGPDFObjectRef, into hasher: inout SHA256, depth: Int) {
        budget -= 1
        guard budget >= 0 else { cut("budget", into: &hasher); return }
        guard depth <= PageKeyer.maxDepth else { cut("deep", into: &hasher); return }
        let type = CGPDFObjectGetType(object)
        switch type {
        case .null:
            hasher.add("null")
        case .boolean:
            var value: CGPDFBoolean = 0
            _ = CGPDFObjectGetValue(object, type, &value)
            hasher.add("bool \(value)")
        case .integer:
            var value: CGPDFInteger = 0
            _ = CGPDFObjectGetValue(object, type, &value)
            hasher.add("int \(value)")
        case .real:
            var value: CGPDFReal = 0
            _ = CGPDFObjectGetValue(object, type, &value)
            hasher.add("real \(Double(value).bitPattern)")
        case .name:
            var value: UnsafePointer<CChar>?
            _ = CGPDFObjectGetValue(object, type, &value)
            hasher.add("name")
            hasher.add(value.map { Data(bytes: $0, count: strlen($0)) } ?? Data())
        case .string:
            var value: CGPDFStringRef?
            _ = CGPDFObjectGetValue(object, type, &value)
            hasher.add("string")
            if let value, let bytes = CGPDFStringGetBytePtr(value) {
                hasher.add(Data(bytes: bytes, count: CGPDFStringGetLength(value)))
            }
        case .array:
            var array: CGPDFArrayRef?
            _ = CGPDFObjectGetValue(object, type, &array)
            guard let array else { hasher.add("missing"); return }
            let identity = UnsafeRawPointer(array.rawValue)
            guard !reuse(identity, into: &hasher) else { return }
            let cutsBefore = cuts
            var inner = SHA256()
            feedArray(array, into: &inner, depth: depth + 1)
            finish(identity, inner, cutsBefore: cutsBefore, into: &hasher)
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            _ = CGPDFObjectGetValue(object, type, &dictionary)
            guard let dictionary else { hasher.add("missing"); return }
            let identity = UnsafeRawPointer(dictionary.rawValue)
            guard !reuse(identity, into: &hasher) else { return }
            let cutsBefore = cuts
            var inner = SHA256()
            feedDictionary(dictionary, into: &inner, depth: depth + 1)
            finish(identity, inner, cutsBefore: cutsBefore, into: &hasher)
        case .stream:
            var stream: CGPDFStreamRef?
            _ = CGPDFObjectGetValue(object, type, &stream)
            guard let stream else { hasher.add("missing"); return }
            let identity = UnsafeRawPointer(stream.rawValue)
            guard !reuse(identity, into: &hasher) else { return }
            let cutsBefore = cuts
            var inner = SHA256()
            feedStream(stream, into: &inner, depth: depth + 1)
            finish(identity, inner, cutsBefore: cutsBefore, into: &hasher)
        @unknown default:
            hasher.add("unknown")
        }
    }

    /// Adds a remembered object's hash, or marks a loop back to an object still being read.
    /// Returns false when the object must be read now; it is then marked as being read.
    private mutating func reuse(_ identity: UnsafeRawPointer, into hasher: inout SHA256) -> Bool {
        if let digest = memo[identity] {
            hasher.add(digest)
            return true
        }
        if active.contains(identity) {
            cut("cycle", into: &hasher)
            return true
        }
        active.insert(identity)
        return false
    }

    private mutating func finish(_ identity: UnsafeRawPointer, _ inner: SHA256, cutsBefore: Int,
                                 into hasher: inout SHA256) {
        active.remove(identity)
        let digest = inner.finalize()
        if cuts == cutsBefore { memo[identity] = digest }
        hasher.add(digest)
    }

    private mutating func cut(_ marker: String, into hasher: inout SHA256) {
        cuts += 1
        hasher.add(marker)
    }

    private mutating func feedArray(_ array: CGPDFArrayRef, into hasher: inout SHA256, depth: Int) {
        let count = CGPDFArrayGetCount(array)
        hasher.add("array \(count)")
        for index in 0..<count {
            var element: CGPDFObjectRef?
            if CGPDFArrayGetObject(array, index, &element), let element {
                feed(element, into: &hasher, depth: depth)
            } else {
                hasher.add("missing")
            }
        }
    }

    private mutating func feedDictionary(_ dictionary: CGPDFDictionaryRef, into hasher: inout SHA256, depth: Int) {
        // Keys are compared as bytes: a name need not be valid UTF-8.
        var entries: [(Data, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            entries.append((Data(bytes: key, count: strlen(key)), value))
            return true
        }, nil)
        entries.sort { $0.0.lexicographicallyPrecedes($1.0) }
        hasher.add("dictionary \(entries.count)")
        for (key, value) in entries {
            hasher.add(key)
            feed(value, into: &hasher, depth: depth)
        }
    }

    private mutating func feedStream(_ stream: CGPDFStreamRef, into hasher: inout SHA256, depth: Int) {
        hasher.add("stream")
        if let dictionary = CGPDFStreamGetDictionary(stream) {
            feedDictionary(dictionary, into: &hasher, depth: depth)
        }
        var format = CGPDFDataFormat.raw
        if let data = CGPDFStreamCopyData(stream, &format) {
            hasher.add("data \(format.rawValue)")
            hasher.add(data as Data)
        } else {
            hasher.add("no data")
        }
    }
}
