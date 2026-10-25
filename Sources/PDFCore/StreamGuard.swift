import CoreGraphics
import Foundation

/// Counts the drawing operators of a content stream without holding it: CGPDFScanner reads the
/// decoded bytes as it goes, where `CGPDFStreamCopyData` builds all of them, so a stream of 600 KB
/// that inflates to 600 MB (a bomb, M2.21) cost 1.2 GB and 15 s in the page's key alone.
enum StreamGuard {
    /// Operators in one content stream past which a page is not read: 20 million are 80 MB or
    /// more of decoded commands, where the largest maps and CAD drawings hold a few million.
    static let operatorLimit = 20_000_000
    /// A stream with no filter, or a single Flate or RunLength one (ASCII filters only shrink), stored
    /// in this many bytes or fewer decodes to 130 MB at most (Flate holds at most 1,032 bytes to a
    /// byte), so it is copied without counting. Any other filters, such as two Flate ones in an
    /// array, or LZW, multiply the bound and are always counted.
    static let storedBytesChecked = 128 * 1024

    private final class Counter {
        var count = 0
        let limit: Int
        init(limit: Int) { self.limit = limit }
    }

    nonisolated(unsafe) private static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        for name in FontCheck.operatorNames.split(separator: " ") {
            CGPDFOperatorTableSetCallback(table, String(name)) { scanner, info in
                guard let info else { return }
                let counter = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue()
                counter.count += 1
                if counter.count > counter.limit { CGPDFScannerStop(scanner) }
            }
        }
        return table
    }()

    /// How many operators a content stream holds, up to `limit + 1`. Nil for a stream that is
    /// small enough to copy whatever it holds, or that cannot be scanned.
    static func operators(in stream: CGPDFStreamRef, limit: Int = operatorLimit, checking above: Int = storedBytesChecked) -> Int? {
        var declared: CGPDFReal = 0
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        // A length that is missing or no number does not say how big the stream is: it is counted.
        if CGPDFDictionaryGetNumber(dictionary, "Length", &declared), declared <= CGPDFReal(above), boundedFilters(dictionary) { return nil }
        guard let create = FontCheck.createContentStream, let content = create(stream, dictionary, nil) else { return nil }
        defer { CGPDFContentStreamRelease(content) }
        let counter = Counter(limit: limit)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(counter).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
        return counter.count
    }

    /// Whether the stream's filters expand it at most 1,032 times: none, or one of Flate and RunLength,
    /// with any ASCII85 or ASCIIHex ones, which only shrink it.
    static func boundedFilters(_ dictionary: CGPDFDictionaryRef) -> Bool {
        let expanding = Drawing.filters(dictionary).filter { !["ASCII85Decode", "A85", "ASCIIHexDecode", "AHx"].contains($0) }
        return expanding.isEmpty || (expanding.count == 1 && ["FlateDecode", "Fl", "RunLengthDecode", "RL"].contains(expanding[0]))
    }

    /// The failure of a page whose content holds more operators than `limit`.
    static func reason(limit: Int = operatorLimit) -> String {
        "too many drawing commands to read: its content holds more than \(limit >= 1_000_000 ? "\(limit / 1_000_000) million" : "\(limit)") operators, "
            + "as a content stream built to fill memory does"
    }
}
