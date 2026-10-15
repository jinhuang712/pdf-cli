// Makes the OCR test files in testdata/ocr/ from the first two pages of a smoke-set paper:
// a scan with no text, a scan with a right hidden text layer, and a scan with a wrong one,
// whose every letter is shifted by one, as a broken font table can make it.
//
// Run from the repo root: swift scripts/make-ocr-fixtures.swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: "testdata/smoke/arxiv-2608.04589.pdf")
let folder = URL(fileURLWithPath: "testdata/ocr", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let document = PDFDocument(url: source)!

/// The page as a grey JPEG at 150 dpi, like a scanner makes.
func scan(_ page: PDFPage) -> CGImage {
    let bounds = page.bounds(for: .cropBox)
    let scale = 150.0 / 72
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
    CGImageDestinationFinalize(destination)
    let jpeg = CGImageSourceCreateWithData(data, nil)!
    return CGImageSourceCreateImageAtIndex(jpeg, 0, nil)!
}

/// Each line of the page's text, with its baseline origin and height in points.
func lines(_ page: PDFPage) -> [(String, CGRect)] {
    guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
    return selection.selectionsByLine().compactMap { line in
        guard let text = line.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return (text, line.bounds(for: page))
    }
}

func shifted(_ text: String) -> String {
    String(text.unicodeScalars.map { scalar -> Character in
        switch scalar {
        case "a"..."y", "A"..."Y": return Character(Unicode.Scalar(scalar.value + 1)!)
        case "z": return "a"
        case "Z": return "A"
        default: return Character(scalar)
        }
    })
}

enum Layer { case none, right, wrong }

func write(_ name: String, layer: Layer) {
    let url = folder.appendingPathComponent(name)
    var box = document.page(at: 0)!.bounds(for: .cropBox)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for index in 0..<2 {
        let page = document.page(at: index)!
        var pageBox = page.bounds(for: .cropBox)
        context.beginPage(mediaBox: &pageBox)
        context.draw(scan(page), in: CGRect(origin: .zero, size: pageBox.size))
        if layer != .none {
            context.setTextDrawingMode(.invisible)
            for (text, rect) in lines(page) {
                let font = CTFontCreateWithName("Helvetica" as CFString, max(rect.height * 0.8, 4), nil)
                let string = layer == .right ? text : shifted(text)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                context.textPosition = CGPoint(x: rect.minX - pageBox.minX, y: rect.minY - pageBox.minY + rect.height * 0.2)
                CTLineDraw(line, context)
            }
        }
        context.endPage()
    }
    context.closePDF()
    print("wrote \(url.path)")
}

write("scan-no-text.pdf", layer: .none)
write("scan-right-layer.pdf", layer: .right)
write("scan-wrong-layer.pdf", layer: .wrong)
