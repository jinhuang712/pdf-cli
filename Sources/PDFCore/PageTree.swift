import CoreGraphics

/// A document's pages from one walk of its page tree, for the index. CGPDF finds a page by its
/// number from the top of the tree, which takes longer the more pages share a node: listing a
/// flat tree of 30,000 pages page by page took 17 s.
///
/// The walk serves only a tree it numbers as CGPDF does: each node a /Pages node with its /Kids
/// and a true /Count, or a /Page with neither, which CGPDF would count as a node; each kid naming
/// its node as /Parent; no node twice; as many pages as CGPDF counts; and CGPDF's own pages where
/// the walk puts them, at five places through the file. For any other tree it gives nil, and the
/// index asks CGPDF for each page, as before: a page numbered otherwise would store one page's
/// text under another's key, which any file holding that other page would read.
struct PageTree {
    static let maxDepth = 64

    let pages: [CGPDFDictionaryRef]

    init?(_ document: CGPDFDocument) {
        let count = document.numberOfPages
        var root: CGPDFDictionaryRef?
        var parent: CGPDFDictionaryRef?
        guard count > 0, let catalog = document.catalog, CGPDFDictionaryGetDictionary(catalog, "Pages", &root), let root,
              !CGPDFDictionaryGetDictionary(root, "Parent", &parent) else { return nil }
        var pages: [CGPDFDictionaryRef] = []
        pages.reserveCapacity(count)
        var seen = Set<OpaquePointer>()
        guard Self.walk(root, parent: nil, depth: 0, limit: count, seen: &seen, into: &pages) != nil,
              pages.count == count else { return nil }
        for number in Set([1, (count + 3) / 4, (count + 1) / 2, (3 * count + 3) / 4, count].map { min(max($0, 1), count) }) {
            guard let dictionary = document.page(at: number)?.dictionary,
                  FactReader.identity(dictionary) == FactReader.identity(pages[number - 1]) else { return nil }
        }
        self.pages = pages
    }

    /// Adds the pages under `node` to `pages`, and gives how many, or nil where the tree is not
    /// one the walk serves.
    private static func walk(_ node: CGPDFDictionaryRef, parent: CGPDFDictionaryRef?, depth: Int, limit: Int,
                             seen: inout Set<OpaquePointer>, into pages: inout [CGPDFDictionaryRef]) -> Int? {
        guard depth <= maxDepth, pages.count <= limit, seen.insert(FactReader.identity(node)).inserted else { return nil }
        if let parent {
            var named: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &named), let named,
                  FactReader.identity(named) == FactReader.identity(parent) else { return nil }
        }
        switch FactReader.name(node, "Type") {
        case "Page":
            // CGPDF takes a node with kids for a node, whatever its type says, and counts by its
            // /Count: a page with either could number the pages after it otherwise.
            guard PageKeyer.object(node, "Kids") == nil, PageKeyer.object(node, "Count") == nil else { return nil }
            pages.append(node)
            return 1
        case "Pages":
            var kids: CGPDFArrayRef?
            var count: CGPDFInteger = 0
            guard CGPDFDictionaryGetArray(node, "Kids", &kids), let kids,
                  CGPDFDictionaryGetInteger(node, "Count", &count) else { return nil }
            var total = 0
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(kids, index, &kid), let kid,
                      let added = walk(kid, parent: node, depth: depth + 1, limit: limit, seen: &seen, into: &pages)
                else { return nil }
                total += added
            }
            return total == count ? total : nil
        default:
            return nil
        }
    }
}

/// What the page key takes from CGPDF's page: its media box, crop box and rotation.
struct PageGeometry {
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    var mediaBox: CGRect
    var cropBox: CGRect
    var rotation: Int32

    init(_ page: CGPDFPage) {
        mediaBox = page.getBoxRect(.mediaBox)
        cropBox = page.getBoxRect(.cropBox)
        rotation = page.rotationAngle
    }

    /// The geometry read from the page's dictionary by CGPDF's rules, as measured on macOS 26:
    /// a box is the nearest one of four numbers up the tree, with its corners in either order;
    /// the media box is US Letter without one, the crop box the media box; the rotation is the
    /// nearest /Rotate as written, 0 without one. Nil where an entry is anything else, such as a
    /// box of three numbers, which CGPDF passes over for its parent's: the caller asks CGPDF.
    init?(dictionary: CGPDFDictionaryRef) {
        var media: CGRect?
        var crop: CGRect?
        var rotation: Int32?
        var current: CGPDFDictionaryRef? = dictionary
        for _ in 0...PageTree.maxDepth + 1 {
            guard let node = current else { break }
            if media == nil, PageKeyer.object(node, "MediaBox") != nil {
                guard let box = Self.box(node, "MediaBox") else { return nil }
                media = box
            }
            if crop == nil, PageKeyer.object(node, "CropBox") != nil {
                guard let box = Self.box(node, "CropBox") else { return nil }
                crop = box
            }
            if rotation == nil, PageKeyer.object(node, "Rotate") != nil {
                var value: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(node, "Rotate", &value), let exact = Int32(exactly: value) else { return nil }
                rotation = exact
            }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(node, "Parent", &parent) ? parent : nil
        }
        guard current == nil else { return nil }
        mediaBox = media ?? Self.letter
        cropBox = crop ?? mediaBox
        self.rotation = rotation ?? 0
    }

    /// A box of four numbers, with its corners in either order. Nil for a box with -0, whose sign
    /// CGPDF keeps in a way the key would hash otherwise.
    static func box(_ dictionary: CGPDFDictionaryRef, _ name: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, name, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values: [CGFloat] = []
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value), !(value == 0 && value.sign == .minus) else { return nil }
            values.append(value)
        }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }
}
