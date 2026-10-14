import ArgumentParser
import CoreGraphics
import Foundation
import PDFKit
import Vision

/// M0.3: renders pages and runs Apple's document recognizer on them, to test
/// whether its reading order is usable on born-digital pages.
struct SpikeDocs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs",
        abstract: "Run Apple's document recognizer on rendered pages, one JSON object per page."
    )

    @Argument(help: "Path to a PDF file.")
    var path: String

    @Option(help: "Pages to read, such as 2 or 1-3. Default: every page.")
    var pages: String?

    @Option(help: "Render resolution in dots per inch.")
    var dpi: Double = 200

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("The document recognizer needs macOS 26.")
        }
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else {
            throw ValidationError("PDFKit could not open \(path)")
        }
        let range = try pageRange(pageCount: document.pageCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        for number in range {
            guard let page = document.page(at: number - 1) else { continue }
            let renderStart = DispatchTime.now().uptimeNanoseconds
            guard let image = render(page, dpi: dpi) else {
                throw ValidationError("Could not render page \(number)")
            }
            let renderMs = milliseconds(since: renderStart)

            let visionStart = DispatchTime.now().uptimeNanoseconds
            let observations = try await RecognizeDocumentsRequest().perform(on: image)
            let visionMs = milliseconds(since: visionStart)

            let container = observations.first?.document
            let record = PageDocs(
                page: number,
                dpi: dpi,
                renderMs: renderMs,
                visionMs: visionMs,
                title: container?.title?.transcript,
                paragraphs: (container?.paragraphs ?? []).map { Block(bbox: box($0.boundingRegion), text: $0.transcript) },
                tables: (container?.tables ?? []).map { table in
                    TableInfo(bbox: box(table.boundingRegion), rows: table.rows.count, columns: table.columns.count)
                },
                lists: (container?.lists ?? []).map { list in
                    ListInfo(bbox: box(list.boundingRegion), items: list.items.map(\.itemString))
                }
            )
            var line = try encoder.encode(record)
            line.append(0x0A)
            FileHandle.standardOutput.write(line)
        }
    }

    private func pageRange(pageCount: Int) throws -> ClosedRange<Int> {
        guard let pages else { return 1...max(pageCount, 1) }
        let parts = pages.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first, first >= 1, (parts.last ?? first) <= pageCount, parts.count <= 2 else {
            throw ValidationError("Pages must look like 2 or 1-3, within 1-\(pageCount).")
        }
        return first...(parts.last ?? first)
    }
}

/// Renders a page's crop box to an sRGB bitmap on a white background.
func render(_ page: PDFPage, dpi: Double) -> CGImage? {
    let bounds = page.bounds(for: .cropBox)
    let scale = dpi / 72
    let width = Int((bounds.width * scale).rounded())
    let height = Int((bounds.height * scale).rounded())
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)
    return context.makeImage()
}

/// A Vision region as [x, y, width, height] in page fractions, with y measured from the top.
@available(macOS 26, *)
func box(_ region: NormalizedRegion) -> [Double] {
    let rect = region.normalizedPath.boundingBoxOfPath
    let round3 = { (value: CGFloat) in (Double(value) * 1000).rounded() / 1000 }
    return [round3(rect.minX), round3(1 - rect.maxY), round3(rect.width), round3(rect.height)]
}

func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

struct PageDocs: Encodable {
    let page: Int
    let dpi: Double
    let renderMs: Double
    let visionMs: Double
    let title: String?
    let paragraphs: [Block]
    let tables: [TableInfo]
    let lists: [ListInfo]
}

struct Block: Encodable {
    let bbox: [Double]
    let text: String
}

struct TableInfo: Encodable {
    let bbox: [Double]
    let rows: Int
    let columns: Int
}

struct ListInfo: Encodable {
    let bbox: [Double]
    let items: [String]
}
