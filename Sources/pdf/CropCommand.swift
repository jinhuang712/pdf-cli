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

            What combines: --page N alone crops the whole page; --page N --bbox crops a region of it (--bbox needs \
            --page); --figure, --table or --equation crops that item, and --page narrows the search to one page; \
            --grid draws its lines on any of these. --bbox with --figure, --table or --equation, two of those three, \
            or none of --page, --figure, --table and --equation end 64 with a line naming the flags. --page takes one \
            page here, so a range such as --page 3-5 ends 64 with "crop takes one page; use --page N"; pdf read \
            takes ranges. It prints the image's path and cost, at most about 1,600 image tokens.

            Exit codes: 0 done; 3 the file failed (a locked one needs --password-stdin); 1 it could not run (a \
            missing file, a page out of range, no such figure); 64 used wrongly.

            Examples:
              pdf crop paper.pdf --figure 4
              pdf crop paper.pdf --page 3 --bbox 0.1,0.4,0.8,0.3
              pdf crop paper.pdf --page 3 --grid
              pdf crop paper.pdf --equation 5 --page 4 --json
            """
    )

    @Argument(help: "Path to a PDF file.") var path: String
    @Option(
        name: .customLong("page"),
        help: ArgumentHelp(
            "The page, by its position in the file. One page here, not a range (pdf read takes ranges). With --figure, --table or --equation it picks where two share a number.",
            valueName: "N"))
    var pageSpec: String?
    var page: Int? { pageSpec.flatMap { Int($0) } }
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
        if let pageSpec {
            if let many = ReadCommand.pages(pageSpec), Int(pageSpec) == nil, many.count > 1 || pageSpec.contains("-") || pageSpec.contains(",") {
                throw ValidationError("crop takes one page; use --page N (pdf read takes ranges such as \(pageSpec))")
            }
            guard let page, page >= 1 else { throw ValidationError("--page takes one page number, 1 or more") }
        }
        if let bbox, Box.parse(bbox) == nil {
            throw ValidationError("--bbox takes x,y,width,height in fractions of the page, such as 0.1,0.4,0.8,0.3")
        }
        if [figure, table, equation].compactMap({ $0 }).count > 1 {
            throw ValidationError("--figure, --table and --equation cannot go together: give one of them")
        }
        if wanted != nil, bbox != nil {
            throw ValidationError(
                "--bbox and \(wanted!.kind == .figure ? "--figure" : wanted!.kind == .table ? "--table" : "--equation") cannot go together: --bbox crops a region of the page you name with --page; --figure, --table and --equation crop their own"
            )
        }
        if wanted == nil, page == nil { throw ValidationError("give --page, or --figure, --table or --equation") }
    }

    func run() throws {
        try Contract.guarding(path, json: json) { try crop() }
    }

    func crop() throws {
        let store = try Store()
        let password = passwordStdin ? Password.read(for: path) : nil
        let reader = Reader(store: store, library: try Library())
        let docID: String
        switch try reader.read(path: path, pages: [], password: password) {
        case .fileFailed(let reason):
            let shown = reason + Contract.unlockHint(reason)
            throw Contract.fail(path, shown, json: json, code: Contract.fileFailed)
        case .pages(let id, let pageCount, _):
            if let page, page > pageCount { throw ReadError.pageOutOfRange(page: page - 1, pageCount: pageCount) }
            docID = id
        }
        var number = page ?? 1
        var region = bbox.flatMap(Box.parse)?.outward
        var caption: String?
        // An equation's LaTeX or a table's Markdown that the agent kept, to check against the
        // image, and the number to keep one by.
        var kept: Transcript?
        var keepable: (kind: Region.Kind, number: String)?
        var twins = 1
        var unsearched: [Int] = []
        var linked: [(page: Int, region: Region)] = []
        var link: TableLink?
        // The pages whose text mentions it, as "Fig. 4", in the pages parsed so far.
        var mentioned: [Int] = []
        if let wanted {
            let found = try Self.locate(wanted, page: page, path: path, password: password, docID: docID, store: store, reader: reader)
            number = found.page + 1
            region = found.region.box.outward
            caption = found.caption
            twins = found.twins
            unsearched = found.unsearched
            linked = found.parts
            link = found.link
            let layers = try InfoCommand.cachedPages(docID: docID, store: store).compactMap { page -> (index: Int, layer: PDFCore.PageText)? in
                page.result.pageText.map { (page.index, $0) }
            }
            mentioned = ReferenceIndex.pagesMentioning(wanted.kind, found.region.number, in: layers)
            if wanted.kind != .figure {
                let regionNumber = Region.normalized(found.region.number)
                keepable = (wanted.kind, regionNumber)
                let keys = try store.pageKeys(docID: docID)
                // A linked table has one reading, kept on any of its pages.
                for part in found.link?.pages.map({ $0 - 1 }) ?? [found.page] where kept == nil && keys.indices.contains(part) {
                    kept = try Transcripts().transcripts(keys: [keys[part]])[keys[part]]?
                        .first { $0.kind == wanted.kind && $0.number == regionNumber }
                }
            }
        }
        let made: Crop.Made
        do {
            made = try Crop.make(path: path, page: number, region: region, grid: grid, password: password)
        } catch {
            let reason = (error as? CropError)?.description ?? "\(error)"
            // A file that did not open ends 3, as on every command, with its own reason; a page
            // that could not be drawn ends 1.
            if let failed = error as? CropError, failed.fileFailed {
                throw Contract.fail(path, reason + Contract.unlockHint(reason), json: json, code: Contract.fileFailed)
            }
            throw Contract.fail(path, "p.\(number) could not be drawn: \(reason)", json: json)
        }
        let tokens = Crop.tokens(width: made.width, height: made.height)
        // The other parts of a table that runs over a page break, one crop each, in page order.
        var others: [(page: Int, made: Crop.Made, caption: String)] = []
        if let link {
            for part in linked where part.page + 1 != number {
                do {
                    let layer = try InfoCommand.cachedPages(docID: docID, store: store).first { $0.index == part.page }?.result.pageText
                    others.append(
                        (
                            part.page + 1,
                            try Crop.make(path: path, page: part.page + 1, region: part.region.box.outward, grid: false, password: password),
                            layer.map { part.region.captionText(in: $0) } ?? ""
                        ))
                } catch {
                    throw Contract.fail(
                        path, "p.\(part.page + 1), part of \(link.id), could not be drawn: \((error as? CropError)?.description ?? "\(error)")",
                        json: json)
                }
            }
        }
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
                var markdown: String?
                var transcribed: String?
                var mentionedOn: [Int]?
                var notSearched: [Int]?
                var table: TableLink?
                var parts: [Part]?
            }
            struct Part: Encodable {
                var page: Int
                var bbox: String
                var image: String
                var width: Int
                var height: Int
                var tokens: Int
                var caption: String?
            }
            let everyPart: [Part]? = link.map { _ in
                linked.compactMap { part -> Part? in
                    if part.page + 1 == number {
                        return Part(
                            page: number, bbox: Output.format(part.region.box.outward), image: made.url.path, width: made.width,
                            height: made.height, tokens: tokens, caption: caption)
                    }
                    guard let other = others.first(where: { $0.page == part.page + 1 }) else { return nil }
                    return Part(
                        page: other.page, bbox: Output.format(part.region.box.outward), image: other.made.url.path, width: other.made.width,
                        height: other.made.height, tokens: Crop.tokens(width: other.made.width, height: other.made.height),
                        caption: other.caption)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            print(
                String(
                    decoding: try encoder.encode(
                        Body(
                            file: path, page: number, bbox: region.map(Output.format), image: made.url.path,
                            width: made.width, height: made.height, tokens: tokens, caption: caption,
                            latex: kept?.kind == .equation ? kept?.text : nil,
                            markdown: kept?.kind == .table ? kept?.text : nil, transcribed: kept?.day,
                            mentionedOn: wanted == nil ? nil : mentioned,
                            notSearched: unsearched.isEmpty ? nil : unsearched.map { $0 + 1 }, table: link, parts: everyPart)),
                    as: UTF8.self))
        } else {
            print("\(made.url.path)  (~\(Info.thousands(tokens)) image tokens, \(made.width)×\(made.height) px)")
            if let caption, !caption.isEmpty {
                print("p.\(number) · caption: \(caption)")
            } else if wanted != nil, keepable == nil {
                print("p.\(number)")
            }
            if let link {
                print(
                    "p.\(number) · one table, \(link.id), linked over p.\(link.pages.map(String.init).joined(separator: ", p.")): a crop for each linked part, in page order, this one first"
                )
                for other in others {
                    print(
                        "\(other.made.url.path)  (~\(Info.thousands(Crop.tokens(width: other.made.width, height: other.made.height))) image tokens, \(other.made.width)×\(other.made.height) px)"
                    )
                    print("p.\(other.page) · linked part" + (other.caption.isEmpty ? "" : " · caption: \(other.caption)"))
                }
            }
            if let wanted, twins > 1 {
                print("p.\(number) numbers \(twins) \(wanted.kind.rawValue)s \(wanted.number): this is the first of them")
            }
            if let wanted, !unsearched.isEmpty {
                print(
                    "not searched: \(unsearched.count) pages (\(ReparseCommand.pageList(unsearched.map { $0 + 1 }))) are not parsed yet, so another \(wanted.kind.rawValue) \(wanted.number) there would make this ambiguous; run the command again once the file is parsed, or add --page"
                )
            }
            if !mentioned.isEmpty {
                print(
                    "mentioned on " + mentioned.prefix(12).map { "p.\($0)" }.joined(separator: ", ")
                        + (mentioned.count > 12 ? ", and \(mentioned.count - 12) more" : ""))
            }
            if let keepable {
                let language = Transcript.language(of: keepable.kind)
                let keep = "pdf transcribe \(Output.quoted(path)) --page \(number) --\(keepable.kind.rawValue) \(keepable.number) <<'EOF'"
                if let kept {
                    print("p.\(number) · \(language) kept \(kept.day), which pdf read shows; check it against the image, and replace it with: \(keep)")
                    print(Output.indented(kept.text))
                } else {
                    print("p.\(number) · once read, keep its \(language) for later reads: \(keep), then the \(language), then EOF")
                }
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
    static func locate(
        _ wanted: (kind: Region.Kind, number: String), page: Int?, path: String, password: String?, docID: String,
        store: Store, reader: Reader
    ) throws -> (page: Int, region: Region, caption: String, twins: Int, unsearched: [Int], parts: [(page: Int, region: Region)], link: TableLink?) {
        func layers() throws -> [(index: Int, layer: PDFCore.PageText)] {
            try InfoCommand.cachedPages(docID: docID, store: store).compactMap { page -> (index: Int, layer: PDFCore.PageText)? in
                page.result.pageText.map { (page.index, $0) }
            }
        }
        var pages = try layers()
        if let page { pages = pages.filter { $0.index == page - 1 } }
        var found = Region.find(wanted.kind, wanted.number, in: pages)
        let keys = try store.pageKeys(docID: docID)
        var stopped: String?
        // Pages not searched when the looking ended at a match, in a file not parsed whole.
        var unsearched: [Int] = []
        if found.isEmpty, let page {
            _ = try reader.read(path: path, pages: [page - 1], password: password)
            pages = try layers().filter { $0.index == page - 1 }
            found = Region.find(wanted.kind, wanted.number, in: pages)
        } else if found.isEmpty, pages.count < keys.count {
            // A number the parsed pages do not hold: the rest of the file is parsed in batches from
            // the start, and the looking ends at the first batch that holds it, or at the time limit
            // (M2.21: a textbook of 517 pages took 115 s to parse before it said the number was not
            // there). The pages stay parsed, and the parse goes on in the background.
            let started = Date()
            while found.isEmpty {
                let cached = Set(try InfoCommand.cachedPages(docID: docID, store: store).map(\.index))
                let next = keys.indices.filter { !cached.contains($0) }.prefix(Env.lookBatch)
                if next.isEmpty { break }
                if case .fileFailed(let reason) = try reader.read(path: path, pages: Array(next), password: password) {
                    stopped = "the file could not be read any further: \(reason)"
                    break
                }
                pages = try layers()
                found = Region.find(wanted.kind, wanted.number, in: pages)
                let parsed = try InfoCommand.cachedPages(docID: docID, store: store).count
                if found.isEmpty, parsed <= cached.count {
                    // The batch added nothing: the loop would not end.
                    stopped = "the parse made no progress with \(parsed) of \(keys.count) pages searched; run the command again"
                    break
                }
                if found.isEmpty, parsed < keys.count, Date().timeIntervalSince(started) >= Env.lookTimeLimit {
                    stopped =
                        "stopped at the time limit of \(Env.secondsText(Env.lookTimeLimit)) with \(parsed) of \(keys.count) pages searched; "
                        + "run the command again to look further (the pages stay parsed), or add --page N"
                    break
                }
            }
            if !found.isEmpty {
                let now = Set(try InfoCommand.cachedPages(docID: docID, store: store).map(\.index))
                unsearched = keys.indices.filter { !now.contains($0) }
            }
        }
        let name = "\(wanted.kind.rawValue) \(wanted.number)"
        guard let first = found.first else {
            let numbers: [String] = pages.flatMap { page -> [String] in
                (page.layer.regions ?? []).filter { $0.kind == wanted.kind }.map(\.number)
            }
            let list = Set(numbers).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(30).joined(separator: ", ")
            var message = "no \(name)" + (page.map { " on p.\($0)" } ?? " found")
            if let stopped {
                // Not in the whole file: how far the looking went, and how to go on.
                message += " yet: " + stopped + (list.isEmpty ? "" : "; \(wanted.kind.rawValue)s found so far: \(list)")
                throw NotFound(description: message)
            }
            message += list.isEmpty ? "; no \(wanted.kind.rawValue) was found there" : "; \(wanted.kind.rawValue)s found: \(list)"
            if wanted.kind != .equation {
                message += ". A table drawn without rules, or a figure with no caption, is not found; pdf crop --page N --bbox crops any region"
            }
            throw NotFound(description: message)
        }
        // A table that runs over page breaks is one table with a crop per part: the chain of the
        // first one found, with the pages beyond its ends parsed (M3.2).
        var parts: [(page: Int, region: Region)] = []
        var link: TableLink?
        if wanted.kind == .table, let anchor = found.first {
            let tablePages = TablePages(known: [:], keys: keys, store: store) { other in
                _ = try? reader.read(path: path, pages: [other], password: password)
            }
            if let index = tablePages.layer(anchor.page)?.regions?.firstIndex(of: anchor.region) {
                link = TableLinks.link(of: index, on: anchor.page, in: tablePages)
                if let whole = link, whole.parts == 1 {
                    link = nil
                } else if link != nil {
                    parts = TableLinks.chain(of: index, on: anchor.page, layer: tablePages.layer).compactMap { part in
                        tablePages.layer(part.page)?.regions.map { (part.page, $0[part.region]) }
                    }
                }
            }
        }
        // The walk may have parsed pages that hold the number too: look again before judging it ambiguous.
        if link != nil {
            pages = try layers()
            if let page { pages = pages.filter { $0.index == page - 1 } }
            found = Region.find(wanted.kind, wanted.number, in: pages)
        }
        if found.count > 1, Set(found.map(\.page)).count > 1, !found.allSatisfy({ item in parts.contains { $0.page == item.page } }) {
            throw NotFound(description: "\(name) is on " + found.map { "p.\($0.page + 1)" }.joined(separator: " and ") + "; add --page")
        }
        let layer = pages.first { $0.index == first.page }!.layer
        return (first.page, first.region, first.region.captionText(in: layer), found.filter { $0.page == first.page }.count, unsearched, parts, link)
    }
}
