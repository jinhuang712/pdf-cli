import CoreGraphics
import Foundation
import PDFKit

/// The words under the links of a page, which PDFKit selects where each link lies. They are read
/// when their page is read, in a worker, for the pages asked for and a link at a time, so the index
/// does not wait for the links of a file that holds tens of thousands, and the same file gives the
/// same words however busy the machine is (plan/decisions/044-annotations-per-page-in-a-table-of-their-own.md → Decision: annotations per page, in a table
/// of their own).
public enum AnnotationWords {
    /// What the worker is asked: where a link lies, by its page and place in the page's list.
    struct Request: Codable, Equatable {
        var page: Int
        var index: Int
        var box: Box
    }

    /// The longest words kept under a link, in characters.
    static let maxWords = 200

    /// Gives each page of `found` whose links wait for their words the words, and keeps them in the
    /// cache. A worker that fails, runs out of time or memory, or cannot open the file leaves the
    /// links without words, said so in the row, so the next read does not try again.
    public static func fill(path: String, stat: FileStat, found: [Int: Store.PageAnnotations], store: Store) -> [Int: Store.PageAnnotations] {
        var found = found
        let waiting = found.filter { $0.value.words == .pending }.keys.sorted()
        guard !waiting.isEmpty else { return found }
        let requests = waiting.flatMap { page in
            found[page]!.annotations.enumerated().compactMap { index, annotation in
                annotation.kind == .link ? Request(page: page, index: index, box: annotation.box) : nil
            }
        }
        let words = ask(path: path, requests)
        for page in waiting {
            let mine = words.map { $0.filter { $0.page == page } }
            try? store.saveWords(path: path, stat: stat, page: page,
                                 words: mine.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.index, $0.words) }) })
            guard let mine else {
                found[page]!.words = .failed
                continue
            }
            for entry in mine where found[page]!.annotations.indices.contains(entry.index) {
                found[page]!.annotations[entry.index].words = entry.words
            }
            found[page]!.words = .read
        }
        return found
    }

    /// One worker for all the pages asked, or nil when it did not answer.
    static func ask(path: String, _ requests: [Request]) -> [(page: Int, index: Int, words: String)]? {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-words-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: input) }
        guard let data = try? JSONEncoder().encode(requests), (try? data.write(to: input)) != nil else { return nil }
        guard let event = try? Crop.runWorker(["__worker", "words", path, "--out", input.path]),
            event.kind == .result, event.reason == nil, let text = event.text,
            let rows = try? JSONDecoder().decode([[String]].self, from: Data(text.utf8))
        else { return nil }
        return rows.compactMap { row in
            guard row.count == 3, let page = Int(row[0]), let index = Int(row[1]) else { return nil }
            return (page, index, row[2])
        }
    }

    /// The worker: the words PDFKit selects under each requested box, as `[page, index, words]`
    /// rows for the links that have any.
    static func answer(path: String, input: String) -> WorkerEvent {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: input)),
            let requests = try? JSONDecoder().decode([Request].self, from: data)
        else { return WorkerEvent(kind: .result, reason: "the request could not be read") }
        guard let document = PDFDocument(url: url), OpenFailure.unlock(document),
            let cg = CGPDFDocument(url as CFURL)
        else { return WorkerEvent(kind: .result, reason: OpenFailure.classify(url: url)) }
        if cg.isEncrypted && !cg.isUnlocked { _ = cg.unlockWithPassword("") || cg.unlockWithPassword(Env.password) }
        let tree = PageTree(cg)
        var rows: [[String]] = []
        for request in requests {
            guard let page = document.page(at: request.page) else { continue }
            // The box as the facts read it: fractions of the crop box from its top-left corner.
            let crop = tree.flatMap { $0.pages.indices.contains(request.page) ? PageGeometry(dictionary: $0.pages[request.page])?.cropBox : nil }
                ?? PageGeometry.letter
            let width = max(crop.width, 1), height = max(crop.height, 1)
            let rect = CGRect(
                x: crop.minX + request.box.x * width, y: crop.maxY - (request.box.y + request.box.height) * height,
                width: request.box.width * width, height: request.box.height * height)
            guard let words = page.selection(for: rect)?.string, let cleaned = FactReader.clean(words) else { continue }
            rows.append([String(request.page), String(request.index), String(cleaned.prefix(maxWords))])
        }
        guard let encoded = try? JSONEncoder().encode(rows) else { return WorkerEvent(kind: .result, reason: "the words could not be written") }
        return WorkerEvent(kind: .result, text: String(bytes: encoded, encoding: .utf8) ?? "[]")
    }
}
