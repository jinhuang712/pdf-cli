import ArgumentParser
import Foundation
import PDFCore

/// Turns a page, a region of it, or a figure, a table or an equation into an image the agent
/// reads with its own image understanding (FEATURES.md → F5). It prints the image's absolute path.
struct CropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crop",
        abstract: "Turn a page, a region of it, or a figure, a table or an equation into an image, and print its path.",
        discussion: """
            --bbox takes x,y,width,height in fractions of the page from its top left, as pdf read --json and \
            the warnings in pdf read give them. --grid draws lines labelled in the same fractions. --figure, \
            --table and --equation take the number their caption gives, as pdf read and pdf info show it; \
            --page picks one where two share a number. Images stay in the cache folder for 7 days.
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(help: ArgumentHelp("The page, by its position in the file.", valueName: "N")) var page: Int?
    @Option(help: ArgumentHelp("A region: x,y,width,height in fractions of the page, such as 0.1,0.4,0.8,0.3.",
                               valueName: "region"))
    var bbox: String?
    @Option(help: ArgumentHelp("A figure, by the number its caption gives, such as 4 or 2.1.", valueName: "N")) var figure: String?
    @Option(help: ArgumentHelp("A table, by the number its caption gives, such as 1 or IV.", valueName: "N")) var table: String?
    @Option(help: ArgumentHelp("A numbered equation, such as 5.", valueName: "N")) var equation: String?
    @Flag(help: "Draw lines labelled with page fractions, to help pick a region.") var grid = false
    @Flag(help: "Read the password of a locked PDF from standard input, as in: echo \"$PW\" | pdf crop paper.pdf --page 1 --password-stdin")
    var passwordStdin = false
    @Flag(help: "Print JSON.") var json = false

    /// The figure, table or equation asked for, if one is.
    var wanted: (kind: Region.Kind, number: String)? {
        if let figure { return (.figure, figure) }
        if let table { return (.table, table) }
        return equation.map { (.equation, $0) }
    }

    func validate() throws {
        if let page, page < 1 { throw ValidationError("--page takes a page number, 1 or more") }
        if let bbox, Box.parse(bbox) == nil {
            throw ValidationError("--bbox takes x,y,width,height in fractions of the page, such as 0.1,0.4,0.8,0.3")
        }
        if [figure, table, equation].compactMap({ $0 }).count > 1 {
            throw ValidationError("--figure, --table and --equation take one at a time")
        }
        if wanted != nil, bbox != nil { throw ValidationError("--bbox crops a region of a page; --figure, --table and --equation crop their own") }
        if wanted == nil, page == nil { throw ValidationError("give --page, or --figure, --table or --equation") }
    }

    func run() throws {
        let store = try Store()
        let password = passwordStdin ? Password.read(for: path) : nil
        // A locked file needs its password on every crop, since none is stored.
        let unlock = " · crop it with: echo \"$PW\" | pdf crop \(Output.quoted(path))" + (page.map { " --page \($0)" } ?? "") + " --password-stdin"
        let reader = Reader(store: store, library: try Library())
        let docID: String
        switch try reader.read(path: path, pages: [], password: password) {
        case .fileFailed(let reason):
            let shown = reason.hasPrefix(OpenFailure.locked) ? reason + unlock : reason
            print(json ? ReadCommand.failureJSON(path, shown) : "\(path): failed: \(shown)")
            throw ExitCode(3)
        case .pages(let id, let pageCount, _):
            if let page, page > pageCount { throw ReadError.pageOutOfRange(page: page - 1, pageCount: pageCount) }
            docID = id
        }
        var number = page ?? 1
        var region = bbox.flatMap(Box.parse)?.outward
        var caption: String?
        // An equation's LaTeX that the agent kept, to check against the image, and the number to
        // keep one by.
        var kept: Transcript?
        var equationNumber: String?
        if let wanted {
            let found = try Self.locate(wanted, page: page, path: path, password: password, docID: docID, store: store, reader: reader)
            number = found.page + 1
            region = found.region.box.outward
            caption = found.caption
            if wanted.kind == .equation {
                equationNumber = found.region.number
                let keys = try store.pageKeys(docID: docID)
                if keys.indices.contains(found.page) {
                    kept = try Transcripts().transcripts(keys: [keys[found.page]])[keys[found.page]]?
                        .first { $0.kind == .equation && $0.number == Region.normalized(found.region.number) }
                }
            }
        }
        let made: Crop.Made
        do {
            made = try Crop.make(path: path, page: number, region: region, grid: grid, password: password)
        } catch {
            let reason = (error as? CropError)?.description ?? "\(error)"
            let message = "p.\(number) could not be drawn: \(reason)" + (reason.hasPrefix(OpenFailure.locked) ? unlock : "")
            if json {
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["file": path, "page": number, "failed": message],
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
                var caption: String?
                var latex: String?
                var transcribed: String?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            print(String(decoding: try encoder.encode(Body(file: path, page: number, bbox: region.map(Output.format), image: made.url.path,
                                                           width: made.width, height: made.height, tokens: tokens, caption: caption,
                                                           latex: kept?.text, transcribed: kept?.day)),
                         as: UTF8.self))
        } else {
            print("\(made.url.path)  (~\(Info.thousands(tokens)) image tokens, \(made.width)×\(made.height) px)")
            if let equationNumber {
                let keep = "pdf transcribe \(Output.quoted(path)) --page \(number) --equation \(equationNumber) <<'EOF'"
                if let kept {
                    print("p.\(number) · LaTeX kept \(kept.day), which pdf read shows; check it against the image, and replace it with: \(keep)")
                    print(kept.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n"))
                } else {
                    print("p.\(number) · once read, keep its LaTeX for later reads: \(keep), then the LaTeX, then EOF")
                }
            } else if let caption, !caption.isEmpty {
                print("p.\(number) · caption: \(caption)")
            } else if wanted != nil {
                print("p.\(number)")
            }
        }
    }

    /// Why the figure, table or equation asked for was not cropped: an error with no usage
    /// after it, as the command was used right.
    struct NotFound: Error, CustomStringConvertible {
        var description: String
    }

    /// The figure, table or equation asked for: on the page given, or else in the pages parsed so
    /// far, or else, when none of those holds it, in the whole file once it is parsed.
    static func locate(_ wanted: (kind: Region.Kind, number: String), page: Int?, path: String, password: String?, docID: String,
                       store: Store, reader: Reader) throws -> (page: Int, region: Region, caption: String) {
        func layers() throws -> [(index: Int, layer: PDFCore.PageText)] {
            try InfoCommand.cachedPages(docID: docID, store: store).compactMap { page -> (index: Int, layer: PDFCore.PageText)? in
                page.result.pageText.map { (page.index, $0) }
            }
        }
        var pages = try layers()
        if let page { pages = pages.filter { $0.index == page - 1 } }
        var found = Region.find(wanted.kind, wanted.number, in: pages)
        let keys = try store.pageKeys(docID: docID)
        if found.isEmpty, page != nil || pages.count < keys.count {
            _ = try reader.read(path: path, pages: page.map { [$0 - 1] }, password: password)
            pages = try layers()
            if let page { pages = pages.filter { $0.index == page - 1 } }
            found = Region.find(wanted.kind, wanted.number, in: pages)
        }
        let name = "\(wanted.kind.rawValue) \(wanted.number)"
        guard let first = found.first else {
            let numbers: [String] = pages.flatMap { page -> [String] in
                (page.layer.regions ?? []).filter { $0.kind == wanted.kind }.map(\.number)
            }
            let list = Set(numbers).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(30).joined(separator: ", ")
            var message = "no \(name)" + (page.map { " on p.\($0)" } ?? " found")
            message += list.isEmpty ? "; no \(wanted.kind.rawValue) was found there" : "; \(wanted.kind.rawValue)s found: \(list)"
            if wanted.kind != .equation {
                message += ". A table drawn without rules, or a figure with no caption, is not found; pdf crop --page N --bbox crops any region"
            }
            throw NotFound(description: message)
        }
        if found.count > 1, Set(found.map(\.page)).count > 1 {
            throw NotFound(description: "\(name) is on " + found.map { "p.\($0.page + 1)" }.joined(separator: " and ") + "; add --page")
        }
        let layer = pages.first { $0.index == first.page }!.layer
        return (first.page, first.region, first.region.captionText(in: layer))
    }
}
