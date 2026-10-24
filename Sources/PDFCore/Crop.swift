import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit

/// What went wrong making a crop.
public struct CropError: Error, CustomStringConvertible {
    public let description: String
}

/// A worker's output, filled by the thread that reads it.
final class Collected: @unchecked Sendable {
    var data = Data()
}

extension Box {
    /// A region as `pdf crop --bbox` takes it: "x,y,width,height" in fractions of the page from
    /// its top left. A region that runs past the page's edge is cut at the edge, since the
    /// regions failure blocks suggest are grown by a line and can reach past it.
    public static func parse(_ text: String) -> Box? {
        let numbers = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, numbers.allSatisfy({ $0 != nil && $0!.isFinite }) else { return nil }
        let x = max(0, numbers[0]!), y = max(0, numbers[1]!)
        func within(_ start: Double, _ length: Double, _ clamped: Double) -> Double {
            start >= 0 && start + length <= 1 ? length : min(start + length, 1) - clamped
        }
        let width = within(numbers[0]!, numbers[2]!, x), height = within(numbers[1]!, numbers[3]!, y)
        guard x < 1, y < 1, width > 0, height > 0 else { return nil }
        return Box(x: x, y: y, width: width, height: height)
    }

    /// The region grown to whole hundredths of the page: its near edges rounded down and its far
    /// edges up, at least a hundredth wide and tall, inside the page. A crop names its image by
    /// this region and draws it, so a region that rounds to nothing still draws its spot.
    public var outward: Box {
        func down(_ value: Double) -> Double { min(max((value * 100 + 1e-6).rounded(.down) / 100, 0), 0.99) }
        func up(_ value: Double) -> Double { min(max((value * 100 - 1e-6).rounded(.up) / 100, 0.01), 1) }
        let left = down(x), top = down(y)
        let right = max(up(x + width), left + 0.01), bottom = max(up(y + height), top + 0.01)
        return Box(x: left, y: top, width: ((right - left) * 100).rounded() / 100, height: ((bottom - top) * 100).rounded() / 100)
    }
}

/// A page, or a region of it, as a PNG that the agent reads with its own image understanding
/// (FEATURES.md → F5). A worker draws it, since drawing opens PDF content (DESIGNS.md →
/// Principles → Safety), and the image stays in the cache folder for 7 days.
public enum Crop {
    /// Claude's standard image limits: 1568 px on the long edge, and 1,568 image tokens, one
    /// per block of 28×28 px. A crop sized within them costs at most about 1,568 tokens on any
    /// model, and no model shrinks it (DESIGNS.md → Decision: crops sized to Claude's standard
    /// image limits).
    static let longEdge = 1568.0
    static let maxTokens = 1568.0
    static let maxPixels = maxTokens * 28 * 28
    /// A small region is enlarged at most 6 times, 432 dpi: more adds no detail to a scan.
    static let maxScale = 6.0
    /// How long a crop is kept before the same command draws it again.
    public static let keep: TimeInterval = 7 * 24 * 3600

    /// The image tokens Claude counts for an image of this size.
    public static func tokens(width: Int, height: Int) -> Int {
        ((width + 27) / 28) * ((height + 27) / 28)
    }

    // MARK: Drawing

    /// A point of the stored page, in fractions from its top left, on the page as shown: PDFKit
    /// turns a page clockwise by its rotation when it draws it.
    static func shown(_ x: Double, _ y: Double, rotation: Int) -> (x: Double, y: Double) {
        switch rotation {
        case 90: return (1 - y, x)
        case 180: return (1 - x, 1 - y)
        case 270: return (y, 1 - x)
        default: return (x, y)
        }
    }

    static func shown(_ box: Box, rotation: Int) -> Box {
        let a = shown(box.x, box.y, rotation: rotation), b = shown(box.x + box.width, box.y + box.height, rotation: rotation)
        return Box(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Draws `region` of the page, in fractions of the stored page from its top left as block
    /// boxes give them, upright, with its annotations as a reader sees them. With `grid`, lines
    /// labelled in the same fractions help the agent pick a smaller region.
    public static func render(_ page: PDFPage, region: Box, grid: Bool) -> CGImage? {
        let rotation = ((page.rotation % 360) + 360) % 360
        let bounds = page.bounds(for: .cropBox)
        let size = rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let box = shown(region, rotation: rotation)
        let rect = CGRect(x: box.x * size.width, y: (1 - box.y - box.height) * size.height,
                          width: box.width * size.width, height: box.height * size.height)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        var scale = min(longEdge / max(rect.width, rect.height), (maxPixels / (rect.width * rect.height)).squareRoot(), maxScale)
        var width = 1, height = 1
        // Claude counts whole blocks of 28 px, so the size shrinks until the count fits.
        repeat {
            width = max(1, Int((rect.width * scale).rounded(.down)))
            height = max(1, Int((rect.height * scale).rounded(.down)))
            scale *= 0.99
        } while tokens(width: width, height: height) > Int(maxTokens)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        if grid {
            // A point of the stored page, in pixels of the image, from its lower left.
            func pixel(_ x: Double, _ y: Double) -> CGPoint {
                let point = shown(x, y, rotation: rotation)
                return CGPoint(x: (point.x * size.width - rect.minX) * scale, y: ((1 - point.y) * size.height - rect.minY) * scale)
            }
            drawGrid(context, region: region, pixel: pixel, fontSize: max(13, Double(min(width, height)) / 50))
        }
        return context.makeImage()
    }

    /// Lines at round fractions of the stored page, four to ten across each side of the region,
    /// each labelled "x 0.30" or "y 0.40".
    static func drawGrid(_ context: CGContext, region: Box, pixel: (Double, Double) -> CGPoint, fontSize: Double) {
        func values(from start: Double, length: Double) -> [Double] {
            let step = [0.1, 0.05, 0.02, 0.01].first { length / $0 >= 4 } ?? 0.01
            var values: [Double] = []
            var value = (start / step).rounded(.up) * step
            while value <= start + length + 1e-9 {
                if value > start + 1e-9 && value < start + length - 1e-9 { values.append((value * 100).rounded() / 100) }
                value += step
            }
            return values
        }
        let red = CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.6)
        context.setStrokeColor(red)
        context.setLineWidth(1)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        func label(_ text: String, at point: CGPoint) {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.8, green: 0, blue: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let origin = CGPoint(x: min(max(point.x + 3, 2), Double(context.width) - bounds.width - 4),
                                 y: min(max(point.y - bounds.height - 2, 2), Double(context.height) - bounds.height - 4))
            context.setFillColor(CGColor(gray: 1, alpha: 0.7))
            context.fill(CGRect(x: origin.x - 2, y: origin.y - 2, width: bounds.width + 4, height: bounds.height + 4))
            context.textPosition = CGPoint(x: origin.x, y: origin.y - bounds.minY)
            CTLineDraw(line, context)
        }
        for x in values(from: region.x, length: region.width) {
            let top = pixel(x, region.y), bottom = pixel(x, region.y + region.height)
            context.strokeLineSegments(between: [top, bottom])
            label(String(format: "x %.2f", x), at: top.y > bottom.y ? top : bottom)
        }
        for y in values(from: region.y, length: region.height) {
            let left = pixel(region.x, y), right = pixel(region.x + region.width, y)
            context.strokeLineSegments(between: [left, right])
            label(String(format: "y %.2f", y), at: CGPoint(x: min(left.x, right.x), y: max(left.y, right.y)))
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: Making a crop

    /// A crop made or found.
    public struct Made: Sendable {
        public var url: URL
        public var width: Int
        public var height: Int
        /// True when the image was already in the cache folder.
        public var kept: Bool
    }

    static var folder: URL { Env.cacheDirectory.appendingPathComponent("crops", isDirectory: true) }

    /// The folder for one version of a file: its path and its state, since two copies of a file
    /// can carry other comments and highlights, and a crop shows them.
    static func folder(path: String, stat: FileStat) -> URL {
        let digest = SHA256.hash(data: Data("\(path)\u{0}\(stat.size)\u{0}\(stat.modifiedNanos)\u{0}\(stat.inode)\u{0}\(stat.device)".utf8))
        return folder.appendingPathComponent(digest.prefix(8).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    /// Makes the crop of page `page`, counted from 1, or finds it in the cache folder when it was
    /// made in the last 7 days. `region` is in fractions of the stored page; nil is the whole page.
    public static func make(path: String, page: Int, region requested: Box?, grid: Bool, password: String? = nil) throws -> Made {
        let resolved = Reader.resolve(path)
        guard let stat = FileStat(path: resolved) else { throw ReadError.notFound(path) }
        removeOld()
        // The region the image is named by is the one it draws, rounded outward, and the worker
        // gets it in the same words.
        let region = requested?.outward
        let directory = folder(path: resolved, stat: stat)
        let url = directory.appendingPathComponent("p\(page)" + (region.map { "-" + Output.format($0) } ?? "") + (grid ? "-grid" : "") + ".png")
        if let made = existing(url) { return made }
        // The worker makes the folder again right before it writes, in case a cleanup took it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: partial) }
        var arguments = ["__worker", "crop", resolved, "--pages=\(page - 1)", "--out", partial.path]
        if let region { arguments += ["--bbox", Output.format(region)] }
        if grid { arguments.append("--grid") }
        // The password reaches the worker in its environment, never its command line (DESIGNS.md →
        // Decision: a password reaches the workers in their environment).
        let event = try runWorker(arguments, environment: password.map { [Env.passwordVariable: $0] } ?? [:])
        if let reason = event?.reason { throw CropError(description: reason) }
        guard event?.kind == .result, FileManager.default.fileExists(atPath: partial.path) else {
            throw CropError(description: "the reader stopped before the image was made")
        }
        // rename(2) replaces the image at once, so two crops of one region that finish together
        // both leave a whole image.
        guard Darwin.rename(partial.path, url.path) == 0 else {
            throw CropError(description: "the image could not be saved: \(String(cString: strerror(errno)))")
        }
        guard var made = existing(url) else { throw CropError(description: "the image could not be read back") }
        made.kept = false
        return made
    }

    /// A crop in the cache folder that is younger than 7 days, with its size.
    static func existing(_ url: URL) -> Made? {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(modified) < keep,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return Made(url: url, width: width, height: height, kept: true)
    }

    /// What a sweep of the crop folder removed, or would.
    public struct Swept: Equatable, Sendable {
        public var images = 0
        public var bytes: Int64 = 0
    }

    /// Removes crops older than 7 days, partial images that a stopped crop left more than an hour
    /// ago, and folders empty for more than an hour: a folder another crop just made is empty
    /// while that crop waits for its worker. Returns how many images it removed.
    @discardableResult
    public static func removeOld() -> Int { sweep().images }

    /// `removeOld` with the bytes it freed. With `dryRun` it counts the same and removes nothing.
    public static func sweep(dryRun: Bool = false, in directory: URL? = nil) -> Swept {
        let folder = directory ?? Crop.folder
        let manager = FileManager.default
        var swept = Swept()
        func age(_ url: URL) -> TimeInterval {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Date().timeIntervalSince(modified)
        }
        func size(_ url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        for directory in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let partial = file.lastPathComponent.hasPrefix(".")
                guard age(file) >= (partial ? 3600 : keep) else { continue }
                let bytes = size(file)
                if dryRun || (try? manager.removeItem(at: file)) != nil {
                    if !partial {
                        swept.images += 1
                        swept.bytes += bytes
                    }
                }
            }
            if !dryRun, age(directory) >= 3600, ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty {
                try? manager.removeItem(at: directory)
            }
        }
        return swept
    }

    /// The images in the crop folder, and their bytes.
    public static func usage(in directory: URL? = nil) -> Swept {
        let folder = directory ?? Crop.folder
        var swept = Swept()
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            swept.images += 1
            swept.bytes += Int64(values?.fileSize ?? 0)
        }
        return swept
    }

    /// Runs one worker in a slot of the pool, within the time and memory limits a page has, and
    /// returns the last event it reported.
    static func runWorker(_ arguments: [String], environment: [String: String] = [:]) throws -> WorkerEvent? {
        var slot = WorkerPool.acquire(foreground: true)
        while slot == nil {
            Thread.sleep(forTimeInterval: 0.02)
            slot = WorkerPool.acquire(foreground: true)
        }
        defer { slot?.release() }
        let (pid, output) = try Processes.spawn(Env.executablePath, arguments, detached: false, captureOutput: true,
                                                environment: environment)
        // The output is read while the worker runs, so a worker that writes much never waits on
        // a full pipe.
        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        if let output {
            DispatchQueue.global().async {
                collected.data = FileHandle(fileDescriptor: output, closeOnDealloc: true).readDataToEndOfFile()
                done.signal()
            }
        } else {
            done.signal()
        }
        let started = Date()
        var status: Int32?
        var stopped: String?
        while status == nil {
            Thread.sleep(forTimeInterval: 0.02)
            status = Processes.reap(pid)
            guard status == nil else { break }
            if Date().timeIntervalSince(started) > Env.pageTimeLimit {
                stopped = "time limit: the page took more than \(Int(Env.pageTimeLimit)) s to draw"
            } else if let footprint = Processes.footprint(of: pid), footprint > Env.memoryLimitBytes {
                stopped = "memory limit: the reader used more than \(Env.memoryLimitBytes >> 20) MB"
            }
            if stopped != nil {
                kill(pid, SIGKILL)
                while status == nil { status = Processes.reap(pid) ?? { Thread.sleep(forTimeInterval: 0.01); return nil }() }
            }
        }
        done.wait()
        let data = collected.data
        if let stopped { throw CropError(description: stopped) }
        let last = data.split(separator: 0x0A).last.flatMap { try? JSONDecoder().decode(WorkerEvent.self, from: Data($0)) }
        if last == nil, let status, !Processes.exitedCleanly(status: status) {
            throw CropError(description: "the reader " + (status & 0x7f == 0 ? "stopped: " : "crashed: ") + Processes.describe(status: status))
        }
        return last
    }
}
