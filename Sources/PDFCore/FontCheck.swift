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
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name)
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
                  let name, let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
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
        guard CGPDFDictionaryGetInteger(font, "FirstChar", &first), first <= 32,
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
