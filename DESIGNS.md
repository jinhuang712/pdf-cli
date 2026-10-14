<!-- what-we-build: drafted 2026-10-14 -->
# Designs

PDF files on the user's Mac and commands from an agent go in. Text with page addresses, PNG crops, search hits and failure reports come out, served from a local cache. In between, worker processes parse each page once, in steps that escalate only as far as the page needs, and store the result in SQLite. Behavior is in [FEATURES.md](FEATURES.md).

The intended flow, with Apple's engines and simple rules doing the parsing, and the agent doing all the reasoning:

```text
AGENT: Claude Code, or another LLM that can see images
  Does all the reasoning, including reading page images.
   │                                      ▲
   │ pdf info / read / search / crop      │ text, every block with page + position
   │ pdf pick                             │ unsure blocks with two readings
   │                                      │ failure blocks, each with a
   │                                      │   ready-to-run `pdf crop` command
   │                                      │ PNG crops, only when asked
   ▼                                      │
CACHE: SQLite ── already parsed? ──yes──► answer in milliseconds
   │ no
   ▼
WORKER: a child process with time and memory limits, page by page
   │
   ├─ 1. Font check ──── Core Graphics reads each font's widths
   │                     wide character 32 → file marked "at risk"
   │
   ├─ 2. Text ────────── PDFKit: characters, their boxes, their fonts
   │      ├─ at risk ──► Apple OCR reads the page image, and only
   │      │              its word breaks are kept  (*)
   │      └─ scan or ──► Apple OCR document recognizer:
   │         garbled     text, paragraphs, tables, lists
   │
   ├─ 3. Structure ───── simple rules, no model
   │      figures ◄───── drawing commands + "Figure N" captions
   │      headings, footnotes, running headers, footnote markers
   │              ◄───── font sizes and positions
   │      hidden text ─► set aside, shown only with a flag
   │
   └─ 4. Quality check, then every result is cached
          ok ──────────► agent reads the text
          unsure ──────► two readings + `pdf pick` (words only)
          doubtful ────► failure block + `pdf crop` command
          or failed      ──► agent looks at the crop itself

OFF BY DEFAULT: added only when a goal fails without them
   · Layout model on Core ML: labels footnotes and headings in one pass
   · Local vision model (milestone M3): hard pages and formulas

(*) Still open: see Open questions.
```

The "at risk" check comes from the M0 spike: a font that declares character 32 twice as wide as a normal space makes PDFKit drop the spaces between words.

## Principles

### Parsing

- **Apple's engines first.** PDFKit and Vision do the work by default, and a downloaded model joins only where the Base setup measurably falls short of a goal. Cost: some pages read worse than a model would read them, until a measurement shows the gap. Holds as: every model that `pdf setup` downloads is listed in this document with the goal it improves and its measured gain over Base.
- **The file's own structure first.** Tags, bookmarks, page labels and the text layer win over inference, and models fill only the gaps. Cost: a badly tagged PDF misleads the parser until a quality check catches it. Holds as: every block records its source (`file`, `layout`, `ocr` or `vlm`), and a model-made block appears only where the file states nothing.
- **Escalate per page.** Each page goes through the text layer, the layout model, OCR and a vision model, in that order, and stops at the first step that reads it well. Cost: one document mixes methods, so quality varies from page to page. Holds as: every page record names the step that produced it.

### Failure

- **A failed page always holds a failure block.** A page that fails to parse, or reads below the quality bar, gets a failure block in its place: the page, the reason and the quality score. Cost: output on hard documents gets noisy, and agents must handle failure blocks. Holds as: every page record has a status (`ok`, `low-quality` or `failed`) with its reasons, and the output writer turns every page that is not `ok` into a failure block.
- **Every failure names its way out.** The way out is the agent's own image understanding: each failure block carries the ready-to-run `pdf crop` command for the smallest region that holds the doubt, with the lines around it. Cost: the agent pays image tokens for each crop it reads, and a region found too small hides context. Holds as: the output writer emits no failure block without a crop command, and the crop covers the block's own region, or its page when the whole page is in doubt.
- **The agent judges what language can show.** When two readings of a passage differ in words, such as spacing or a sentence spliced across columns, the block shows both readings, and the agent picks one with `pdf pick`. Readings that differ in digits, table cells or formulas go out as a crop instead. Cost: extra tokens for the words that differ, and a wrong pick lasts until `reparse`. Holds as: `pdf pick` accepts only one of the tool's own readings, picks live in their own table apart from the parsed pages, and every picked span carries a `[picked]` label in the output.
- **Failure is reported three times.** It appears in place, in the summary line at the top of the output, and in the exit code, so an agent that reads only one of them still sees it. Cost: the same failure shows up in three places. Holds as: the exit code for partial failure differs from the codes for success and total failure, and the summary counts every page that is not `ok`.
- **Doubt counts as failure.** A garbled text layer, an uncertain reading order or a low OCR confidence gives the page the status `low-quality`, reported like a failure. Cost: more warnings on hard documents. Holds as: each quality check has a threshold, and a page below any threshold gets the status `low-quality`.

### Silent errors

A page can read wrong while it looks right, and the agent believes what it is handed. Each trap found so far gets its own check.

- **Table regions replace their text.** PDFKit turns a table into a stream of numbers without rows or columns, as the M0 spike showed. The text inside a detected table stays out of the output, and the table goes out as an image (see the decision on tables below). Cost: a table the detector misses still leaks its flat numbers. Holds as: the output writer drops every text block inside a table region and emits one table block in its place, and goal G8 in [GOALS.md](GOALS.md) scores table detection.
- **Raised and lowered characters are found from their boxes.** Plain text turns 10⁻⁵ into "10−5", as the M0 spike showed. A character set smaller and above or below its line's baseline is a superscript or a subscript. Cost: a font that reports odd boxes gets wrong marks. Holds as: every character set smaller and off the baseline leaves the text layer with a superscript or subscript mark, or as a footnote or citation marker.
- **One sample page per file is checked against its image.** A broken font table can map shapes to wrong letters, and an old OCR layer in a scan can hold misreads. Both look like real words. Apple OCR reads one sample page, and its words are compared with the text layer's words. Cost: about 0.6 s per file. Holds as: a file whose sample page disagrees beyond the threshold has every page escalate to OCR.
- **Spaces are checked before and after reading.** A font that declares character 32 wider than a normal space makes PDFKit drop the spaces between words, as the M0 spike found. A Word-made spike paper also loses 1–2 spaces per page, for a reason still unknown. Before reading, the font check marks the file "at risk". After reading, a count of run-together words checks every page. Cost: a few milliseconds per page. Holds as: every page record stores its run-together word count, and a page above the threshold gets the status `low-quality`.

### Cache

- **Pay once, read many times.** Results are keyed by page content and parser version, and failed pages are cached with their reasons too. Cost: disk space, and a cache that must stay correct. Holds as: no command parses a page whose key is already in the cache, except `reparse`.
- **Annotations leave the cache alone.** The key hashes each page's content, not the file's bytes. Cost: hashing every page takes time when a file is added. Holds as: adding a highlight in Preview leaves every page key unchanged.
- **Same file, same answer.** Models are pinned, decoding never samples, and a vision model's output is cached. Cost: the project gives up the extra accuracy that sampling sometimes buys. Holds as: two parses of the same file with the same version produce byte-identical output.

### Output

- **Every claim has an address.** Every block carries its page and its position on the page. Cost: a few tokens per block. Holds as: every block type in the output schema has `page` and `bbox`.
- **Text first, pixels on request.** Images come only when the agent asks for them. Cost: the agent can miss a visual cue it did not ask about. Holds as: only `crop`, `dump --figures` and `dump --tables` write image files.

### Performance

- **First answer over full parse.** The requested page is parsed first, and the rest of the document follows in the background. Cost: a page parsed alone lacks the whole document's context, such as heading levels and footnote numbering. Holds as: output from a partly parsed document is marked provisional, and the mark clears once the full parse ends.
- **Parallel by process.** Parsing runs in separate worker processes. Cost: each worker holds its own memory and loaded models. Holds as: no PDF engine call runs on two threads of one process.

### Safety

- **Untrusted files stay in a child process.** Each parse runs in a worker with a time limit and a memory limit. Cost: a process starts for each job. Holds as: only workers open PDF content, the CLI process reads only the cache, and a worker that hits a limit yields a `failed` page instead of a crash.
- **Invisible text stays out of normal output.** Text that a reader cannot see is flagged and set aside: text drawn in the color behind it, tiny, clipped, covered by an image or off the page. Cost: visibility depends on what is drawn behind the text, so every text block needs a look at the layers below it, and an OCR text layer is invisible by design, so it needs its own rule. Holds as: invisible text over a scanned image counts as a text layer, white text on a dark box counts as visible, and every other invisible block reaches the output only with an explicit flag.
- **Parsing stays offline.** Models download only during setup. Cost: a missing model needs a setup step before first use. Holds as: a test parses the open test set under a network monitor and sees zero connections.
- **PDF actions never run.** JavaScript, launch actions and embedded files stay inert. Cost: none for reading. Holds as: workers call no engine API that runs a document action.

### Testing

- **Real PDFs are the test.** Every change and every macOS release reruns a test set of real documents with expected output. Cost: building and labelling the set takes real work. Holds as: CI runs the open set on every pull request. The open set holds only open-access PDFs, such as arXiv papers under CC-BY, and a private set of the user's own PDFs stays local.
- **Scoring weighs wrong over missing.** A wrong block costs a test more than a missing one, as the philosophy says. Cost: a parser that returns less can outscore one that returns more. Holds as: the scorer applies a heavier weight to wrong blocks, and the weight lives in [GOALS.md](GOALS.md).

## Decision: Swift over Rust, Go and Python — 2026-10-14

Swift wins because the tool runs only on macOS, and on macOS every engine the project needs is first-class in Swift. A 2-week spike confirms the choice.

| Option | For | Against |
|---|---|---|
| **Swift** | PDFKit, Core Graphics, Vision (including the macOS 26 document recognizer), Core ML and MLX Swift are all direct calls. It ships as one binary with fast startup. | Few reference implementations to port from. A smaller pool of contributors. |
| Rust | Memory safety for parsing untrusted files. One core can serve many languages. | Apple frameworks come through the `objc2` bindings, and MLX is second-class. A Swift layer is still needed for the newest Apple APIs. |
| Go | A simple CLI and a single binary. | Weak PDF and machine-learning libraries. Apple frameworks need cgo. |
| Python | Every leading parser (Docling, MinerU) and model is written in it. | A PyTorch install weighs gigabytes, and models take seconds to load. |

The spike tests the three riskiest bets:

- The text quality of PDFKit against PDFium on real PDFs.
- The speed and quality of a layout model converted to Core ML.
- The reading order that Apple's document recognizer gives on born-digital pages.

Existing Swift projects show the pieces work: mac-ocr and vision-book-digitizer call Apple's document recognizer, and `mlx-swift-lm` already runs GLM-OCR.

## Decision: macOS only — 2026-10-14

The tool supports macOS and no other platform. The reason lives in [PROPOSAL.md → What we don't want](PROPOSAL.md#what-we-dont-want): Apple's PDF, OCR and Neural Engine frameworks are the project's main advantage.

## Decision: Apple PDFKit, with PDFium as fallback, over a parser of our own — 2026-10-14

PDFKit and Core Graphics parse and render. PDFium is the fallback, and it cross-checks PDFKit on the test set.

| Option | For | Against |
|---|---|---|
| **PDFKit and Core Graphics** | Ship with macOS, and Apple maintains them. Crops look exactly like Preview. | Closed: the project cannot fix their bugs, and their behavior can change between macOS versions. |
| **PDFium** (fallback) | Chrome's engine, open source under BSD, with years of fixes for broken files. | One more binary to bundle. |
| hayro | A pure-Rust PDF renderer under Apache-2.0, in active development. | Young, and Rust in a Swift project. |
| MuPDF and PyMuPDF | Fast and complete. | AGPL, which a permissive public repo cannot take on. |
| A parser of our own | Full control. | Years of work to handle broken files as well as PDFium, with no difference a user could see. |

Which engine is the main text source stays open until the spike.

## Decision: Apple Vision over Tesseract and RapidOCR — 2026-10-14

Vision reads scanned pages and garbled pages.

- It runs on the device and on the Neural Engine.
- It installs nothing, because it ships with macOS.
- On macOS 26, its document recognizer returns paragraphs, tables and lists, along with the text.

Tesseract and RapidOCR would each add an install and a model to ship. On older macOS versions, Vision falls back to plain text recognition, without the document structure.

## Decision: Core ML on the Neural Engine over a Python Docling worker — 2026-10-14

Layout models run as Core ML models on the Neural Engine. This keeps the tool one binary, with no Python.

| Option | For | Against |
|---|---|---|
| **Core ML** | Uses the Neural Engine, and ships inside the binary. | Some models fail to convert. Apple decides whether a model runs on the Neural Engine. |
| MLX | Apple's own machine-learning framework, with a Swift API. | Each model must be ported. It runs on the GPU. |
| ONNX Runtime | Runs almost any exported model. | One more runtime to bundle. |
| Python Docling worker | A proven pipeline, under MIT. | Brings back Python and PyTorch, a gigabyte-scale install and seconds of model loading. |

When a model fails to convert to Core ML, the fallback is MLX first, then ONNX Runtime. Model weights come only from licences that allow use in a public repo, such as Docling's MIT models and PaddlePaddle's Apache-2.0 models. The weights' licences stay to be checked.

## Decision: Tables as images over rebuilt cells — 2026-10-14

A table reaches the agent as a crop, and the agent reads the cells with its own image understanding. The reason lives in [FEATURES.md → Not planned](FEATURES.md#not-planned): a rebuilt cell can be wrong and still look right.

| Option | For | Against |
|---|---|---|
| **A crop, read by the agent** | The agent sees the table as printed, merged cells and odd layouts included. Nothing is rebuilt. | Image tokens for every table the agent reads. A dense table needs a sharp crop, and the agent can still misread a digit. |
| PDFKit text | Free, with the exact digits. | Rows and columns are lost, as the M0 spike showed. |
| Apple's document recognizer | Ships with macOS 26, and returns cells. | Untested on tables, and a wrong cell looks right. |
| A table-structure model, such as the one Docling uses | Built for this job. | A download, and a wrong cell still looks right. |

The table's text stays in the keyword index, so a search still finds the page that holds a table.

## Decision: SQLite over qmd and Tantivy — 2026-10-14

One SQLite file holds the cache and both kinds of search.

| Option | For | Against |
|---|---|---|
| **SQLite** | One file holds pages, positions, the keyword index (FTS5) and the vectors. It serves several agents at once, and GRDB.swift makes it native to Swift. | Search by meaning needs a vector extension. |
| qmd | Keyword search, search by meaning and reranking, with an MCP server already built. | Needs Node, reads only Markdown files, and keeps its index apart from our page positions. |
| Tantivy | A fast full-text engine. | A Rust dependency in a Swift project, and a second store beside the cache. |

## Decision: one Homebrew binary over a Python package — 2026-10-14

The tool installs with one Homebrew command. Models that the base install leaves out download in a separate setup step. A Python package would bring PyTorch, an install measured in gigabytes.

## Decision: no LLM inside the tool — 2026-10-14

The tool returns text, crops and failure reports, and the calling agent does all the reasoning. The reason lives in [PROPOSAL.md → What we don't want](PROPOSAL.md#what-we-dont-want).

## Open questions

- PDFKit or PDFium as the main text source. The spike tests both on real PDFs.
- Which method reads a file marked "at risk" of lost spaces: PDFKit's characters with word breaks from Apple OCR, PDFium, or Apple OCR alone. On the one affected spike paper they found 98%, 98% and 99% of the spaces, and Apple OCR alone differed in 12% of the characters, misread marks included.
- Whether Apple's document recognizer gives a usable reading order on born-digital pages. The spike tests it.
- Which layout models convert to Core ML, and whether their weight licences allow it.
- How to measure reading-order doubt on layouts beyond LaTeX papers, such as Word reports, magazines and textbooks with sidebars. The M0 spike's count of jumps between the left and right halves of a page is a candidate, tested only on two-column LaTeX papers.
- How the cache handles a macOS update. A key that includes the macOS build parses every page again after each update. A key without it mixes text from two versions of PDFKit.
- What reads a file that PDFKit cannot open. The answer depends on whether PDFium ships.
- The embedding model for search by meaning: Apple's built-in embeddings, or a small MLX model.
- The oldest supported macOS version.
- How worker processes start and stop: started per command, or kept running while idle.
- Where the cache lives, and its size limit.
- The quality thresholds that make a page `low-quality`. They get tuned until goal G11 in [GOALS.md](GOALS.md) passes.
