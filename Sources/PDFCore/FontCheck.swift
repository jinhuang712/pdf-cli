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
        var operations = 0
    }

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
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array, let font = scan.font else { return }
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
            var name: UnsafePointer<CChar>?
            let stream = CGPDFScannerGetContentStream(scanner)
            guard scan.depth < 4, CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
            var form: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &form), let form,
                  let dictionary = CGPDFStreamGetDictionary(form) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return }
            // A form without its own resources is rare, and old: the check skips it.
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
            let inner = CGPDFContentStreamCreateWithStream(form, resources, stream)
            defer { CGPDFContentStreamRelease(inner) }
            scan.depth += 1
            FontCheck.run(inner, scan)
            scan.depth -= 1
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
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        FontCheck.run(stream, scan)
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
