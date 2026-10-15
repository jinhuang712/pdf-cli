<!-- what-we-build: drafted 2026-10-15 -->
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
   │      other images and drawings ─► a marker + `pdf crop` command
   │      comments, form values, links ◄── PDFKit annotations
   │      headings, footnotes, running headers, footnote markers
   │              ◄───── font sizes and positions
   │      hidden text ─► a marker in place, its words only with a flag
   │
   └─ 4. Quality check, then every result is cached
          ok ──────────► agent reads the text
          unsure ──────► two readings + `pdf pick` (words only)
          doubtful ────► failure block + `pdf crop` command
          or failed      ──► agent looks at the crop itself
                         ──► its text stays behind `--raw`

OFF BY DEFAULT: added only when a goal fails without them
   · Layout model on Core ML: labels footnotes and headings in one pass
   · Local vision model (milestone M3): hard pages and formulas

(*) See the decision on fonts that hide spaces.
```

The "at risk" check comes from the M0 spike: a font that declares character 32 twice as wide as a normal space makes PDFKit drop the spaces between words.

## Principles

### Parsing

- **Apple's engines first.** PDFKit and Vision do the work by default, and a downloaded model joins only where the Base setup measurably falls short of a goal. Cost: some pages read worse than a model would read them, until a measurement shows the gap. Holds as: every model that `pdf setup` downloads is listed in this document with the goal it improves and its measured gain over Base.
- **The file's own structure first.** Tags, bookmarks, page labels and the text layer win over inference, and models fill only the gaps. Cost: a badly tagged PDF misleads the parser until a quality check catches it. Holds as: every block records its source (`file`, `layout`, `ocr` or `vlm`), and a model-made block appears only where the file states nothing.
- **Escalate per page.** Each page goes through the text layer, the layout model when it is installed, OCR and a vision model when it is installed, in that order, and stops at the first step that reads it well. Cost: one document mixes methods, so quality varies from page to page. Holds as: every page record names the step that produced it.

### Failure

- **A failed page always holds a failure block.** A page that fails to parse, or reads below the quality bar, gets a failure block in its place: the page, the reason and the quality score. Cost: output on hard documents gets noisy, and agents must handle failure blocks. Holds as: every page record has a status (`ok`, `low-quality` or `failed`) with its reasons, and the output writer turns every page that is not `ok` into a failure block.
- **Every failure names its way out.** The way out is the agent's own image understanding: each failure block carries the ready-to-run `pdf crop` command for the smallest region that holds the doubt, with the lines around it. Each failure block also names `--raw`, which shows the doubtful text it replaced, labelled with its reason. Cost: the agent pays image tokens for each crop it reads, and a region found too small hides context. Holds as: the output writer emits no failure block without a crop command and a `--raw` line, and the crop covers the block's own region, or its page when the whole page is in doubt.
- **The agent judges what language can show.** When two readings of a passage differ in words, such as spacing or a sentence spliced across columns, the block shows both readings, and the agent picks one with `pdf pick`. Readings that differ in digits, table cells or formulas go out as a crop, with both readings behind `--raw`. Cost: extra tokens for the words that differ, and a wrong pick lasts until `reparse`. Holds as: `pdf pick` accepts only one of the tool's own readings, picks live in their own table apart from the parsed pages, and every picked span carries a `[picked]` label in the output.
- **Failure is reported three times.** It appears in place, in the summary line at the top of the output, and in the exit code, so an agent that reads only one of them still sees it. Cost: the same failure shows up in three places. Holds as: the exit code for partial failure differs from the codes for success and total failure, and the summary counts every page that is not `ok`.
- **Doubt counts as failure.** A garbled text layer, an uncertain reading order or a low OCR confidence gives the page the status `low-quality`, reported like a failure. Cost: more warnings on hard documents. Holds as: each quality check has a threshold, and a page below any threshold gets the status `low-quality`.

### Silent errors

A page can read wrong while it looks right, and the agent believes what it is handed. Each trap found so far gets its own check.

- **Table regions replace their text.** PDFKit turns a table into a stream of numbers without rows or columns, as the M0 spike showed. The text inside a detected table stays out of normal output, and the table goes out as an image (see the decision on tables below). `--raw` shows the text in place, labelled as flat text that lost its rows and columns. The words inside a figure, such as a chart's axis labels, follow the same rule. Cost: a table the detector misses still leaks its flat numbers. Holds as: the output writer moves every text block inside a table or figure region behind `--raw` and emits one table or figure block in its place, and goal G8 in [GOALS.md](GOALS.md) scores table detection.
- **Raised and lowered characters are found from their boxes.** Plain text turns 10⁻⁵ into "10−5", as the M0 spike showed. A character set smaller and above or below its line's baseline is a superscript or a subscript. Cost: a font that reports odd boxes gets wrong marks. Holds as: every character set smaller and off the baseline leaves the text layer with a superscript or subscript mark, or as a footnote or citation marker.
- **One sample page per file is checked against its image.** A broken font table can map shapes to wrong letters, and an old OCR layer in a scan can hold misreads. Both look like real words. Apple OCR reads one sample page, and its words are compared with the text layer's words. Cost: about 0.6 s per file. Holds as: a file whose sample page disagrees beyond the threshold has every page escalate to OCR, and its old text layer stays behind `--raw`, labelled `[old OCR]`.
- **Spaces are checked before and after reading.** A font that declares character 32 wider than a normal space makes PDFKit drop the spaces between words, as the M0 spike found. A Word-made spike paper also loses 1–2 spaces per page, for a reason still unknown. Before reading, the font check measures each word gap in a page's text operations against half its font's declared width for character 32, counting only body fonts, the fonts that hold at least a quarter of the page's gaps: a maths font can declare a wide character 32 harmlessly. A file with at least 5% risky gaps, and at least 20, is "at risk", and so is a page with at least 10%, and at least 10, for a file that mixes papers. On the eleven samples, the paper that loses its spaces had 29%, and the ten others had none on any page. After reading, a count of run-together words checks every page. Cost: about 0.3 ms per page for the check. Holds as: every page record stores its run-together word count, and a page above the threshold gets the status `low-quality`.

### Cache

- **Pay once, read many times.** Results are keyed by page content and parser version, and failed pages are cached with their reasons too. Cost: disk space, and a cache that must stay correct. Holds as: no command parses a page whose key is already in the cache, except `reparse`.
- **Annotations leave the cache alone.** The key hashes what each page draws, its boxes, content streams and resources, not the file's bytes, so a highlight appended to the file leaves every page key unchanged. Comments, highlights and form values are cached apart, by the file's bytes, so a new highlight re-reads only the annotations. Cost: hashing every page takes time when a file is added, about 1.3 ms per page on a 456-page file. Holds as: a test appends a highlight the way Acrobat saves one, and every page key stays the same. A file that PDFKit saved is the exception (see the decision on PDFKit saves).
- **Same file, same answer.** Models are pinned, decoding never samples, and a vision model's output is cached. Cost: the project gives up the extra accuracy that sampling sometimes buys. Holds as: two parses of the same file with the same version produce byte-identical output.

### Output

- **Every claim has an address.** Every block carries its page and its position on the page. Cost: a few tokens per block. Holds as: every block type in the output schema has `page` and `bbox`.
- **Nothing goes missing without a trace.** Every part of a page reaches normal output as text or as a marker in its place, as the stance in [PHILOSOPHY.md](PHILOSOPHY.md) says: images outside any figure, comments, highlights, form values, link targets, and everything set aside as hidden or doubtful. A marker names what sits there, why it was set aside and the command that shows it. Cost: a few tokens per marker, and each kind of page object needs its own handling. Holds as: on every page of the test sets, each text run, image, annotation and form field that PDFKit reports appears in the output as text or a marker, which goal G17 in [GOALS.md](GOALS.md) counts.
- **Text first, pixels on request.** Images come only when the agent asks for them. Cost: the agent can miss a visual cue it did not ask about. Holds as: only `crop`, `dump --figures`, `dump --tables` and `dump --embedded-images` write image files.

### Performance

- **First answer over full parse.** The requested page is parsed first, and the rest of the document follows in the background. Cost: a page parsed alone lacks the whole document's context, such as heading levels and footnote numbering. Holds as: output from a partly parsed document is marked provisional, and the mark clears once the full parse ends.
- **Parallel by process.** Parsing runs in separate worker processes. Cost: each worker holds its own memory and loaded models. Holds as: no PDF engine call runs on two threads of one process.

### Safety

- **Untrusted files stay in a child process.** Each parse runs in a worker with a time limit and a memory limit. Cost: a process starts for each job. Holds as: only workers open PDF content, the CLI process reads only the cache, and a worker that hits a limit yields a `failed` page instead of a crash.
- **Invisible text leaves a marker, not its words.** Text that a reader cannot see is flagged, and a marker takes its place in normal output: text drawn in the color behind it, tiny, clipped, covered by an image, off the page or in a layer switched off. The marker gives the hidden text's size, how it was hidden and the command that shows it, so nothing goes missing without a trace. Cost: visibility depends on what is drawn behind the text, so every text block needs a look at the layers below it, and an OCR text layer is invisible by design, so it needs its own rule. Holds as: invisible text over a scanned image counts as a text layer, white text on a dark box counts as visible, and every other invisible block reaches normal output as a marker, with its words only behind an explicit flag.
- **Parsing stays offline.** Models download only during setup. Cost: a missing model needs a setup step before first use. Holds as: a test parses the open test set under a network monitor and sees zero connections.
- **PDF actions never run.** JavaScript, launch actions and embedded files stay inert. `pdf info` lists them, so the agent knows they exist, and `pdf dump` saves attachments and prints scripts as text. Cost: none for reading. Holds as: workers call no engine API that runs a document action, and `dump` writes attachments and scripts without opening or running them.

### Testing

- **Real PDFs are the test.** Every change and every macOS release reruns a test set of real documents with expected output. Cost: building and labelling the set takes real work. Holds as: CI runs the open set on every pull request. The open set holds only open-access PDFs, such as arXiv papers under CC-BY, and a private set of the user's own PDFs stays local.
- **Scoring weighs wrong over missing.** A wrong block costs a test more than a missing one, as the philosophy says. Cost: a parser that returns less can outscore one that returns more. Holds as: the scorer applies a heavier weight to wrong blocks, and the weight lives in [GOALS.md](GOALS.md).

## Decision: Swift over Rust, Go and Python — 2026-10-14

Swift wins because the tool runs only on macOS, and on macOS every engine the project needs is first-class in Swift. The M0 spike confirmed the choice: PDFKit, Core Graphics, Vision and Core ML all ran from Swift with the Command Line Tools alone, without Xcode.

| Option | For | Against |
|---|---|---|
| **Swift** | PDFKit, Core Graphics, Vision (including the macOS 26 document recognizer), Core ML and MLX Swift are all direct calls. It ships as one binary with fast startup. | Few reference implementations to port from. A smaller pool of contributors. |
| Rust | Memory safety for parsing untrusted files. One core can serve many languages. | Apple frameworks come through the `objc2` bindings, and MLX is second-class. A Swift layer is still needed for the newest Apple APIs. |
| Go | A simple CLI and a single binary. | Weak PDF and machine-learning libraries. Apple frameworks need cgo. |
| Python | Every leading parser (Docling, MinerU) and model is written in it. | A PyTorch install weighs gigabytes, and models take seconds to load. |

The M0 spike tested the three riskiest bets, and the decisions below record its answers:

- The text quality of PDFKit against PDFium on real PDFs.
- The speed and quality of a layout model converted to Core ML.
- The reading order that Apple's document recognizer gives on born-digital pages.

Existing Swift projects show the pieces work: mac-ocr and vision-book-digitizer call Apple's document recognizer, and `mlx-swift-lm` already runs GLM-OCR.

## Decision: macOS only — 2026-10-14

The tool supports macOS and no other platform. The reason lives in [PROPOSAL.md → What we don't want](PROPOSAL.md#what-we-dont-want): Apple's PDF, OCR and Neural Engine frameworks are the project's main advantage.

## Decision: macOS 11 as the oldest supported version — 2026-10-15

The tool supports macOS 11 and newer, on Apple Silicon and Intel. macOS 11 is the oldest version that ships every engine the base tool needs. A feature that needs a newer macOS checks the version when it runs and turns off below it, and `pdf doctor` names what an upgrade would unlock.

| Feature | Needs |
|---|---|
| PDFKit text, figures from drawing commands, and OCR in English, Chinese, French, German, Italian, Portuguese and Spanish | macOS 11 |
| Layout models on Core ML, if a goal needs one | macOS 12, because the models convert to Core ML's ML Program format |
| OCR in Japanese and Korean | macOS 13 |
| The local vision model through MLX Swift | macOS 14 on Apple Silicon. MLX Swift declares macOS 14 as its minimum, and a Swift package cannot depend on a package with a higher minimum, so the vision model runs in a helper binary of its own. |
| Scan structure: paragraphs, tables and lists | macOS 26 |

| Option | For | Against |
|---|---|---|
| **macOS 11** | Every base engine is there, including Chinese OCR. Inside the range Apple's current compiler supports (macOS 11–26), and Homebrew still runs on it. | Homebrew serves macOS 11–14 at its lowest support tier. Only macOS 26 is tested, so bugs on older versions reach users first. |
| macOS 10.15 | Reaches Intel Macs that stop at Catalina. | Apple's OCR reads English only. Homebrew no longer runs on it. Below the compiler's supported range. |
| macOS 26 | Every feature works, and the tested version is the only supported one. | Leaves out every Mac that cannot run macOS 26, most Intel Macs among them. |

The universal binary builds for macOS 11 on both architectures, checked with `scripts/build-universal.sh` on 2026-10-15.

## Decision: Apple PDFKit over PDFium and a parser of our own — 2026-10-14

PDFKit and Core Graphics parse and render, and PDFKit is the only text source in the binary. PDFium stays out of the binary, and the test scripts use it to cross-check PDFKit. The decision is provisional: it reopens if Apple's engines fail a goal on the open test set.

The M0 spike compared the engines on 10 recent arXiv papers ([spike/M0.2-text.md](spike/M0.2-text.md), [spike/M0.3-reading-order.md](spike/M0.3-reading-order.md)):

- PDFKit read about 9 ms per page, process start included, and PDFium about 2 ms.
- PDFKit kept two-column text in order best: 50 jumps between the left and right halves of the page on 36 pages, against 66 for PDFium, 112 for poppler and 121 for Apple's document recognizer. A clean page has one jump. The count is indirect, because a full-width figure makes some jumps correct.
- PDFKit ran words together on 1 of the 10 papers. The next decision records the cause and its repair.

| Option | For | Against |
|---|---|---|
| **PDFKit and Core Graphics** | Ship with macOS, and Apple maintains them. Crops look exactly like Preview. The best column order in the spike. | Closed: the project cannot fix their bugs, and their behavior can change between macOS versions. Some fonts make it drop spaces. |
| PDFium | Chrome's engine, open source under BSD, with years of fixes for broken files. Kept every space in the spike. | One more library to bundle and update, outside Apple's engines. |
| hayro | A pure-Rust PDF renderer under Apache-2.0, in active development. | Young, and Rust in a Swift project. |
| MuPDF and PyMuPDF | Fast and complete. | AGPL, which a permissive public repo cannot take on. |
| A parser of our own | Full control. | Years of work to handle broken files as well as PDFium, with no difference a user could see. |

PDFKit wins because of the principle "Apple's engines first": its one failure in the spike has a known cause, and an Apple-only repair that matched PDFium.

## Decision: Apple OCR word breaks over PDFium for fonts that hide spaces — 2026-10-14

Some fonts declare character 32 wider than a normal space, and PDFKit then drops the spaces between words. The font check marks such a file "at risk" before reading. For an at-risk file, the tool keeps PDFKit's characters and takes only the word breaks from Apple OCR. The decision is provisional, like the one above.

The M0 spike scored each method on the one affected paper, against PDFKit's text of a copy whose fonts were corrected ([spike/M0.2b-spaces.md](spike/M0.2b-spaces.md)):

| Option | Spaces found | Characters matching | Spaces added | Note |
|---|---|---|---|---|
| **PDFKit characters + Apple OCR word breaks** | 97.6% | 99.9% | 71 | Apple-only. About 0.63 s per page, paid by at-risk files only. |
| PDFium | 97.5% | 98.3% | 276 | A non-Apple library to bundle. |
| Apple OCR alone | 98.9% | 88.4% | 71 | Misreads small marks, such as a superscript 1 as `'`. |
| PDFKit alone | 71.2% | 99.9% | 0 | Words run together on every page. |

Task M1.2 built the repair and scored it the same way: 97.8% of spaces found, 99.9% of characters matching and 68 spaces added, with macOS 26's document recognizer. The text recognizer that older macOS versions use found 96.2% and added 93. A repaired page costs 0.64–0.8 s of OCR in one worker, and the whole 18-page paper took 6.9 s with four workers. The first page of the paper, unseen, came back in 1.33 s, inside goal G2's 2 s.

Most added spaces sit inside formulas and number lists. The run-together count flags the spaces still missing (see Silent errors), and where two readings still differ in words, the agent picks one with `pdf pick`. The sample is one paper, the only one of ten with this problem.

## Decision: line-end hyphens resolved by the page and macOS's word list — 2026-10-15

PDFKit keeps the hyphen where a word breaks across lines, as in "exam-" and "ple". The text layer joins the two halves when the joined word appears elsewhere on the page, or in macOS's word list at `/usr/share/dict/words`, allowing common endings such as "-s" and "-ed". Otherwise the hyphen stays, as in "self-attention". A capital letter or a digit after the break always keeps the hyphen. When in doubt the hyphen stays, because "data-set" still reads right and a wrongly joined word does not.

| Option | For | Against |
|---|---|---|
| **The page's words and macOS's word list** | Apple-only and fixed, so the same file always reads the same. | The list is old: it lacks "dataset", so such a word joins only when the page spells it whole elsewhere. |
| Every hyphen kept | Never wrong. | "exam-ple" in the text breaks search. |
| Every hyphen dropped | Simple. | "selfattention" is wrong. |
| macOS's spell checker | Knows modern words. | Learns from each user, so two Macs can read one file differently. |

## Decision: Apple Vision over Tesseract and RapidOCR — 2026-10-14

Vision reads scanned pages and garbled pages.

- It runs on the device and on the Neural Engine.
- It installs nothing, because it ships with macOS.
- On macOS 26, its document recognizer returns paragraphs, tables and lists, along with the text.

Tesseract and RapidOCR would each add an install and a model to ship. On older macOS versions, Vision falls back to plain text recognition, without the document structure.

The document recognizer reads scans and repairs spaces, and PDFKit sets the reading order of born-digital pages. On 36 born-digital two-column pages in the M0 spike, the recognizer mixed the two columns badly on 2 pages and took a median 0.67 s per page ([spike/M0.3-reading-order.md](spike/M0.3-reading-order.md)).

## Decision: Core ML on the Neural Engine over a Python Docling worker — 2026-10-14

Layout models run as Core ML models on the Neural Engine. This keeps the tool one binary, with no Python.

| Option | For | Against |
|---|---|---|
| **Core ML** | Uses the Neural Engine, and ships inside the binary. | Some models fail to convert. Apple decides whether a model runs on the Neural Engine. |
| MLX | Apple's own machine-learning framework, with a Swift API. | Each model must be ported. It runs on the GPU. |
| ONNX Runtime | Runs almost any exported model. | One more runtime to bundle. |
| Python Docling worker | A proven pipeline, under MIT. | Brings back Python and PyTorch, a gigabyte-scale install and seconds of model loading. |

When a model fails to convert to Core ML, the fallback is MLX first, then ONNX Runtime. Model weights come only from licences that allow use in a public repo.

The M0 spike converted Docling's two layout models, heron and egret-medium, both under Apache-2.0 ([spike/M0.4-coreml.md](spike/M0.4-coreml.md)). Full precision matched PyTorch exactly. Mixed precision on all compute units ran in 15–29 ms per page and missed about 1 region in 100. Plain half precision gave wrong results on the CPU and the Neural Engine. Swift compiled and loaded the models without Xcode.

## Decision: Rules on PDFKit's fonts and positions over a default layout model — 2026-10-14

Figures, footnotes, headings, running headers and footnote markers come from simple rules on what PDFKit and Core Graphics report: fonts, sizes, positions and drawing commands. A layout model joins only when a goal fails without it, as the principle "Apple's engines first" says. The decision is provisional, like the text-source decision.

| Option | For | Against |
|---|---|---|
| **Rules, no model** | Apple-only, with nothing to download. Found 54 of 54 figures with their captions on 116 spike pages, at about 9 ms per page ([spike/M0.3b-figures-base.md](spike/M0.3b-figures-base.md)). | Tuned on the same papers it was tested on. Rules for footnotes and headings are untested. Scans need OCR's structure instead. |
| egret-medium in `pdf setup` | Labels footnotes, headings, captions, formulas, lists, headers and footers in one pass, in 15–27 ms per page. About 50 MB. | A download, and its accuracy on our own pages is unmeasured. |
| heron in `pdf setup` | The larger Docling model, in 23–29 ms per page. | About 100 MB, with the same unmeasured accuracy. On the spike's scan, it and egret disagree. |

## Decision: Tables as images over rebuilt cells — 2026-10-14

A table reaches the agent as a crop, and the agent reads the cells with its own image understanding. The reason lives in [FEATURES.md → Not planned](FEATURES.md#not-planned): a rebuilt cell can be wrong and still look right.

| Option | For | Against |
|---|---|---|
| **A crop, read by the agent** | The agent sees the table as printed, merged cells and odd layouts included. Nothing is rebuilt. | Image tokens for every table the agent reads. A dense table needs a sharp crop, and the agent can still misread a digit. |
| PDFKit text | Free, with the exact digits. | Rows and columns are lost, as the M0 spike showed. |
| Apple's document recognizer | Ships with macOS 26, and returns cells. | Untested on tables, and a wrong cell looks right. |
| A table-structure model, such as the one Docling uses | Built for this job. | A download, and a wrong cell still looks right. |

The table's text stays in the keyword index, so a search still finds the page that holds a table, and `--raw` shows it, labelled as flat text that lost its rows and columns.

## Decision: SQLite over qmd and Tantivy — 2026-10-14

One SQLite file holds the cache and both kinds of search.

| Option | For | Against |
|---|---|---|
| **SQLite** | One file holds pages, positions, the keyword index (FTS5) and the vectors. It serves several agents at once, and GRDB.swift makes it native to Swift. | Search by meaning needs a vector extension. |
| qmd | Keyword search, search by meaning and reranking, with an MCP server already built. | Needs Node, reads only Markdown files, and keeps its index apart from our page positions. |
| Tantivy | A fast full-text engine. | A Rust dependency in a Swift project, and a second store beside the cache. |

## Decision: macOS's Library folders, with no size limit — 2026-10-15

What the tool can rebuild from the PDFs goes to `~/Library/Caches/pdf-cli/`: the SQLite cache with its keyword index, and the crop images. The agent's own work goes to `~/Library/Application Support/pdf-cli/`: the library list, picks and memos. These are the folders macOS sets aside for each kind of data, so a cleanup tool that clears caches costs time and leaves the agent's work intact.

The cache keeps every parse result until `pdf rm` or `pdf gc` removes it, as the principle "Pay once, read many times" says. Crop images are the exception: each one goes 7 days after it is written, because making it again needs no parse.

The 10 sample papers hold 3.8 KB of text per page, measured with PDFKit. With positions and the keyword index, a page likely takes 10–20 KB, so a 30-page paper takes about 0.3–0.6 MB, against 1.6 MB for the average sample PDF itself. The estimate stays unmeasured until the cache exists.

| Option | For | Against |
|---|---|---|
| **Library folders, no size limit** | macOS's own convention. A cleared cache costs only time. Nothing is parsed twice. | The cache grows with every PDF an agent opens, because any command adds a PDF on first use. |
| A size cap that removes the least recently read PDFs | Disk use stays bounded. | A removed PDF is parsed again. For a 300-page scan, that is about 3 minutes of OCR on one worker, at 0.6 s per page. |
| One dot-folder, such as `~/.pdf-cli/` or `~/.cache/pdf-cli/` | One place that command-line users know. | Mixes rebuildable data with the agent's own work, and follows Linux's convention instead of macOS's. |

## Decision: macOS updates leave the cache alone — 2026-10-15

The cache key holds the page content and the parser version, and leaves the macOS version out, so a macOS update parses nothing again. Each page records the macOS build it was parsed on, and `pdf reparse` reads a page or a file again on the running macOS. When the test set shows that a macOS release changes the output, a new pdf-cli release raises the parser version, and each page is parsed again on its next read.

This follows "Pay once, read many times" and "Same file, same answer". A document seldom mixes two macOS versions, because a worker parses the whole document right after its first use.

| Option | For | Against |
|---|---|---|
| **macOS left out of the key** | Nothing is parsed twice. A cached answer never changes on its own. | Apple's fixes reach a cached file only through `pdf reparse` or a new pdf-cli release. |
| The macOS major version in the key | Each yearly macOS brings its fixes to every file read again. | Every file is parsed again once a year. A 300-page scan costs about 3 minutes of OCR. |
| The full macOS build in the key | Every page matches the running macOS. | Every minor update, several a year, parses everything again. |

## Decision: a worker process per job over a background service — 2026-10-15

Each parse job starts its own worker process, which exits when the job ends. A short-lived runner process starts the workers for one file: it stops any worker that spends more than 30 s on a page or holds more than 2 GB of memory, retries a page whose worker crashed once, and writes what the workers report to the cache. The runner never opens PDF content itself. A command that needs only one page returns once that page is ready, and the runner goes on with the rest of the document in the background, then exits. The runner holds a lock per file and per document in the SQLite cache, so two commands never parse the same page twice.

Task M1.1 measured this on a 456-page file built from the sample papers: the first page in 0.73 s, the whole file within 4 s, and a cached read in 20–30 ms per command. Three commands at once on the new file started one runner, and each page went to one worker. A planted hang, runaway memory or crash cost one page, and the rest of the file read normally (`scripts/test-cache.sh`).

The principle "Untrusted files stay in a child process" already pays a process start for each job, and the start is cheap enough: the M0 spike read a whole paper's text and page 1's figures in at most 0.36 s per file, each in a fresh process, against the 2 s of goal G2. The decision reopens when a model joins the default and its load time breaks goal G2 or G4.

| Option | For | Against |
|---|---|---|
| **A worker per job** | Nothing runs while the tool is idle. Nothing to install or upgrade beside the binary. A crash ends one job. | Every job pays a process start, and every worker loads its models again. |
| A background service that stays running | Loaded models and warm engines stay in memory. | A launchd service to install, upgrade and restart, and memory held while idle. |

## Decision: a 5,000-token default budget over no default — 2026-10-15

`read` and `search` stop at 5,000 tokens unless the agent passes `--budget`. The default keeps the stance "No whole document by default" in [PHILOSOPHY.md](PHILOSOPHY.md) true for an agent that passes no flags. Search has no default result count, so the budget alone decides how many hits fit, about 60 by estimate.

A sample-paper page holds about 950 tokens of text, so 5,000 tokens is about 5 pages, or 20,000 characters. Claude Code shows a command's output in full up to about 30,000 characters and moves the rest to a file, according to third-party reports. Our cut lands between blocks and ends with the command that continues. Claude Code's cut lands anywhere.

| Option | For | Against |
|---|---|---|
| **5,000 tokens** | A typical paper section in one call, inside Claude Code's 30,000 characters. | A long section takes two calls. |
| 2,000 tokens | Cheaper per call. | More calls for the same section. |
| No default | The agent always gets everything it asked for. | A flagless read of a 300-page book sends about 285,000 tokens, and Claude Code cuts it mid-sentence. |

## Decision: a marker in place of hidden text over its words with a label — 2026-10-15

Normal output replaces hidden text with a marker at the same spot: its size, how it was hidden, and the command that shows its words. Nothing goes missing without a trace, and planted words reach the agent only when it asks for them.

| Option | For | Against |
|---|---|---|
| **A marker in place** | The agent knows where hidden text sits and how much there is, and planted instructions stay out of its context. | One more command to read the hidden words. |
| The words in place, with a label | Nothing is even one command away. | Planted instructions reach every agent that reads the page. In Microsoft's 2024 study, wrapping untrusted text in markers only about halved attack success on GPT-3.5-Turbo ([Hines et al.](https://arxiv.org/abs/2403.14720)). |
| A count in the summary line only | The shortest output. | The agent learns the page, but not where on it or how much. |

## Decision: a loud failure for a file PDFKit cannot open — 2026-10-15

When PDFKit cannot open a file, the whole file fails with a reason the agent can act on: not a PDF, locked by a password, or damaged. The tool reads nothing else from it. This follows the PDFKit decision, which keeps PDFium out of the binary, and "Wrong is way worse than missing" in [PHILOSOPHY.md](PHILOSOPHY.md). How often a file fails this way is unmeasured. The safety test set holds broken PDFs, and the decision reopens if daily use or the open test set shows such files are common.

| Option | For | Against |
|---|---|---|
| **A loud failure** | Apple-only, with nothing to bundle. The agent learns at once, and can tell the user. | A damaged file that PDFium could read stays unread. |
| PDFium as a fallback | Opens many damaged files. | A non-Apple library in the binary, which the PDFKit decision keeps out. |
| A repair tool the user has installed, such as qpdf | Repairs many damaged files. | Depends on what each Mac has, so one file gives different answers on different Macs. |

## Decision: a file that PDFKit saved counts as a new file, with a warning — 2026-10-15

A PDFKit save, the way macOS Preview saves a highlight, rewrites every page. Task M1.1 found that it re-embeds the fonts in the MacRoman encoding and drops their Unicode maps, so characters outside MacRoman read back wrong: on an arXiv sample, "∗" came back as "→" and the math letter "𝑒" as "!". Users have reported the same damage from Preview for years ([Zotero forum](https://forums.zotero.org/discussion/comment/274497)). The test ran on PDFKit's own save, not on Preview itself.

Such a file gets new page keys and is parsed again, as a new file. Its summary line warns that a PDFKit save can damage the text, and that an earlier copy may read better. The tool recognizes the save by the file's producer, "Quartz PDFContext". A highlight that an app appends without rewriting the file, as Acrobat saves one, still leaves every page key unchanged.

| Option | For | Against |
|---|---|---|
| **A new file, with a warning** | Nothing wrong is ever served, and the agent learns why the text may be poor. | The file is parsed again, and its damaged text is what the agent reads. |
| The earlier copy's pages, reused while the character positions line up | The agent keeps the good text. | A real edit that keeps the positions would be served stale, and wrong is way worse than missing. |
| The earlier copy's reading offered beside the new one, to pick with `pdf pick` | Nothing lost and nothing silently wrong. | Needs a history of each file's earlier copies. |

## Decision: one Homebrew binary over a Python package — 2026-10-14

The tool installs with one Homebrew command. Models that the base install leaves out download in a separate setup step. A Python package would bring PyTorch, an install measured in gigabytes.

## Decision: no LLM inside the tool — 2026-10-14

The tool returns text, crops and failure reports, and the calling agent does all the reasoning. The reason lives in [PROPOSAL.md → What we don't want](PROPOSAL.md#what-we-dont-want).

## Open questions

- How to measure reading-order doubt on layouts beyond LaTeX papers, such as Word reports, magazines and textbooks with sidebars. The M0 spike's count of jumps between the left and right halves of a page is a candidate, tested only on two-column LaTeX papers.
- The embedding model for search by meaning: Apple's built-in embeddings, or a small MLX model.
- The quality thresholds that make a page `low-quality`. They get tuned until goal G11 in [GOALS.md](GOALS.md) passes.
- How to serve the first page of a very long file within goal G2. The runner reads every page's key before it parses any page, at about 1.3 ms per page, so a file of more than about 1,400 pages likely misses G2's 2 s.
