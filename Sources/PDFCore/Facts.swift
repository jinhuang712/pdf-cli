import CoreGraphics
import Foundation
import PDFKit

/// What a file states about itself beyond its pages' text: its metadata, its outline and page
/// labels, its comments, highlights and form fields, and the files and scripts it carries. These
/// live in the file's catalog and annotations, not in what its pages draw, so they are kept per
/// file, with its entry, apart from the pages' results (DESIGNS.md → Principles → Cache).
public struct FileFacts: Codable, Equatable, Sendable {
    /// An entry of the file's outline, its bookmarks.
    public struct Section: Codable, Equatable, Sendable {
        public var title: String
        /// 1 for a top-level entry.
        public var level: Int
        /// Counted from 0.
        public var page: Int
        /// Where the section starts on its page, as fractions from the top and from the left,
        /// when the bookmark says.
        public var top: Double?
        public var left: Double? = nil
    }

    /// A file the PDF carries.
    public struct Attachment: Codable, Equatable, Sendable {
        public var name: String
        public var size: Int?
        /// The page whose annotation holds it, counted from 0, or nil for the document's own.
        public var page: Int?
    }

    /// A script or a program launch the PDF holds. None of them runs (DESIGNS.md → Principles →
    /// Safety).
    public struct Script: Codable, Equatable, Sendable {
        /// What would start it, such as "document open" or "field keystroke".
        public var trigger: String
        /// "JavaScript", or "Launch" for an action that starts a program or opens a file.
        public var kind: String
        /// The page it belongs to, counted from 0, or nil for the document's own.
        public var page: Int?
        /// The script's length in characters, or the launched file's name.
        public var detail: String
    }

    public var author: String?
    /// The year the file was made, from its metadata.
    public var year: String?
    public var outline: [Section] = []
    /// The number printed on each page, when the file's page labels differ from the pages'
    /// positions. Nil when they do not.
    public var labels: [String]?
    public var comments = 0
    public var highlights = 0
    public var formFields = 0
    public var filledFields = 0
    public var attachments: [Attachment] = []
    public var scripts: [Script] = []

    public init() {}

    /// Adds what one page holds.
    mutating func merge(_ page: FileFacts) {
        comments += page.comments
        highlights += page.highlights
        formFields += page.formFields
        filledFields += page.filledFields
        attachments += page.attachments
        scripts += page.scripts
    }
}

/// Reads a file's facts. A worker runs it, since it opens PDF content. Every walk through the
/// file's dictionaries has a depth and a count limit, so a hostile file cannot make it loop.
enum FactReader {
    static let maxItems = 2_000
    static let maxDepth = 12

    /// The facts the catalog and the information dictionary hold: metadata, the document's
    /// attachments and its scripts. The outline and the page labels come from PDFKit.
    static func document(_ document: CGPDFDocument, url: URL) -> FileFacts {
        var facts = FileFacts()
        if let info = document.info {
            facts.author = string(info, "Author").map(TextCleanup.line).flatMap { $0.isEmpty ? nil : $0 }
            if let created = string(info, "CreationDate") ?? string(info, "ModDate"),
               let match = created.range(of: #"(19|20)\d\d"#, options: .regularExpression) {
                facts.year = String(created[match])
            }
        }
        if let catalog = document.catalog {
            var names: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
                var tree: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &tree), let tree {
                    walkNameTree(tree) { name, value in
                        var spec: CGPDFDictionaryRef?
                        guard CGPDFObjectGetValue(value, .dictionary, &spec), let spec else { return }
                        facts.attachments.append(attachment(spec, fallback: name, page: nil))
                    }
                }
                if CGPDFDictionaryGetDictionary(names, "JavaScript", &tree), let tree {
                    walkNameTree(tree) { _, value in
                        var action: CGPDFDictionaryRef?
                        guard CGPDFObjectGetValue(value, .dictionary, &action), let action else { return }
                        facts.scripts += scripts(in: action, trigger: "document open", page: nil)
                    }
                }
            }
            var open: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "OpenAction", &open), let open {
                facts.scripts += scripts(in: open, trigger: "document open", page: nil)
            }
            facts.scripts += additionalActions(catalog, page: nil, triggers: [
                "WC": "document close", "WS": "before save", "DS": "after save", "WP": "before print", "DP": "after print",
            ])
        }
        if let pdf = PDFDocument(url: url), OpenFailure.unlock(pdf) {
            facts.outline = outline(pdf)
            facts.labels = labels(pdf)
        }
        return facts
    }

    /// The facts one page's annotations hold.
    static func page(_ page: CGPDFPage, index: Int) -> FileFacts {
        var facts = FileFacts()
        guard let dictionary = page.dictionary else { return facts }
        facts.scripts += additionalActions(dictionary, page: index, triggers: ["O": "page open", "C": "page close"])
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return facts }
        for position in 0..<min(CGPDFArrayGetCount(annotations), maxItems) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation else { continue }
            switch name(annotation, "Subtype") ?? "" {
            case "Text", "FreeText":
                facts.comments += 1
            case "Highlight", "Underline", "Squiggly", "StrikeOut":
                facts.highlights += 1
            case "Widget":
                facts.formFields += 1
                if filled(annotation) { facts.filledFields += 1 }
            case "FileAttachment":
                var spec: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(annotation, "FS", &spec), let spec {
                    facts.attachments.append(attachment(spec, fallback: "attachment", page: index))
                }
            default:
                break
            }
            var action: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(annotation, "A", &action), let action {
                facts.scripts += scripts(in: action, trigger: "link click", page: index)
            }
            facts.scripts += additionalActions(annotation, page: index, triggers: [
                "K": "field keystroke", "F": "field format", "V": "field change", "C": "field calculation",
                "E": "mouse enter", "X": "mouse exit", "D": "mouse down", "U": "mouse up", "Fo": "field focus",
                "Bl": "field blur", "PO": "page open", "PC": "page close", "PV": "page shown", "PI": "page hidden",
            ])
        }
        return facts
    }

    // MARK: Outline and labels

    static func outline(_ document: PDFDocument) -> [FileFacts.Section] {
        var sections: [FileFacts.Section] = []
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren where sections.count < maxItems && level <= maxDepth {
                guard let child = item.child(at: index) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let destination, let page = destination.page {
                    let crop = page.bounds(for: .cropBox)
                    let point = destination.point
                    func known(_ value: CGFloat) -> Bool { value.isFinite && value > -1e6 && value < 1e6 }
                    let top = known(point.y) && crop.height > 0 ? min(max(Double((crop.maxY - point.y) / crop.height), 0), 1) : nil
                    let left = known(point.x) && crop.width > 0 && point.x > crop.minX
                        ? min(max(Double((point.x - crop.minX) / crop.width), 0), 1) : nil
                    sections.append(FileFacts.Section(title: TextCleanup.line(child.label ?? ""), level: level,
                                                      page: document.index(for: page), top: top, left: left))
                }
                walk(child, level: level + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, level: 1) }
        return sections.filter { !$0.title.isEmpty }
    }

    static func labels(_ document: PDFDocument) -> [String]? {
        let labels = (0..<document.pageCount).map { document.page(at: $0)?.label ?? "" }
        let differ = labels.enumerated().contains { index, label in !label.isEmpty && label != String(index + 1) }
        return differ ? labels : nil
    }

    // MARK: Dictionaries

    static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    /// Calls `visit` for each entry of a name tree, in order, within the limits.
    static func walkNameTree(_ node: CGPDFDictionaryRef, depth: Int = 0, visit: (String, CGPDFObjectRef) -> Void) {
        var budget = maxItems
        func walk(_ node: CGPDFDictionaryRef, depth: Int) {
            guard depth <= maxDepth, budget > 0 else { return }
            var names: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Names", &names), let names {
                let count = CGPDFArrayGetCount(names)
                var index = 0
                while index + 1 < count && budget > 0 {
                    var key: CGPDFStringRef?
                    var value: CGPDFObjectRef?
                    let name = CGPDFArrayGetString(names, index, &key) ? (key.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "") : ""
                    if CGPDFArrayGetObject(names, index + 1, &value), let value { visit(name, value) }
                    budget -= 1
                    index += 2
                }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                for index in 0..<CGPDFArrayGetCount(kids) where budget > 0 {
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, index, &kid), let kid { walk(kid, depth: depth + 1) }
                }
            }
        }
        walk(node, depth: depth)
    }

    /// An attached file's name and size, from its file specification.
    static func attachment(_ spec: CGPDFDictionaryRef, fallback: String, page: Int?) -> FileFacts.Attachment {
        let name = string(spec, "UF") ?? string(spec, "F") ?? fallback
        var size: Int?
        var files: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetDictionary(spec, "EF", &files), let files, CGPDFDictionaryGetStream(files, "F", &stream),
           let stream, let info = CGPDFStreamGetDictionary(stream) {
            var params: CGPDFDictionaryRef?
            var value: CGPDFInteger = 0
            if CGPDFDictionaryGetDictionary(info, "Params", &params), let params, CGPDFDictionaryGetInteger(params, "Size", &value) {
                size = value
            } else if CGPDFDictionaryGetInteger(info, "Length", &value) {
                size = value
            }
        }
        return FileFacts.Attachment(name: TextCleanup.line(name), size: size, page: page)
    }

    /// The scripts and launches of an action and of the actions chained after it.
    static func scripts(in action: CGPDFDictionaryRef, trigger: String, page: Int?, depth: Int = 0) -> [FileFacts.Script] {
        guard depth <= 5 else { return [] }
        var found: [FileFacts.Script] = []
        switch name(action, "S") ?? "" {
        case "JavaScript":
            var stream: CGPDFStreamRef?
            var length = string(action, "JS")?.count ?? 0
            if length == 0, CGPDFDictionaryGetStream(action, "JS", &stream), let stream {
                var format = CGPDFDataFormat.raw
                length = (CGPDFStreamCopyData(stream, &format) as Data?)?.count ?? 0
            }
            found.append(FileFacts.Script(trigger: trigger, kind: "JavaScript", page: page, detail: "\(length) characters"))
        case "Launch":
            var spec: CGPDFDictionaryRef?
            let target = string(action, "F")
                ?? ((CGPDFDictionaryGetDictionary(action, "F", &spec)) ? spec.flatMap { string($0, "UF") ?? string($0, "F") } : nil)
            found.append(FileFacts.Script(trigger: trigger, kind: "Launch", page: page, detail: target ?? "a program"))
        default:
            break
        }
        var next: CGPDFDictionaryRef?
        var chain: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(action, "Next", &next), let next {
            found += scripts(in: next, trigger: trigger, page: page, depth: depth + 1)
        } else if CGPDFDictionaryGetArray(action, "Next", &chain), let chain {
            for index in 0..<min(CGPDFArrayGetCount(chain), 16) {
                if CGPDFArrayGetDictionary(chain, index, &next), let next {
                    found += scripts(in: next, trigger: trigger, page: page, depth: depth + 1)
                }
            }
        }
        return found
    }

    /// The scripts of a dictionary's additional actions, named by what would start them.
    static func additionalActions(_ dictionary: CGPDFDictionaryRef, page: Int?, triggers: [String: String]) -> [FileFacts.Script] {
        var actions: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "AA", &actions), let actions else { return [] }
        return triggers.keys.sorted().flatMap { key -> [FileFacts.Script] in
            var action: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(actions, key, &action), let action else { return [] }
            return scripts(in: action, trigger: triggers[key]!, page: page)
        }
    }

    /// Whether a form field holds a value: text, a choice, or a box that is checked. The value
    /// can sit on the field the widget belongs to.
    static func filled(_ widget: CGPDFDictionaryRef) -> Bool {
        var field: CGPDFDictionaryRef? = widget
        for _ in 0..<maxDepth {
            guard let current = field else { return false }
            var text: CGPDFStringRef?
            if CGPDFDictionaryGetString(current, "V", &text), let text {
                return !((CGPDFStringCopyTextString(text) as String?) ?? "").isEmpty
            }
            if let value = name(current, "V") { return value != "Off" }
            var choices: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(current, "V", &choices), let choices { return CGPDFArrayGetCount(choices) > 0 }
            var parent: CGPDFDictionaryRef?
            field = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return false
    }
}
