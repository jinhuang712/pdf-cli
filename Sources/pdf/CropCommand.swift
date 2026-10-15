import ArgumentParser
import Foundation
import PDFCore

/// Turns a page, or a region of it, into an image the agent reads with its own image
/// understanding (FEATURES.md → F5). It prints the image's absolute path.
struct CropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crop",
        abstract: "Turn a page, or a region of it, into an image, and print its path.",
        discussion: """
            --bbox takes x,y,width,height in fractions of the page from its top left, as pdf read --json and \
            the warnings in pdf read give them. --grid draws lines labelled in the same fractions. Images stay \
            in the cache folder for 7 days.
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(help: ArgumentHelp("The page, by its position in the file.", valueName: "N")) var page: Int
    @Option(help: ArgumentHelp("A region: x,y,width,height in fractions of the page, such as 0.1,0.4,0.8,0.3.",
                               valueName: "region"))
    var bbox: String?
    @Flag(help: "Draw lines labelled with page fractions, to help pick a region.") var grid = false
    @Flag(help: "Read the password of a locked PDF from standard input, as in: echo \"$PW\" | pdf crop paper.pdf --page 1 --password-stdin")
    var passwordStdin = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if page < 1 { throw ValidationError("--page takes a page number, 1 or more") }
        if let bbox, Box.parse(bbox) == nil {
            throw ValidationError("--bbox takes x,y,width,height in fractions of the page, such as 0.1,0.4,0.8,0.3")
        }
    }

    func run() throws {
        let store = try Store()
        let password = passwordStdin ? readLine(strippingNewline: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : nil
        switch try Reader(store: store, library: try Library()).read(path: path, pages: [], password: password) {
        case .fileFailed(let reason):
            print(json ? ReadCommand.failureJSON(path, reason) : "\(path): failed: \(Output.failure(reason, file: path))")
            throw ExitCode(3)
        case .pages(_, let pageCount, _):
            guard page <= pageCount else { throw ReadError.pageOutOfRange(page: page - 1, pageCount: pageCount) }
        }
        let region = bbox.flatMap(Box.parse)
        let made: Crop.Made
        do {
            made = try Crop.make(path: path, page: page, region: region, grid: grid, password: password)
        } catch let error as CropError {
            let message = "p.\(page) could not be drawn: \(error.description)"
            if json {
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["file": path, "page": page, "failed": message],
                                                                  options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            } else {
                print("\(path): \(message)")
            }
            throw ExitCode(1)
        }
        let tokens = Crop.tokens(width: made.width, height: made.height)
        if json {
            struct Body: Encodable {
                var file: String
                var page: Int
                var bbox: String?
                var image: String
                var width: Int
                var height: Int
                var tokens: Int
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            print(String(decoding: try encoder.encode(Body(file: path, page: page, bbox: region.map(Output.format), image: made.url.path,
                                                           width: made.width, height: made.height, tokens: tokens)),
                         as: UTF8.self))
        } else {
            print("\(made.url.path)  (~\(Info.thousands(tokens)) image tokens, \(made.width)×\(made.height) px)")
        }
    }
}
