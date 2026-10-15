import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFCore

@Suite struct CropTests {
    /// A one-page PDF of 600×800 pt with a black rectangle at `box`, in fractions of the page
    /// from its top left, turned by `rotation`.
    func page(black box: Box, rotation: Int) throws -> PDFPage {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: box.x * 600, y: (1 - box.y - box.height) * 800, width: box.width * 600, height: box.height * 800))
        context.endPDFPage()
        context.closePDF()
        let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))
        page.rotation = rotation
        return page
    }

    /// The share of dark pixels in an image.
    func darkness(_ image: CGImage) throws -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(pixels.filter { $0 < 64 }.count) / Double(pixels.count)
    }

    /// A region, as block boxes give it, crops the same spot of the page at every rotation.
    @Test(arguments: [0, 90, 180, 270])
    func aRegionCropsTheSameSpotAtEveryRotation(rotation: Int) throws {
        let black = Box(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        let page = try page(black: black, rotation: rotation)
        let inside = try #require(Crop.render(page, region: Box(x: 0.12, y: 0.12, width: 0.2, height: 0.1), grid: false))
        #expect(try darkness(inside) > 0.95)
        let outside = try #require(Crop.render(page, region: Box(x: 0.5, y: 0.5, width: 0.3, height: 0.3), grid: false))
        #expect(try darkness(outside) < 0.01)
        let whole = try #require(Crop.render(page, region: Box(x: 0, y: 0, width: 1, height: 1), grid: false))
        #expect(abs(try darkness(whole) - 0.06) < 0.01)
        // The page comes out upright: turned a quarter, it is wider than tall.
        #expect((whole.width > whole.height) == (rotation % 180 != 0))
    }

    /// A crop fits Claude's standard limits, so no model shrinks it.
    @Test func aCropFitsClaudesImageLimits() throws {
        let page = try page(black: Box(x: 0, y: 0, width: 0.1, height: 0.1), rotation: 0)
        let whole = try #require(Crop.render(page, region: Box(x: 0, y: 0, width: 1, height: 1), grid: true))
        #expect(max(whole.width, whole.height) <= 1568)
        #expect(Crop.tokens(width: whole.width, height: whole.height) <= 1568)
        let strip = try #require(Crop.render(page, region: Box(x: 0, y: 0.5, width: 1, height: 0.05), grid: false))
        #expect(strip.width == 1568)
        let tiny = try #require(Crop.render(page, region: Box(x: 0.5, y: 0.5, width: 0.01, height: 0.01), grid: false))
        #expect(tiny.width == 36)
    }

    @Test func aRegionThatRunsPastTheEdgeIsCutThere() {
        #expect(Box.parse("0.1,0.2,0.3,0.4") == Box(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(Box.parse("0.9,0.9,0.3,0.3").map { [$0.width, $0.height].map { ($0 * 100).rounded() } } == [10, 10])
        #expect(Box.parse("1,1,0.1,0.1") == nil)
        #expect(Box.parse("0.1,0.2,0.3") == nil)
        #expect(Box.parse("a,b,c,d") == nil)
    }
}
