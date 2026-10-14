import ArgumentParser
import Foundation
import PDFKit

/// Experiments for milestone M0. Hidden from `pdf --help`, and removed once
/// the spike's questions are answered (ROADMAP.md → M0).
struct Spike: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spike",
        abstract: "Experiments for milestone M0. Not part of the product.",
        shouldDisplay: false,
        subcommands: [SpikeText.self, SpikeDocs.self]
    )
}

/// M0.2: prints each page's PDFKit text as one JSON object per line.
struct SpikeText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Print each page's text from PDFKit, one JSON object per line."
    )

    @Argument(help: "Path to a PDF file.")
    var path: String

    func run() throws {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else {
            throw ValidationError("PDFKit could not open \(path)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            let text = page.string ?? ""
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let record = PageText(
                page: index + 1, label: page.label, ms: elapsed, text: text,
                columns: columnRuns(page: page, text: text)
            )
            var line = try encoder.encode(record)
            line.append(0x0A)
            FileHandle.standardOutput.write(line)
        }
    }
}

struct PageText: Encodable {
    let page: Int
    let label: String?
    let ms: Double
    let text: String
    let columns: String
}

/// The order in which the text visits the page's left and right halves, such as "L R".
/// Text is split into lines at line breaks. A line that crosses the middle of the page
/// (a title, a full-width caption) is skipped, and every other line counts once per
/// character for the half its center falls in. Runs shorter than `minimumRun`
/// characters are dropped, so superscripts and stray marks do not count.
func columnRuns(page: PDFPage, text: String, minimumRun: Int = 20) -> String {
    let characters = text as NSString
    let bounds = page.bounds(for: .cropBox)
    let middle = bounds.midX
    let margin = bounds.width * 0.05
    var sides: [Character] = []
    var line: [CGRect] = []

    func flushLine() {
        defer { line.removeAll() }
        guard let minX = line.map(\.minX).min(), let maxX = line.map(\.maxX).max() else { return }
        if minX < middle - margin && maxX > middle + margin { return }
        let side: Character = (minX + maxX) / 2 < middle ? "L" : "R"
        sides.append(contentsOf: repeatElement(side, count: line.count))
    }

    for index in 0..<characters.length {
        let unit = characters.character(at: index)
        if unit == 0x0A || unit == 0x0D {
            flushLine()
            continue
        }
        if let scalar = Unicode.Scalar(unit), CharacterSet.whitespaces.contains(scalar) { continue }
        let box = page.characterBounds(at: index)
        if !box.isEmpty { line.append(box) }
    }
    flushLine()
    return collapse(sides, minimumRun: minimumRun)
}

/// Collapses a sequence of sides into its long runs, such as "L R L".
func collapse(_ sides: [Character], minimumRun: Int) -> String {
    var runs: [(side: Character, count: Int)] = []
    for side in sides {
        if let last = runs.last, last.side == side {
            runs[runs.count - 1].count += 1
        } else {
            runs.append((side, 1))
        }
    }
    var kept: [Character] = []
    for run in runs where run.count >= minimumRun {
        if kept.last != run.side { kept.append(run.side) }
    }
    return kept.map(String.init).joined(separator: " ")
}
