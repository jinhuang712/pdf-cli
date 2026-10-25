import CoreGraphics
import Foundation

/// The font check (DESIGNS.md → Principles → Silent errors). PDFKit appears to drop the space
/// at a word gap narrower than half the declared width of the font's character 32. A font in
/// LaTeX's T1 layout declares that character as a visible space, twice a normal space, so
/// PDFKit runs most words together.
///
/// The check measures each word gap in the page's text operations, a jump of at least 0.15 em
/// inside a `TJ` array, and counts the gaps that PDFKit would drop. Only body fonts count,
/// fonts that hold at least a quarter of the page's gaps, because a maths font can declare a
/// wide character 32 harmlessly. On the M0 samples, the paper that lost its spaces had 23–38%
/// risky gaps on most pages, and the nine others had none.
public struct FontCheck: Sendable, Equatable {
    /// Word gaps in the page's body fonts.
    public var gaps = 0
    /// The ones PDFKit would drop.
    public var risky = 0
    /// Images the page draws, inline or as objects. A page with an image and no text is a scan.
    public var images = 0
    /// One of the page's content streams declares data and decodes to none, as one whose filter
    /// its data does not match. CGPDF draws nothing of it and says nothing, so what it draws is
    /// missing from the page's text and its image. Only `init(page:)` checks.
    public var damaged = false

    /// A file is at risk when at least 5% of its body-font gaps, and at least 20 of them, are
    /// risky. Then every page gets the space repair.
    public static func atRisk(gaps: Int, risky: Int) -> Bool {
        risky >= 20 && risky * 20 >= gaps
    }

    /// A page is at risk on its own when at least 10% of its body-font gaps, and at least 10
    /// of them, are risky. This catches a file that mixes papers, such as proceedings, where
    /// one paper's fonts hide spaces and the file as a whole stays under 5%.
    public var pageAtRisk: Bool {
        risky >= 10 && risky * 10 >= gaps
    }

    final class Scan {
        var depth = 0
        var font: UnsafeRawPointer?
        var halfSpace: [UnsafeRawPointer: Double?] = [:]
        var byFont: [UnsafeRawPointer: (gaps: Int, risky: Int)] = [:]
        /// What each form adds, so a form drawn many times is read once.
        var forms: [UnsafeRawPointer: [UnsafeRawPointer: (gaps: Int, risky: Int)]] = [:]
        /// Text and form operations counted, against `operationLimit`.
        var operations = 0
        var images = 0
        /// The page's resources, for an old form that has none of its own.
        var pageResources: CGPDFDictionaryRef?
        /// The resources of the nodes above the page, nearest first, for a page read from its
        /// dictionary: CGPDF looks a name the page's resources lack up there for the page's own
        /// content, not for a form's.
        var inherited: [CGPDFDictionaryRef] = []

        /// A resource by name, from the stream's resources, or from those above the page.
        func resource(_ stream: CGPDFContentStreamRef, _ category: String, _ name: UnsafePointer<CChar>) -> CGPDFObjectRef? {
            if let object = CGPDFContentStreamGetResource(stream, category, name) { return object }
            guard depth == 0 else { return nil }
            for resources in inherited {
                var dictionary: CGPDFDictionaryRef?
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetDictionary(resources, category, &dictionary), let dictionary,
                   CGPDFDictionaryGetObject(dictionary, name, &object), let object {
                    return object
                }
            }
            return nil
        }

        func add(_ counts: [UnsafeRawPointer: (gaps: Int, risky: Int)]) {
            for (font, entry) in counts {
                let current = byFont[font] ?? (0, 0)
                byFont[font] = (current.gaps + entry.gaps, current.risky + entry.risky)
            }
        }
    }

    /// Bounds the check's work on a hostile page. A real page has a few thousand operations.
    static let operationLimit = 200_000

    /// Created once and only read afterwards, so sharing it across threads is safe.
    nonisolated(unsafe) static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var size: CGPDFReal = 0
            _ = CGPDFScannerPopNumber(scanner, &size)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = scan.resource(CGPDFScannerGetContentStream(scanner), "Font", name)
            else {
                scan.font = nil
                return
            }
            var font: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &font), let font else {
                scan.font = nil
                return
            }
            let identity = UnsafeRawPointer(font.rawValue)
            if scan.halfSpace[identity] == nil { scan.halfSpace[identity] = FontCheck.halfSpace(font) }
            scan.font = identity
            // A Type 3 font draws its glyphs as pictures, so a scan can hide in one.
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype, String(cString: subtype) == "Type3" {
                scan.images += 1
            }
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            scan.operations += 1
            var array: CGPDFArrayRef?
            guard scan.operations <= operationLimit, CGPDFScannerPopArray(scanner, &array), let array,
                  let font = scan.font else { return }
            let half = scan.halfSpace[font] ?? nil
            var entry = scan.byFont[font] ?? (0, 0)
            for index in 0..<CGPDFArrayGetCount(array) {
                var adjustment: CGPDFReal = 0
                guard CGPDFArrayGetNumber(array, index, &adjustment), adjustment <= -150 else { continue }
                entry.gaps += 1
                if let half, Double(-adjustment) / 1000 < half { entry.risky += 1 }
            }
            scan.byFont[font] = entry
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            scan.operations += 1
            var name: UnsafePointer<CChar>?
            let stream = CGPDFScannerGetContentStream(scanner)
            guard scan.operations <= operationLimit, scan.depth < 4, CGPDFScannerPopName(scanner, &name),
                  let name, let object = scan.resource(stream, "XObject", name) else { return }
            var form: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &form), let form,
                  let dictionary = CGPDFStreamGetDictionary(form) else { return }
            let identity = UnsafeRawPointer(form.rawValue)
            if let counts = scan.forms[identity] {
                scan.add(counts)
                return
            }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            if String(cString: subtype) == "Image" { scan.images += 1 }
            guard String(cString: subtype) == "Form" else { return }
            // A form without its own resources is rare, and old: it uses the page's.
            var own: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
            guard let resources = own ?? scan.pageResources else { return }
            let inner = CGPDFContentStreamCreateWithStream(form, resources, stream)
            defer { CGPDFContentStreamRelease(inner) }
            // A form runs inside its own graphics state: the font it sets ends with it.
            let before = scan.byFont
            let font = scan.font
            scan.depth += 1
            FontCheck.run(inner, scan)
            scan.depth -= 1
            scan.font = font
            var added: [UnsafeRawPointer: (gaps: Int, risky: Int)] = [:]
            for (key, after) in scan.byFont {
                let earlier = before[key] ?? (0, 0)
                if after.gaps > earlier.gaps { added[key] = (after.gaps - earlier.gaps, after.risky - earlier.risky) }
            }
            scan.forms[identity] = added
        }
        // The end of an image drawn inline in the content stream.
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue().images += 1
        }
        return table
    }()

    static func run(_ stream: CGPDFContentStreamRef, _ scan: Scan) {
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(scan).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    /// Half the declared width of character 32, in em, for a simple font that declares it.
    static func halfSpace(_ font: CGPDFDictionaryRef) -> Double? {
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype,
              ["Type1", "TrueType", "MMType1"].contains(String(cString: subtype)) else { return nil }
        var first: CGPDFInteger = 0
        var widths: CGPDFArrayRef?
        var width: CGPDFReal = 0
        guard CGPDFDictionaryGetInteger(font, "FirstChar", &first), first >= 0, first <= 32,
              CGPDFDictionaryGetArray(font, "Widths", &widths), let widths,
              CGPDFArrayGetNumber(widths, 32 - first, &width), width > 0 else { return nil }
        return Double(width) / 2000
    }

    /// Measures one page.
    public init(page: CGPDFPage) {
        let scan = Scan()
        if let dictionary = page.dictionary, let object = PageKeyer.inherited(dictionary, "Resources") {
            var resources: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &resources) { scan.pageResources = resources }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        FontCheck.run(stream, scan)
        self.init(scan)
        damaged = FontCheck.damaged(stream, resources: scan.pageResources)
    }

    /// Whether one of the streams declares 64 bytes or more and holds no operator: a stream whose
    /// filter cannot give its data back gives the scanner nothing. An empty stream, compressed,
    /// takes a few bytes, ASCII85 and Flate together about 20. Each stream is scanned, never copied
    /// out but a short one with no operator: one of 600 KB that inflates to 600 MB took that much
    /// memory copied. A stream whose length is missing or no number is not judged, nor a page with
    /// no resources to scan by.
    static func damaged(_ content: CGPDFContentStreamRef, resources: CGPDFDictionaryRef?) -> Bool {
        guard let resources, let create = createContentStream, let streams = CGPDFContentStreamGetStreams(content) else { return false }
        for index in 0..<CFArrayGetCount(streams) {
            guard let pointer = CFArrayGetValueAtIndex(streams, index) else { continue }
            let stream = CGPDFStreamRef(OpaquePointer(pointer))
            var declared: CGPDFReal = 0
            guard let dictionary = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetNumber(dictionary, "Length", &declared),
                  declared >= 64, let one = create(stream, resources, nil) else { continue }
            defer { CGPDFContentStreamRelease(one) }
            var operators = 0
            withUnsafeMutablePointer(to: &operators) { counter in
                let scanner = CGPDFScannerCreate(one, anyOperator, counter)
                defer { CGPDFScannerRelease(scanner) }
                CGPDFScannerScan(scanner)
            }
            // A stream of only a comment, spaces, or operands whose operator is in the next
            // stream holds no operator either, but decodes to something. It is copied out to tell,
            // only up to 64 KB as declared, since a short stream can inflate a thousandfold.
            guard operators == 0 else { continue }
            if declared > 65_536 { return true }
            var format = CGPDFDataFormat.raw
            if (CGPDFStreamCopyData(stream, &format).map(CFDataGetLength) ?? 0) == 0 { return true }
        }
        return false
    }

    /// The operators of the content stream syntax (PDF 32000, annex A).
    static let operatorNames =
        "b B b* B* BDC BI BMC BT BX c cm CS cs d d0 d1 Do DP EI EMC ET EX f F f* G g gs h i ID j J K k l m M MP n "
        + "q Q re RG rg ri s S SC sc SCN scn sh T* Tc Td TD Tf Tj TJ TL Tm Tr Ts Tw Tz v w W W* y ' \""

    /// Every operator of the content stream syntax, each counted.
    nonisolated(unsafe) private static let anyOperator: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        for name in operatorNames.split(separator: " ") {
            CGPDFOperatorTableSetCallback(table, String(name)) { _, info in
                info?.assumingMemoryBound(to: Int.self).pointee += 1
            }
        }
        return table
    }()

    /// Measures the page whose dictionary is `dictionary`, as `init(page:)` does, reading its
    /// content streams in turn. A name the page's resources lack is looked up in the resources of
    /// the nodes above it, nearest first, as CGPDF looks it up for a page (`Scan.resource`). An operation split between two
    /// streams, which the format allows and files hardly do, goes uncounted. Nil for a page whose
    /// contents are neither a stream nor streams, or that has contents and no resources: the
    /// caller asks CGPDF for the page.
    init?(pageDictionary dictionary: CGPDFDictionaryRef) {
        let scan = Scan()
        // The resources up the tree, nearest first.
        var chain: [CGPDFDictionaryRef] = []
        var node: CGPDFDictionaryRef? = dictionary
        for _ in 0...PageTree.maxDepth + 1 {
            guard let current = node else { break }
            if let object = PageKeyer.object(current, "Resources") {
                var resources: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &resources), let resources else { return nil }
                chain.append(resources)
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        scan.pageResources = chain.first
        scan.inherited = Array(chain.dropFirst())
        var streams: [CGPDFStreamRef] = []
        if let object = PageKeyer.object(dictionary, "Contents") {
            var stream: CGPDFStreamRef?
            var array: CGPDFArrayRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                streams = [stream]
            } else if CGPDFObjectGetValue(object, .array, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var item: CGPDFStreamRef?
                    guard CGPDFArrayGetStream(array, index, &item), let item else { return nil }
                    streams.append(item)
                }
            } else {
                return nil
            }
        }
        if !streams.isEmpty {
            guard let resources = chain.first, let create = Self.createContentStream else { return nil }
            for stream in streams {
                guard let content = create(stream, resources, nil) else { return nil }
                defer { CGPDFContentStreamRelease(content) }
                FontCheck.run(content, scan)
            }
        }
        self.init(scan)
    }

    /// `CGPDFContentStreamCreateWithStream`, which takes no parent stream in C, as its header
    /// says, though Swift's import of it asks for one.
    typealias CreateContentStream =
        @convention(c) (
            CGPDFStreamRef, CGPDFDictionaryRef,
            CGPDFContentStreamRef?
        ) -> CGPDFContentStreamRef?
    static let createContentStream: CreateContentStream? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGPDFContentStreamCreateWithStream") else { return nil }
        return unsafeBitCast(symbol, to: CreateContentStream.self)
    }()

    private init(_ scan: Scan) {
        images = scan.images
        let total = scan.byFont.values.reduce(0) { $0 + $1.gaps }
        for (_, entry) in scan.byFont where entry.gaps * 4 >= max(total, 1) {
            gaps += entry.gaps
            risky += entry.risky
        }
    }

    public init(gaps: Int, risky: Int) {
        self.gaps = gaps
        self.risky = risky
    }
}
