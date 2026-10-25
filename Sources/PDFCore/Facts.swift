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
            /// A stamp, a drawing by hand, or a shape a reader drew on the page.
            case stamp, ink, shape
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
    /// The annotations the walk found: on each page the first `FactReader.maxAnnotations` links
    /// and as many of the other annotations, and `FactReader.maxAnnotationsInFile` in all;
    /// `moreAnnotations` counts those past them, `moreOnPage` by page (counted from 0).
    ///
    /// Only the walk's result holds them. The cache keeps them per page in a table of their own
    /// (`Store.annotations`), so the facts it hands back have none, and `moreOnPage` is empty too
    /// (DESIGNS.md → Decision: annotations per page, in a table of their own).
    public var annotations: [Annotation] = []
    public var moreAnnotations = 0
    public var moreOnPage: [Int: Int] = [:]
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
    /// Per page: links, and as many of the other annotations.
    static let maxAnnotations = 1_000
    /// In a file, all pages together: the table of a hostile file stays small.
    static let maxAnnotationsInFile = 100_000
    /// The longest an annotation's text or words are kept, in characters.
    static let maxAnnotationText = 1_000
    /// How long the read of annotations with PDFKit may take, of the facts' 10 s.
    static let annotationSeconds = 3.0

    private(set) var facts = FileFacts()
    /// Given each attachment and script as the walk meets it, for `pdf dump`; nil for the facts.
    var sink: ((Payload) -> Void)?
    /// What the sink wants; the rest is never decoded.
    var wantAttachments = true, wantScripts = true
    /// Streams and actions already handed to the sink, so one shared by many places is saved once.
    private var handed = Set<OpaquePointer>()
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
    /// The links and the other annotations listed so far on the page being read, each up to
    /// `maxAnnotations`, and the count of all in the file.
    private var linksListed = 0, othersListed = 0
    private var listedInFile = 0
    private var currentPage = -1
    /// The layers the file switches off, by their dictionaries: an annotation in one is hidden.
    private var layersOff = Set<OpaquePointer>()

    /// Reads every fact of `document`. The outline comes from PDFKit, which opens the file again.
    static func read(_ document: CGPDFDocument, url: URL, attachments: Bool = true, scripts: Bool = true,
                     sink: ((Payload) -> Void)? = nil) -> FileFacts {
        let reader = FactReader()
        reader.sink = sink
        reader.wantAttachments = attachments
        reader.wantScripts = scripts
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
        // The layers off by default, as the hidden-text check reads them: those listed off, and
        // with a base state of off, every layer not listed on.
        var properties: CGPDFDictionaryRef?, defaults: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties), let properties,
           CGPDFDictionaryGetDictionary(properties, "D", &defaults), let defaults {
            func layers(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [OpaquePointer] {
                var array: CGPDFArrayRef?
                guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
                return (0..<min(CGPDFArrayGetCount(array), 1_000)).compactMap { index in
                    var layer: CGPDFDictionaryRef?
                    return CGPDFArrayGetDictionary(array, index, &layer) ? layer.map(Self.identity) : nil
                }
            }
            if Self.name(defaults, "BaseState") == "OFF" {
                layersOff = Set(layers(properties, "OCGs")).subtracting(layers(defaults, "ON"))
            }
            layersOff.formUnion(layers(defaults, "OFF"))
        }
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
    static let shown: Set<String> = ["Text", "FreeText", "Highlight", "Underline", "Squiggly", "StrikeOut", "Widget", "Link",
                                     "Stamp", "Ink", "Square", "Circle", "Line", "Polygon", "PolyLine", "Caret"]

    /// The 14 stamp names the PDF standard defines, as the words their stamps show.
    static let stampNames: [String: String] = [
        "Approved": "Approved", "Experimental": "Experimental", "NotApproved": "Not Approved", "AsIs": "As Is",
        "Expired": "Expired", "NotForPublicRelease": "Not For Public Release", "Confidential": "Confidential",
        "Final": "Final", "Sold": "Sold", "Departmental": "Departmental", "ForComment": "For Comment",
        "TopSecret": "Top Secret", "Draft": "Draft", "ForPublicRelease": "For Public Release",
    ]

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
        let breaks: Set<Character> = ["\r", "\n", "\r\n", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}"]
        let line = TextCleanup.line(String(text.map { breaks.contains($0) ? " " : $0 }))
        return line.isEmpty ? nil : String(line.prefix(maxAnnotationText))
    }

    /// Starts an annotation's entry: its kind, page, place, author, and whether the file hides it.
    func start(_ annotation: CGPDFDictionaryRef, kind: FileFacts.Annotation.Kind, page: Int, crop: CGRect) -> FileFacts.Annotation? {
        guard let rect = Self.rect(annotation) else { return nil }
        let width = max(crop.width, 1), height = max(crop.height, 1)
        let box = Box(x: Double((rect.minX - crop.minX) / width), y: Double((crop.maxY - rect.maxY) / height),
                      width: Double(rect.width / width), height: Double(rect.height / height))
        var found = FileFacts.Annotation(kind: kind, page: page, box: box)
        found.author = Self.clean(Self.string(annotation, "T"))
        // Set off the page, mostly: a note 1 pt over the edge shows a reader nothing to read.
        let onPage = rect.intersection(crop)
        let shown = onPage.isNull ? 0 : onPage.width * onPage.height
        if hidden(annotation) || rect.width * rect.height < 1 || shown < 0.5 * rect.width * rect.height { found.hidden = true }
        // A reply to a hidden comment is hidden with it.
        var parent: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(annotation, "IRT", &parent), let parent, hidden(parent) { found.hidden = true }
        return found
    }

    /// Whether the file hides an annotation: by its flags, hidden, bit 2, or not to be shown on
    /// screen, bit 6; in a layer switched off, or a membership over one; or fully transparent.
    func hidden(_ annotation: CGPDFDictionaryRef) -> Bool {
        var flags: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(annotation, "F", &flags)
        if flags & (2 | 32) != 0 { return true }
        var opacity: CGPDFReal = 1
        if CGPDFDictionaryGetNumber(annotation, "CA", &opacity), opacity < 0.05 { return true }
        var layer: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(annotation, "OC", &layer), let layer else { return false }
        if layersOff.contains(Self.identity(layer)) { return true }
        var one: CGPDFDictionaryRef?, many: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(layer, "OCGs", &one), let one { return layersOff.contains(Self.identity(one)) }
        if CGPDFDictionaryGetArray(layer, "OCGs", &many), let many {
            return (0..<min(CGPDFArrayGetCount(many), 1_000)).contains { index in
                var member: CGPDFDictionaryRef?
                return CGPDFArrayGetDictionary(many, index, &member) && member.map { layersOff.contains(Self.identity($0)) } == true
            }
        }
        return false
    }

    /// Lists an annotation, up to `maxAnnotations` links and as many others on its page, and
    /// `maxAnnotationsInFile` in the file; past them, `moreAnnotations` and the page's count in
    /// `moreOnPage` count it. Only what would show counts. Pages are read one after another, so
    /// the page's counters start again when the page changes.
    func list(_ found: FileFacts.Annotation) -> Bool {
        let link = found.kind == .link
        if found.page != currentPage {
            currentPage = found.page
            linksListed = 0
            othersListed = 0
        }
        guard (link ? linksListed : othersListed) < Self.maxAnnotations, listedInFile < Self.maxAnnotationsInFile else {
            facts.moreAnnotations += 1
            facts.moreOnPage[found.page, default: 0] += 1
            return false
        }
        listedInFile += 1
        if link { linksListed += 1 } else { othersListed += 1 }
        facts.annotations.append(found)
        return true
    }

    /// Reads a comment, a note, a mark on words or a link from the annotation's dictionary, as
    /// CGPDF holds it: PDFKit, asked for a link's action, followed an action chained to itself
    /// until it crashed.
    func collect(_ annotation: CGPDFDictionaryRef, subtype: String, page: Int, crop: CGRect) {
        let kinds: [String: FileFacts.Annotation.Kind] = ["Text": .comment, "FreeText": .note, "Highlight": .highlight,
                                                          "Underline": .underline, "Squiggly": .squiggly, "StrikeOut": .strikeout,
                                                          "Link": .link, "Stamp": .stamp, "Ink": .ink, "Square": .shape,
                                                          "Circle": .shape, "Line": .shape, "Polygon": .shape, "PolyLine": .shape,
                                                          "Caret": .shape]
        guard let kind = kinds[subtype], var found = start(annotation, kind: kind, page: page, crop: crop) else { return }
        let text = Self.clean(Self.string(annotation, "Contents"))
        switch kind {
        case .comment, .note:
            guard let text else { return }
            found.text = text
            if Self.has(annotation, "IRT") { found.reply = true }
            _ = list(found)
        case .highlight, .underline, .squiggly, .strikeout:
            found.text = text
            guard list(found) else { return }
            underWords.append((facts.annotations.count - 1, page, Self.quads(annotation) ?? [Self.rect(annotation)].compactMap { $0 }))
        case .link:
            var action: CGPDFDictionaryRef?
            let acts = CGPDFDictionaryGetDictionary(annotation, "A", &action)
            if acts, let action, let kind = Self.name(action, "S") {
                switch kind {
                case "URI":
                    // A web or mail address. A link that starts a program or opens a file is a
                    // script, which `pdf info` names and nothing runs.
                    // On one line, with no space, as a reader's browser takes it: a new line in
                    // an address wrote lines of its own into the output.
                    guard let uri = Self.clean(Self.string(action, "URI"))?.replacingOccurrences(of: " ", with: "%20"),
                          let scheme = uri.split(separator: ":").first?.lowercased(),
                          ["http", "https", "mailto", "ftp"].contains(scheme) else { return }
                    found.target = uri
                case "GoTo":
                    guard let destination = Self.destination(action, "D") else { return }
                    found.target = "p.?"
                    pageLinks.append((facts.annotations.count, destination.page, destination.name))
                default:
                    return
                }
            } else if !acts, let destination = Self.destination(annotation, "Dest") {
                found.target = "p.?"
                pageLinks.append((facts.annotations.count, destination.page, destination.name))
            } else {
                return
            }
            guard list(found) else {
                if found.target == "p.?" { pageLinks.removeLast() }
                return
            }
            underWords.append((facts.annotations.count - 1, page, [Self.rect(annotation)].compactMap { $0 }))
        case .stamp, .ink, .shape:
            // What it says, or a stamp's standard name, as "Approved". Any other name is a key a
            // reader never sees: an Acrobat stamp's is a random ID, and a file can name one with a
            // planted line.
            found.text = text ?? (kind == .stamp ? Self.name(annotation, "Name").flatMap { Self.stampNames[$0] } : nil)
            _ = list(found)
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
        // The filled field, where its widget shows it, with its full name and the value a reader
        // sees: never a password, which a viewer shows as dots.
        guard var found = start(widget, kind: .field, page: page, crop: crop) else { return }
        if field != widget, hidden(field) { found.hidden = true }
        found.name = Self.clean(fullName(field))
        if type == "Tx", flags & (1 << 13) != 0 {
            found.value = "a password, not shown"
        } else {
            found.value = Self.clean(value(field, type: type))
        }
        guard found.name != nil, found.value != nil else { return }
        _ = list(found)
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

    /// What a field shows a reader: its text, the choice or choices made, by the text its list
    /// shows for them, "checked" for a box that is, and "signed" for a signature. A box's state
    /// is a name a reader never sees, as a choice's export value is.
    func value(_ field: CGPDFDictionaryRef, type: String?) -> String? {
        if type == "Sig" { return "signed" }
        // A choice's list of [export, shown] pairs, or of the shown texts alone.
        var shown: [String: String] = [:]
        _ = inherited(field) { dictionary -> Bool? in
            var options: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Opt", &options), let options else { return nil }
            for index in 0..<min(CGPDFArrayGetCount(options), 1_000) {
                var pair: CGPDFArrayRef?, export: CGPDFStringRef?, display: CGPDFStringRef?
                if CGPDFArrayGetArray(options, index, &pair), let pair, CGPDFArrayGetString(pair, 0, &export), let export,
                   CGPDFArrayGetString(pair, 1, &display), let display,
                   let key = CGPDFStringCopyTextString(export) as String?, let text = CGPDFStringCopyTextString(display) as String? {
                    shown[key] = text
                }
            }
            return true
        }
        func display(_ value: String) -> String { shown[value] ?? value }
        return inherited(field) { dictionary -> String? in
            if let text = Self.string(dictionary, "V") { return type == "Ch" ? display(text) : text }
            if let name = Self.name(dictionary, "V") { return name == "Off" ? nil : "checked" }
            var choices: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "V", &choices), let choices else { return nil }
            let picked = (0..<min(CGPDFArrayGetCount(choices), 100)).compactMap { index -> String? in
                var item: CGPDFStringRef?
                return CGPDFArrayGetString(choices, index, &item) ? item.flatMap { CGPDFStringCopyTextString($0) as String? }.map(display) : nil
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
        if let sink, wantAttachments, let payload = payload(of: spec, fallback: fallback, page: page) { sink(payload) }
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
            if let sink, wantScripts, handed.insert(Self.identity(action)).inserted {
                sink(Self.payload(of: action, trigger: trigger, page: page))
            }
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
            if let sink, wantScripts, handed.insert(Self.identity(action)).inserted {
                sink(.script(trigger: trigger, kind: "Launch", page: page,
                             text: "The file names this program or file to start: \(target ?? "a program")\nIt was not started.", skipped: nil))
            }
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

// MARK: What `pdf dump` saves

/// An attached file or a script, as the walk of the file meets it. The bytes are only copied
/// out of their streams, never opened, run or launched.
public enum Payload: Sendable {
    case attachment(name: String, page: Int?, data: Data?, skipped: String?)
    case script(trigger: String, kind: String, page: Int?, text: String?, skipped: String?)
}

extension FactReader {
    /// The most one attachment or script may decode to; a stream that decodes past it is skipped.
    static let maxPayload = 256 << 20

    /// The decoded bytes of a stream, or why they were left. A stream with stacked filters is left
    /// at once: each layer can multiply its size by a thousand, and the decoder builds the whole
    /// result before it can be measured.
    static func bytes(_ stream: CGPDFStreamRef) -> (data: Data?, skipped: String?) {
        if let info = CGPDFStreamGetDictionary(stream) {
            var filters: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(info, "Filter", &filters), let filters, CGPDFArrayGetCount(filters) > 1 {
                return (nil, "the stream stacks \(CGPDFArrayGetCount(filters)) filters")
            }
            var length: CGPDFInteger = 0
            let limit = has(info, "Filter") ? maxPayload / 4 : maxPayload
            if CGPDFDictionaryGetInteger(info, "Length", &length), length > limit {
                return (nil, "stored size \(length) bytes is over the limit")
            }
        }
        var format = CGPDFDataFormat.raw
        guard let copy = CGPDFStreamCopyData(stream, &format) else { return (nil, "the stream could not be decoded") }
        let data = copy as Data
        return data.count > maxPayload ? (nil, "decoded size \(data.count) bytes is over the limit") : (data, nil)
    }

    func payload(of spec: CGPDFDictionaryRef, fallback: String, page: Int?) -> Payload? {
        let name = Self.string(spec, "UF") ?? Self.string(spec, "F") ?? fallback
        var files: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(spec, "EF", &files), let files, CGPDFDictionaryGetStream(files, "F", &stream), let stream else {
            return .attachment(name: name, page: page, data: nil, skipped: "the file specification holds no embedded file")
        }
        // Many specifications may name one stream: it is saved once.
        guard handed.insert(unsafeBitCast(stream, to: OpaquePointer.self)).inserted else { return nil }
        let read = Self.bytes(stream)
        return .attachment(name: name, page: page, data: read.data, skipped: read.skipped)
    }

    static func payload(of action: CGPDFDictionaryRef, trigger: String, page: Int?) -> Payload {
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(action, "JS", &stream), let stream {
            let read = bytes(stream)
            return .script(trigger: trigger, kind: "JavaScript", page: page, text: read.data.map(decode), skipped: read.skipped)
        }
        guard let text = string(action, "JS") else {
            return .script(trigger: trigger, kind: "JavaScript", page: page, text: nil, skipped: "the action holds no script text")
        }
        return .script(trigger: trigger, kind: "JavaScript", page: page, text: text, skipped: nil)
    }

    /// A script's bytes as text: UTF-16 when a byte order mark says so, else UTF-8, else Latin-1.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]), let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
