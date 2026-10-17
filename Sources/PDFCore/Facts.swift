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
        /// The file's own size, when the PDF states it.
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
        /// The script's length, or the launched file's name.
        public var detail: String
    }

    /// What an annotation shows a reader beside the page's text (FEATURES.md → F3): a comment or
    /// a note typed on the page, a highlight or another mark on words, a filled-in form field, or
    /// a link.
    public struct Annotation: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case comment, note, highlight, underline, strikeout, squiggly, field, link
        }

        public var kind: Kind
        /// Counted from 0.
        public var page: Int
        /// Where it sits, as fractions of the page from its top-left corner, as blocks are.
        public var box: Box
        /// Who wrote it, when the file says.
        public var author: String?
        /// A comment's or a note's text, or the comment a mark carries.
        public var text: String?
        /// A field's name and the value filled in.
        public var name: String?
        public var value: String?
        /// Where a link leads: a web address, or "p.12" for a page of the file.
        public var target: String?
        /// The words under a mark or a link, as PDFKit selects them there. They may hold text a
        /// reader cannot see, so the output keeps only words its page shows.
        public var words: String?
        /// A reply to another comment.
        public var reply: Bool?
        /// The file hides it, or sets it off the page.
        public var hidden: Bool?
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
    /// Form fields a person can fill in, each counted once however many widgets show it.
    public var formFields = 0
    public var filledFields = 0
    /// The first `FactReader.maxListed` attachments and scripts; `moreAttachments` and
    /// `moreScripts` count the rest.
    public var attachments: [Attachment] = []
    public var scripts: [Script] = []
    public var moreAttachments = 0
    public var moreScripts = 0
    /// The first `FactReader.maxAnnotations` links, and as many of the other annotations, in page
    /// order, so a file of links cannot crowd out its comments; `moreAnnotations` counts those past
    /// them.
    public var annotations: [Annotation] = []
    public var moreAnnotations = 0
    /// True when the file holds more objects than one read visits, so the counts cover part of it.
    public var partial = false
    /// Why the facts could not be read, such as a time limit. The file's pages read all the same.
    public var failure: String?

    public init() {}

    public init(failure: String) {
        self.failure = failure
    }
}

/// Reads a file's facts. A worker of its own runs it, apart from the index, so a file whose
/// facts take too long or crash the reader loses its facts and keeps its pages. One read visits
/// at most `maxVisits` objects, and no walk follows a loop, so the work stays bounded however
/// the file's objects point at each other.
final class FactReader {
    static let maxDepth = 12
    static let maxVisits = 200_000
    static let maxListed = 100
    static let maxAnnotations = 1_000
    /// The longest an annotation's text or words are kept, in characters.
    static let maxAnnotationText = 1_000
    /// How long the read of annotations with PDFKit may take, of the facts' 10 s.
    static let annotationSeconds = 3.0

    private(set) var facts = FileFacts()
    private var visits = 0
    /// Tree nodes, file specifications and form fields: each counts once in the file.
    private var seen = Set<OpaquePointer>()
    /// Actions: each counts once for the document, and once on each page that holds it.
    private var actionsSeen = Set<OpaquePointer>()
    /// Each page's index by its dictionary, for links to a page of the file.
    private var pageIndex: [OpaquePointer: Int] = [:]
    /// Annotations whose words PDFKit selects, by their place in `facts.annotations`, with their
    /// page and the rectangles, in page space, of their words.
    private var underWords: [(annotation: Int, page: Int, rects: [CGRect])] = []
    /// Links to a page of the file, by their place in `facts.annotations`, with the page's
    /// dictionary, or the name of a destination.
    private var pageLinks: [(annotation: Int, page: OpaquePointer?, name: String?)] = []
    /// The links and the other annotations listed so far, each up to `maxAnnotations`.
    private var linksListed = 0, othersListed = 0

    /// Reads every fact of `document`. The outline comes from PDFKit, which opens the file again.
    static func read(_ document: CGPDFDocument, url: URL) -> FileFacts {
        let reader = FactReader()
        reader.readDocument(document)
        // The page tree is walked once: asking for each page by its number takes longer the
        // longer the file, 27 s for 30,000 pages.
        var index = 0
        if let catalog = document.catalog {
            var root: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Pages", &root), let root {
                var path = Set<OpaquePointer>()
                reader.walkPages(root, path: &path) { page in
                    reader.readPage(page, index: index)
                    index += 1
                }
            }
        }
        if let pdf = PDFDocument(url: url), OpenFailure.unlock(pdf) {
            reader.facts.outline = outline(pdf)
            reader.readWords(pdf)
        }
        reader.resolveLinks(document)
        if reader.visits >= maxVisits { reader.facts.partial = true }
        return reader.facts
    }

    /// CGPDF hands out the same reference for the same object while the document is open, so the
    /// reference names it.
    static func identity(_ dictionary: CGPDFDictionaryRef) -> OpaquePointer {
        unsafeBitCast(dictionary, to: OpaquePointer.self)
    }

    /// Whether the read may visit one more object: `maxVisits` in all.
    private func spend() -> Bool {
        guard visits < Self.maxVisits else {
            facts.partial = true
            return false
        }
        visits += 1
        return true
    }

    /// Whether the read may visit `dictionary`: once in `set`, within the budget.
    private func visit(_ dictionary: CGPDFDictionaryRef, in set: inout Set<OpaquePointer>) -> Bool {
        set.insert(Self.identity(dictionary)).inserted && spend()
    }

    private func visit(_ dictionary: CGPDFDictionaryRef) -> Bool { visit(dictionary, in: &seen) }

    /// The facts the catalog and the information dictionary hold: metadata, page labels, the
    /// document's attachments and its scripts.
    func readDocument(_ document: CGPDFDocument) {
        if let info = document.info {
            facts.author = Self.string(info, "Author").map(TextCleanup.line).flatMap { $0.isEmpty ? nil : $0 }
            if let created = Self.string(info, "CreationDate") ?? Self.string(info, "ModDate"),
               let match = created.range(of: #"(19|20)\d\d"#, options: .regularExpression) {
                facts.year = String(created[match])
            }
        }
        guard let catalog = document.catalog else { return }
        facts.labels = labels(catalog, pageCount: document.numberOfPages)
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var tree: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &tree), let tree {
                walkTree(tree, entries: "Names") { name, value in
                    var spec: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(value, .dictionary, &spec), let spec else { return }
                    attachment(spec, fallback: name, page: nil)
                }
            }
            if CGPDFDictionaryGetDictionary(names, "JavaScript", &tree), let tree {
                walkTree(tree, entries: "Names") { _, value in
                    var action: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(value, .dictionary, &action), let action else { return }
                    scripts(in: action, trigger: "document open", page: nil)
                }
            }
        }
        var open: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "OpenAction", &open), let open {
            scripts(in: open, trigger: "document open", page: nil)
        }
        additionalActions(catalog, page: nil, triggers: [
            "WC": "document close", "WS": "before save", "DS": "after save", "WP": "before print", "DP": "after print",
        ])
    }

    /// Calls `visit` for each page of the page tree, in order. A node the tree lists twice counts
    /// twice, as CGPDF counts it, so the pages keep CGPDF's numbers; only a node inside itself,
    /// a loop, is passed over.
    func walkPages(_ node: CGPDFDictionaryRef, depth: Int = 0, path: inout Set<OpaquePointer>,
                   visit page: (CGPDFDictionaryRef) -> Void) {
        let id = Self.identity(node)
        guard depth <= 64, !path.contains(id), spend() else { return }
        var kids: CGPDFArrayRef?
        guard Self.name(node, "Type") != "Page", CGPDFDictionaryGetArray(node, "Kids", &kids), let kids else {
            page(node)
            return
        }
        path.insert(id)
        for index in 0..<CGPDFArrayGetCount(kids) where visits < Self.maxVisits {
            var kid: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(kids, index, &kid), let kid { walkPages(kid, depth: depth + 1, path: &path, visit: page) }
        }
        path.remove(id)
    }

    /// The facts one page's annotations hold. A page the tree lists twice counts twice.
    func readPage(_ dictionary: CGPDFDictionaryRef, index: Int) {
        actionsSeen.removeAll(keepingCapacity: true)
        pageIndex[Self.identity(dictionary)] = index
        let geometry = PageGeometry(dictionary: dictionary)
        additionalActions(dictionary, page: index, triggers: ["O": "page open", "C": "page close"])
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return }
        for position in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation, spend() else { continue }
            let subtype = Self.name(annotation, "Subtype") ?? ""
            if Self.shown.contains(subtype), subtype != "Widget" {
                collect(annotation, subtype: subtype, page: index, crop: geometry?.cropBox ?? PageGeometry.letter)
            }
            switch subtype {
            case "Text", "FreeText":
                facts.comments += 1
            case "Highlight", "Underline", "Squiggly", "StrikeOut":
                facts.highlights += 1
            case "Widget":
                field(of: annotation, page: index, crop: geometry?.cropBox ?? PageGeometry.letter)
            case "FileAttachment":
                var spec: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(annotation, "FS", &spec), let spec {
                    attachment(spec, fallback: "attachment", page: index)
                }
            default:
                break
            }
            var action: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(annotation, "A", &action), let action {
                scripts(in: action, trigger: "link click", page: index)
            }
            additionalActions(annotation, page: index, triggers: Self.widgetTriggers.merging(Self.fieldTriggers) { first, _ in first })
        }
    }

    /// The annotations whose words, values or targets reach the output beside the page's text.
    static let shown: Set<String> = ["Text", "FreeText", "Highlight", "Underline", "Squiggly", "StrikeOut", "Widget", "Link"]

    // MARK: Annotations

    /// An annotation's rectangle in page space, with its corners in either order.
    static func rect(_ annotation: CGPDFDictionaryRef, _ key: String = "Rect") -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annotation, key, &array), let array, CGPDFArrayGetCount(array) >= 4 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for index in 0..<4 { guard CGPDFArrayGetNumber(array, index, &values[index]), values[index].isFinite else { return nil } }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]), width: abs(values[2] - values[0]),
                      height: abs(values[3] - values[1]))
    }

    /// Text as the file holds it, on one line, cut to `maxAnnotationText` characters.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = TextCleanup.line(text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        return line.isEmpty ? nil : String(line.prefix(maxAnnotationText))
    }

    /// Starts an annotation's entry: its kind, page, place, author, and whether the file hides it.
    func start(_ annotation: CGPDFDictionaryRef, kind: FileFacts.Annotation.Kind, page: Int, crop: CGRect) -> FileFacts.Annotation? {
        guard let rect = Self.rect(annotation) else { return nil }
        guard (kind == .link ? linksListed : othersListed) < Self.maxAnnotations else {
            facts.moreAnnotations += 1
            return nil
        }
        if kind == .link { linksListed += 1 } else { othersListed += 1 }
        let width = max(crop.width, 1), height = max(crop.height, 1)
        let box = Box(x: Double((rect.minX - crop.minX) / width), y: Double((crop.maxY - rect.maxY) / height),
                      width: Double(rect.width / width), height: Double(rect.height / height))
        var found = FileFacts.Annotation(kind: kind, page: page, box: box)
        found.author = Self.clean(Self.string(annotation, "T"))
        // Hidden, bit 2, or not to be shown on screen, bit 6; or set off the page.
        var flags: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(annotation, "F", &flags)
        if flags & (2 | 32) != 0 || !rect.intersects(crop) { found.hidden = true }
        return found
    }

    /// Reads a comment, a note, a mark on words or a link from the annotation's dictionary, as
    /// CGPDF holds it: PDFKit, asked for a link's action, followed an action chained to itself
    /// until it crashed.
    func collect(_ annotation: CGPDFDictionaryRef, subtype: String, page: Int, crop: CGRect) {
        let kinds: [String: FileFacts.Annotation.Kind] = ["Text": .comment, "FreeText": .note, "Highlight": .highlight,
                                                          "Underline": .underline, "Squiggly": .squiggly, "StrikeOut": .strikeout,
                                                          "Link": .link]
        guard let kind = kinds[subtype], var found = start(annotation, kind: kind, page: page, crop: crop) else { return }
        let text = Self.clean(Self.string(annotation, "Contents"))
        switch kind {
        case .comment, .note:
            guard let text else { return }
            found.text = text
            if Self.has(annotation, "IRT") { found.reply = true }
            facts.annotations.append(found)
        case .highlight, .underline, .squiggly, .strikeout:
            found.text = text
            facts.annotations.append(found)
            underWords.append((facts.annotations.count - 1, page, Self.quads(annotation) ?? [Self.rect(annotation)].compactMap { $0 }))
        case .link:
            var action: CGPDFDictionaryRef?
            let acts = CGPDFDictionaryGetDictionary(annotation, "A", &action)
            if acts, let action, let kind = Self.name(action, "S") {
                switch kind {
                case "URI":
                    // A web or mail address. A link that starts a program or opens a file is a
                    // script, which `pdf info` names and nothing runs.
                    guard let uri = Self.string(action, "URI").map({ $0.trimmingCharacters(in: .whitespaces) }),
                          let scheme = uri.split(separator: ":").first?.lowercased(),
                          ["http", "https", "mailto", "ftp"].contains(scheme) else { return }
                    found.target = String(uri.prefix(Self.maxAnnotationText))
                case "GoTo":
                    guard let destination = Self.destination(action, "D") else { return }
                    pageLinks.append((facts.annotations.count, destination.page, destination.name))
                default:
                    return
                }
            } else if !acts, let destination = Self.destination(annotation, "Dest") {
                pageLinks.append((facts.annotations.count, destination.page, destination.name))
            } else {
                return
            }
            facts.annotations.append(found)
            underWords.append((facts.annotations.count - 1, page, [Self.rect(annotation)].compactMap { $0 }))
        case .field:
            return
        }
    }

    /// A mark's quadrilaterals, each as the rectangle around its four corners.
    static func quads(_ annotation: CGPDFDictionaryRef) -> [CGRect]? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annotation, "QuadPoints", &array), let array else { return nil }
        let count = min(CGPDFArrayGetCount(array), 8 * 200)
        var numbers: [CGFloat] = []
        for index in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value), value.isFinite else { return nil }
            numbers.append(value)
        }
        let rects = stride(from: 0, to: numbers.count - numbers.count % 8, by: 8).map { start -> CGRect in
            let xs = [numbers[start], numbers[start + 2], numbers[start + 4], numbers[start + 6]]
            let ys = [numbers[start + 1], numbers[start + 3], numbers[start + 5], numbers[start + 7]]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        return rects.isEmpty ? nil : rects
    }

    /// Where a destination leads: an explicit one names its page's dictionary first; a named one,
    /// a name or a string, is looked up after the walk.
    static func destination(_ dictionary: CGPDFDictionaryRef, _ key: String) -> (page: OpaquePointer?, name: String?)? {
        var array: CGPDFArrayRef?, page: CGPDFDictionaryRef?
        if CGPDFDictionaryGetArray(dictionary, key, &array), let array {
            guard CGPDFArrayGetDictionary(array, 0, &page), let page else { return nil }
            return (identity(page), nil)
        }
        if let name = name(dictionary, key) ?? string(dictionary, key) { return (nil, name) }
        return nil
    }

    /// Gives each link to a page of the file its page, "p.12", and drops the links whose page is
    /// not found. Named destinations come from the catalog's /Dests, or its /Names tree.
    func resolveLinks(_ document: CGPDFDocument) {
        var named: [String: OpaquePointer] = [:]
        if pageLinks.contains(where: { $0.name != nil }), let catalog = document.catalog {
            func page(_ object: CGPDFObjectRef) -> OpaquePointer? {
                var array: CGPDFArrayRef?, holder: CGPDFDictionaryRef?, page: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetDictionary(array, 0, &page), let page {
                    return Self.identity(page)
                }
                if CGPDFObjectGetValue(object, .dictionary, &holder), let holder, CGPDFDictionaryGetArray(holder, "D", &array), let array,
                   CGPDFArrayGetDictionary(array, 0, &page), let page {
                    return Self.identity(page)
                }
                return nil
            }
            var dests: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Dests", &dests), let dests {
                CGPDFDictionaryApplyBlock(dests, { key, object, _ in
                    if let found = page(object) { named[String(cString: key)] = found }
                    return named.count < 10_000
                }, nil)
            }
            var names: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names, CGPDFDictionaryGetDictionary(names, "Dests", &tree), let tree {
                walkTree(tree, entries: "Names") { name, object in
                    if let found = page(object) { named[name] = found }
                }
            }
        }
        var dropped = Set<Int>()
        for link in pageLinks {
            if let page = link.page ?? link.name.flatMap({ named[$0] }), let index = pageIndex[page] {
                facts.annotations[link.annotation].target = "p.\(index + 1)"
            } else {
                dropped.insert(link.annotation)
            }
        }
        guard !dropped.isEmpty else { return }
        facts.annotations = facts.annotations.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// The words under each mark and link, as PDFKit selects them there: they may hold text a
    /// reader cannot see, which the output leaves out. At most `annotationSeconds`.
    func readWords(_ document: PDFDocument) {
        let started = DispatchTime.now().uptimeNanoseconds
        for entry in underWords {
            guard Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < Self.annotationSeconds else { break }
            guard let page = document.page(at: entry.page) else { continue }
            let words = entry.rects.compactMap { page.selection(for: $0)?.string }.joined(separator: " ")
            facts.annotations[entry.annotation].words = Self.clean(words)
        }
    }

    static let widgetTriggers = ["E": "mouse enter", "X": "mouse exit", "D": "mouse down", "U": "mouse up",
                                 "Fo": "field focus", "Bl": "field blur", "PO": "page open", "PC": "page close",
                                 "PV": "page shown", "PI": "page hidden"]
    static let fieldTriggers = ["K": "field keystroke", "F": "field format", "V": "field change", "C": "field calculation"]

    // MARK: Form fields

    /// Counts the field a widget shows, once per field: a radio group's buttons, or one field
    /// shown on two pages, count as one. A push button holds no value, so it is no field to fill.
    /// A field's own scripts sit on the field when it has several widgets.
    func field(of widget: CGPDFDictionaryRef, page: Int, crop: CGRect) {
        var field = widget
        var parent: CGPDFDictionaryRef?
        if !Self.has(widget, "T") && !Self.has(widget, "FT"), CGPDFDictionaryGetDictionary(widget, "Parent", &parent), let parent {
            field = parent
        }
        guard visit(field) else { return }
        if field != widget { additionalActions(field, page: page, triggers: Self.fieldTriggers) }
        let type = inherited(field) { Self.name($0, "FT") }
        var flags: CGPDFInteger = 0
        _ = inherited(field) { CGPDFDictionaryGetInteger($0, "Ff", &flags) ? true : nil }
        if type == "Btn" && flags & (1 << 16) != 0 { return }
        facts.formFields += 1
        guard filled(field) else { return }
        facts.filledFields += 1
        // The filled field, where its widget shows it, with its full name and its value.
        guard var found = start(widget, kind: .field, page: page, crop: crop) else { return }
        found.name = Self.clean(fullName(field))
        found.value = Self.clean(value(field))
        guard found.name != nil, found.value != nil else { return }
        facts.annotations.append(found)
    }

    /// A field's name: its own and its parents', joined by dots.
    func fullName(_ field: CGPDFDictionaryRef) -> String? {
        var parts: [String] = []
        var current: CGPDFDictionaryRef? = field
        for _ in 0..<Self.maxDepth {
            guard let dictionary = current else { break }
            if let part = Self.string(dictionary, "T"), !part.isEmpty { parts.insert(part, at: 0) }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent) ? parent : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    /// What a field holds: its text, the choice or choices made, or the state of a box that is
    /// checked; "signed" for a signature.
    func value(_ field: CGPDFDictionaryRef) -> String? {
        if inherited(field, { Self.name($0, "FT") }) == "Sig" { return "signed" }
        return inherited(field) { dictionary -> String? in
            if let text = Self.string(dictionary, "V") { return text }
            if let name = Self.name(dictionary, "V") { return name == "Off" ? nil : name }
            var choices: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "V", &choices), let choices else { return nil }
            let picked = (0..<min(CGPDFArrayGetCount(choices), 100)).compactMap { index -> String? in
                var item: CGPDFStringRef?
                return CGPDFArrayGetString(choices, index, &item) ? item.flatMap { CGPDFStringCopyTextString($0) as String? } : nil
            }
            return picked.isEmpty ? nil : picked.joined(separator: ", ")
        }
    }

    /// The first value `read` finds on a field or the fields above it.
    func inherited<T>(_ field: CGPDFDictionaryRef, _ read: (CGPDFDictionaryRef) -> T?) -> T? {
        var current: CGPDFDictionaryRef? = field
        for _ in 0..<Self.maxDepth {
            guard let dictionary = current else { return nil }
            if let value = read(dictionary) { return value }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    /// Whether a form field holds a value: text, a choice, a box that is checked, or a signature.
    func filled(_ field: CGPDFDictionaryRef) -> Bool {
        inherited(field) { dictionary -> Bool? in
            var text: CGPDFStringRef?
            if CGPDFDictionaryGetString(dictionary, "V", &text), let text {
                return !((CGPDFStringCopyTextString(text) as String?) ?? "").isEmpty
            }
            if let value = Self.name(dictionary, "V") { return value != "Off" }
            var choices: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "V", &choices), let choices { return CGPDFArrayGetCount(choices) > 0 }
            return Self.has(dictionary, "V") ? true : nil
        } ?? false
    }

    // MARK: Outline and labels

    static func outline(_ document: PDFDocument) -> [FileFacts.Section] {
        var sections: [FileFacts.Section] = []
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren where sections.count < 2_000 && level <= maxDepth {
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

    /// Each page's label, from the catalog's number tree (PDF 32000-1:2008, 12.4.2), read in one
    /// pass: asking PDFKit page by page takes longer the longer the file, 54 s for 30,000 pages.
    func labels(_ catalog: CGPDFDictionaryRef, pageCount: Int) -> [String]? {
        var root: CGPDFDictionaryRef?
        guard pageCount > 0, CGPDFDictionaryGetDictionary(catalog, "PageLabels", &root), let root else { return nil }
        var ranges: [(start: Int, style: String?, prefix: String, first: Int)] = []
        walkNumberTree(root) { start, value in
            var range: CGPDFDictionaryRef?
            guard start >= 0, start < pageCount, CGPDFObjectGetValue(value, .dictionary, &range), let range else { return }
            var first: CGPDFInteger = 1
            _ = CGPDFDictionaryGetInteger(range, "St", &first)
            // A start beyond any real page number would overflow when pages are counted on.
            ranges.append((start, Self.name(range, "S"), Self.string(range, "P") ?? "", min(max(first, 1), 1_000_000_000)))
        }
        guard !ranges.isEmpty else { return nil }
        ranges.sort { $0.start < $1.start }
        var labels: [String] = []
        labels.reserveCapacity(pageCount)
        var current = -1
        for page in 0..<pageCount {
            while current + 1 < ranges.count && ranges[current + 1].start <= page { current += 1 }
            guard current >= 0 else {
                labels.append("")
                continue
            }
            let range = ranges[current]
            labels.append(range.prefix + Self.number(range.first + page - range.start, style: range.style))
        }
        let differ = labels.enumerated().contains { index, label in !label.isEmpty && label != String(index + 1) }
        return differ ? labels : nil
    }

    /// A page number in a label's style: decimal, roman or letters, upper or lower case.
    static func number(_ value: Int, style: String?) -> String {
        switch style {
        case "D": return String(value)
        case "R": return roman(value)
        case "r": return roman(value).lowercased()
        case "A": return letters(value)
        case "a": return letters(value).lowercased()
        default: return ""
        }
    }

    static func roman(_ value: Int) -> String {
        guard value > 0 && value < 4_000 else { return String(value) }
        let numerals = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                        (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = value
        var text = ""
        for (amount, numeral) in numerals {
            while rest >= amount {
                text += numeral
                rest -= amount
            }
        }
        return text
    }

    /// A to Z, then AA to ZZ, then AAA, as the PDF standard counts.
    static func letters(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let letter = Character(UnicodeScalar(UInt8(65 + (value - 1) % 26)))
        return String(repeating: letter, count: min((value - 1) / 26 + 1, 100))
    }

    // MARK: Trees and dictionaries

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

    static func has(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &value)
    }

    /// Calls `visit` for each entry of a name tree, in order, visiting each node once.
    func walkTree(_ node: CGPDFDictionaryRef, entries: String, depth: Int = 0, visit entry: (String, CGPDFObjectRef) -> Void) {
        guard depth <= Self.maxDepth, visit(node) else { return }
        var pairs: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, entries, &pairs), let pairs {
            let count = CGPDFArrayGetCount(pairs)
            var index = 0
            while index + 1 < count && visits < Self.maxVisits {
                var key: CGPDFStringRef?
                var value: CGPDFObjectRef?
                let name = CGPDFArrayGetString(pairs, index, &key) ? (key.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "") : ""
                if CGPDFArrayGetObject(pairs, index + 1, &value), let value { entry(name, value) }
                visits += 1
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) where visits < Self.maxVisits {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid { walkTree(kid, entries: entries, depth: depth + 1, visit: entry) }
            }
        }
    }

    /// Calls `visit` for each entry of a number tree, as `walkTree` does for a name tree.
    func walkNumberTree(_ node: CGPDFDictionaryRef, depth: Int = 0, visit entry: (Int, CGPDFObjectRef) -> Void) {
        guard depth <= Self.maxDepth, visit(node) else { return }
        var pairs: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Nums", &pairs), let pairs {
            let count = CGPDFArrayGetCount(pairs)
            var index = 0
            while index + 1 < count && visits < Self.maxVisits {
                var key: CGPDFInteger = 0
                var value: CGPDFObjectRef?
                if CGPDFArrayGetInteger(pairs, index, &key), CGPDFArrayGetObject(pairs, index + 1, &value), let value {
                    entry(key, value)
                }
                visits += 1
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) where visits < Self.maxVisits {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid { walkNumberTree(kid, depth: depth + 1, visit: entry) }
            }
        }
    }

    /// An attached file's name, and its size when the PDF states it. The stream's own length
    /// is its compressed size, so it is no answer.
    func attachment(_ spec: CGPDFDictionaryRef, fallback: String, page: Int?) {
        guard visit(spec) else { return }
        guard facts.attachments.count < Self.maxListed else {
            facts.moreAttachments += 1
            return
        }
        let name = Self.string(spec, "UF") ?? Self.string(spec, "F") ?? fallback
        var size: Int?
        var files: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetDictionary(spec, "EF", &files), let files, CGPDFDictionaryGetStream(files, "F", &stream),
           let stream, let info = CGPDFStreamGetDictionary(stream) {
            var params: CGPDFDictionaryRef?
            var value: CGPDFInteger = 0
            if CGPDFDictionaryGetDictionary(info, "Params", &params), let params, CGPDFDictionaryGetInteger(params, "Size", &value) {
                size = value
            }
        }
        facts.attachments.append(FileFacts.Attachment(name: TextCleanup.line(name), size: size, page: page))
    }

    /// The scripts and launches of an action and of the actions chained after it. A script is
    /// measured by its stored length, never decompressed.
    func scripts(in action: CGPDFDictionaryRef, trigger: String, page: Int?, depth: Int = 0) {
        guard depth <= Self.maxDepth, visit(action, in: &actionsSeen) else { return }
        var found: FileFacts.Script?
        switch Self.name(action, "S") ?? "" {
        case "JavaScript":
            var stream: CGPDFStreamRef?
            func characters(_ count: Int) -> String { "\(count) character\(count == 1 ? "" : "s")" }
            var detail = Self.string(action, "JS").map { characters($0.count) } ?? "a script"
            if CGPDFDictionaryGetStream(action, "JS", &stream), let stream, let info = CGPDFStreamGetDictionary(stream) {
                var length: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(info, "Length", &length) {
                    detail = Self.has(info, "Filter") ? "\(length) bytes compressed" : characters(length)
                }
            }
            found = FileFacts.Script(trigger: trigger, kind: "JavaScript", page: page, detail: detail)
        case "Launch":
            var spec: CGPDFDictionaryRef?
            let target = Self.string(action, "F")
                ?? ((CGPDFDictionaryGetDictionary(action, "F", &spec)) ? spec.flatMap { Self.string($0, "UF") ?? Self.string($0, "F") } : nil)
            found = FileFacts.Script(trigger: trigger, kind: "Launch", page: page, detail: target ?? "a program")
        default:
            break
        }
        if let found {
            if facts.scripts.count < Self.maxListed { facts.scripts.append(found) } else { facts.moreScripts += 1 }
        }
        var next: CGPDFDictionaryRef?
        var chain: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(action, "Next", &next), let next {
            scripts(in: next, trigger: trigger, page: page, depth: depth + 1)
        } else if CGPDFDictionaryGetArray(action, "Next", &chain), let chain {
            for index in 0..<CGPDFArrayGetCount(chain) where visits < Self.maxVisits {
                if CGPDFArrayGetDictionary(chain, index, &next), let next {
                    scripts(in: next, trigger: trigger, page: page, depth: depth + 1)
                }
            }
        }
    }

    /// The scripts of a dictionary's additional actions, named by what would start them.
    func additionalActions(_ dictionary: CGPDFDictionaryRef, page: Int?, triggers: [String: String]) {
        var actions: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "AA", &actions), let actions else { return }
        for key in triggers.keys.sorted() {
            var action: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(actions, key, &action), let action else { continue }
            scripts(in: action, trigger: triggers[key]!, page: page)
        }
    }
}
