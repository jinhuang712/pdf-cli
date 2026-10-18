import Foundation
import PDFKit
import Testing

@testable import PDFCore

/// The LaTeX the agent reads from an equation's crop, kept so later reads show it (ROADMAP.md →
/// M2.13).
@Suite struct TranscriptsTests {
    /// What the agent gives is kept as written, without what could hide or reorder it, and
    /// without the signs around it that the output adds.
    @Test func whatIsKept() {
        #expect(Transcripts.cleaned("$$E = m c^{2}$$\n") == "E = m c^{2}")
        #expect(Transcripts.cleaned("\\[ \\frac{a}{b} \\]") == "\\frac{a}{b}")
        #expect(Transcripts.cleaned("$x_{1}$") == "x_{1}")
        #expect(Transcripts.cleaned("$a$ and $b$") == "$a$ and $b$")
        #expect(Transcripts.cleaned("a \\\\\r\n\tb  \r\n") == "a \\\\\n b")
        #expect(Transcripts.cleaned("x\u{202E}y\u{0007}z") == "xyz")
        #expect(Transcripts.cleaned("  \n $$ $$ \n") == nil)
    }

    /// One a page and an equation, replaced by the next, removed on request, and gone with a
    /// page that changed.
    @Test func keptByPageAndNumber() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Transcripts(directory: folder)
        try store.save(Transcript(pageKey: "k1", kind: .equation, number: "5", text: "a = b", madeAt: Date()))
        try store.save(Transcript(pageKey: "k1", kind: .equation, number: "5", text: "a = c", madeAt: Date()))
        try store.save(Transcript(pageKey: "k1", kind: .equation, number: "2.1", text: "d", madeAt: Date()))
        let found = try store.transcripts(keys: ["k1", "k2"])
        #expect(found["k1"]?.count == 2 && found["k1"]?.first { $0.number == "5" }?.text == "a = c")
        #expect(found["k2"] == nil)
        #expect(try store.remove(pageKey: "k1", kind: .equation, number: "5"))
        #expect(try !store.remove(pageKey: "k1", kind: .equation, number: "5"))
        #expect(try store.transcripts(keys: ["k1"])["k1"]?.map(\.number) == ["2.1"])
    }

    /// `pdf read` shows the LaTeX in the equation's block, labelled as transcribed, each line
    /// indented, with the crop to check it by; for that page and that number alone.
    @Test func readShowsTheLaTeXInPlace() throws {
        let url = repoRoot.appendingPathComponent("testdata/safety/hidden-figure-alt.pdf")
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let layer = withExtendedLifetime(document) { TextLayer.read(page, visibility: Visibility(page: page)) }
        let data = String(decoding: try JSONEncoder().encode(layer), as: UTF8.self)
        let result = PageResult(status: .ok, method: "pdfkit", text: layer.text, reason: "", parseMillis: 1, data: data)
        let output = Output.Page(index: 0, result: result, key: "k0")
        func read(_ text: String, key: String = "k0", number: String = "1") -> Output.Report {
            let kept = Transcript(pageKey: key, kind: .equation, number: number, text: text, madeAt: Date(timeIntervalSince1970: 1_790_000_000))
            return Output.render(file: "f.pdf", pageCount: 1, pages: [output], transcripts: [key: [kept]])
        }
        let day = Transcript(pageKey: "", kind: .equation, number: "1", text: "", madeAt: Date(timeIntervalSince1970: 1_790_000_000)).day
        let shown = read("E = m c^{2}").text
        #expect(shown.contains("[equation 1, transcribed \(day)]\n  $$E = m c^{2}$$\n  crop: pdf crop f.pdf --page 1 --equation 1"))
        var json = Output.Document(file: "f.pdf", pageCount: 1, transcripts: [
            "k0": [Transcript(pageKey: "k0", kind: .equation, number: "1", text: "E = m c^{2}", madeAt: Date(timeIntervalSince1970: 1_790_000_000))],
        ])
        _ = json.add(output)
        let block = try #require(json.blocks.first { $0.kind == Output.Block.Kind.equation })
        #expect(block.latex == "E = m c^{2}" && block.transcribed == day)
        // A display environment of its own goes as written; an inner one goes between $$; no
        // line of either reads as a page of its own.
        #expect(read("\\begin{align}\na &= b\n\\end{align}").text.contains("]\n  \\begin{align}\n  a &= b\n  \\end{align}\n  crop:"))
        #expect(read("\\begin{aligned}\na &= b\n## p.9\n\\end{aligned}").text.contains("  $$\\begin{aligned}\n  a &= b\n  ## p.9\n"))
        #expect(!read("\\begin{aligned}\n## p.9\n\\end{aligned}").text.contains("\n## p.9"))
        // Another page's, or another equation's, is not this one's.
        #expect(read("x", key: "other").text.contains("[equation 1] crop: pdf crop f.pdf --page 1 --equation 1"))
        #expect(read("x", number: "2").text.contains("[equation 1] crop: pdf crop f.pdf --page 1 --equation 1"))
    }
}
