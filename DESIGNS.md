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
   │      ├─ at risk, or ► Apple OCR reads the page image, and only
   │      │  words run   its word breaks are kept  (*)
   │      │  together
   │      └─ scan or ──► Apple OCR document recognizer:
   │         garbled     text, paragraphs, tables, lists,
   │                     read a second time to check the first
   │
   ├─ 3. Structure ───── simple rules, no model
   │      figures ◄───── drawing commands + "Figure N" captions
   │      other images and drawings ─► a marker + `pdf crop` command
   │      comments, form values, links ◄── PDFKit annotations
   │      headings, footnotes, running headers, footnote markers
   │              ◄───── font sizes and positions
   │      hidden text ─► a marker in place, its words only with a flag
   │
   └─ 4. Quality measures, cached with every result, judged when read
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

- **A failed page always holds a failure block.** A page that fails to parse, or reads below the quality bar, gets a failure block in its place: the page, the reason and the quality score. Cost: output on hard documents gets noisy, and agents must handle failure blocks. Holds as: every page read gets a status (`ok`, `unsure`, `low-quality` or `failed`) with its reasons, and the output writer turns every failed or low-quality page or block into a failure block.
- **Every failure names its way out.** The way out is the agent's own image understanding: each failure block carries the ready-to-run `pdf crop` command for the smallest region that holds the doubt, with the lines around it. Each block that replaced doubtful text also names `--raw`, which shows that text, labelled with its reason. A failed page has no text to show. Cost: the agent pays image tokens for each crop it reads, and a region found too small hides context. Holds as: the output writer emits no failure block without a crop command, no low-quality block without a `--raw` line, and the crop covers the block's own region, or its page when the whole page is in doubt.
- **The agent judges what language can show.** When two readings of a passage differ in words, such as spacing or a sentence spliced across columns, the block shows both readings, and the agent picks one with `pdf pick`. Readings that differ in digits, table cells or formulas go out as a crop, with both readings behind `--raw`. Cost: extra tokens for the words that differ, and a wrong pick lasts until `reparse`. Holds as: `pdf pick` accepts only one of the tool's own readings, picks live in their own table apart from the parsed pages, and every picked span carries a `[picked]` label in the output.
- **Failure is reported three times.** It appears in place, in the summary line at the top of the output, and in the exit code, so an agent that reads only one of them still sees it. Cost: the same failure shows up in three places. Holds as: the exit code for partial failure differs from the codes for success and total failure, and the summary counts every page that is not `ok`.
- **Doubt counts as failure.** A garbled text layer, an uncertain reading order or OCR readings that disagree give the page, or the block, the status `low-quality`, reported like a failure. Cost: more warnings on hard documents. Holds as: each quality check has a threshold, and a page or block below any threshold gets the status `low-quality`.

### Silent errors

A page can read wrong while it looks right, and the agent believes what it is handed. Each trap found so far gets its own check.

- **Table regions replace their text.** PDFKit turns a table into a stream of numbers without rows or columns, as the M0 spike showed. The text inside a detected table stays out of normal output, and the table goes out as an image (see the decision on tables below). `--raw` shows the text in place, labelled as flat text that lost its rows and columns. The words inside a figure, such as a chart's axis labels, follow the same rule. Cost: a table the detector misses still leaks its flat numbers. Holds as: the output writer moves every text block inside a table or figure region behind `--raw` and emits one table or figure block in its place, and goal G8 in [GOALS.md](GOALS.md) scores table detection.
- **Raised and lowered characters keep a mark.** Plain text turns 10⁻⁵ into "10−5", as the M0 spike showed. PDFKit reports each run of text with its font size and how far its baseline is raised. A character set smaller than its line's main text, and raised or lowered against it, is a superscript or a subscript, as in `10^{-5}`, `LLM_{tea}` and `Haoru Tan^{1,†}`. Main-size text that PDFKit reports a little raised, as in some table cells, keeps no mark. Cost: a font that reports odd sizes gets wrong marks. Holds as: every character set smaller and off the line's baseline leaves the text layer with a superscript or subscript mark, or as a footnote or citation marker.
- **One sample page per file is checked against its image.** A broken font table can map shapes to wrong letters, and an old OCR layer in a scan can hold misreads. Both look like real words. Apple OCR reads a band around the densest paragraph of the first page among the first ten with at least 300 letters, and the check counts the share of OCR's words, four letters or longer, that the text layer spells the same, with spaces left out so a layer that lost its spaces still matches. A share under 0.7 fails. On the eleven samples it was 0.90–0.99, the scan's old OCR layer 0.94 included, and a layer with every letter shifted by one scored 0.00. Cost: 0.35–0.6 s per new file, in a worker of its own beside the index. Holds as: a file whose sample fails has every page read by OCR and cached apart, and its old text layer stays behind `--raw`, labelled `[old OCR]`.
- **Spaces are checked before and after reading.** A font that declares character 32 wider than a normal space makes PDFKit drop the spaces between words, as the M0 spike found. A Word-made spike paper also loses 1–2 spaces per page, for a reason still unknown. Before reading, the font check measures each word gap in a page's text operations against half its font's declared width for character 32, counting only body fonts, the fonts that hold at least a quarter of the page's gaps: a maths font can declare a wide character 32 harmlessly. A file with at least 5% risky gaps, and at least 20, is "at risk", and so is a page with at least 10%, and at least 10, for a file that mixes papers. On the eleven samples, the paper that loses its spaces had 29%, and the ten others had none on any page. After reading, a count of run-together words, letter runs longer than 25, checks every page, and a page with any gets the space repair too: the Word-made paper had 1–2 on four pages. A word still in doubt after the repair gets a second reading (see the decision on second readings). Cost: about 0.3 ms per page for the check, and 0.7 s of OCR for each page with run-together words. Holds as: every page record stores its run-together word count, and every page with run-together words goes through the space repair.

### Cache

- **Pay once, read many times.** Results are keyed by page content and parser version, and failed pages are cached with their reasons too. Cost: disk space, and a cache that must stay correct. Holds as: no command parses a page whose key is already in the cache, except `reparse`.
- **Annotations leave the cache alone.** The key hashes what each page draws, its boxes, content streams and resources, not the file's bytes, so a highlight appended to the file leaves every page key unchanged. Comments, highlights and form values are cached apart, by the file's bytes, so a new highlight re-reads only the annotations. Cost: hashing every page takes time when a file is added, about 1.3 ms per page on a 456-page file. Holds as: a test appends a highlight the way Acrobat saves one, and every page key stays the same. A file that PDFKit saved is the exception (see the decision on PDFKit saves).
- **Same file, same answer.** Models are pinned, decoding never samples, and a vision model's output is cached. Cost: the project gives up the extra accuracy that sampling sometimes buys. Holds as: two parses of the same file with the same version produce byte-identical output.

### Output

- **Every claim has an address.** Every block carries its page and its number on the page, and its position in `--json` (see the decision on paragraph numbers). Cost: a few tokens per block. Holds as: every block type in the output schema has `page` and `bbox`.
- **Nothing goes missing without a trace.** Every part of a page reaches normal output as text or as a marker in its place, as the stance in [PHILOSOPHY.md](PHILOSOPHY.md) says: images outside any figure, comments, highlights, form values, link targets, and everything set aside as hidden or doubtful. A marker names what sits there, why it was set aside and the command that shows it. Cost: a few tokens per marker, and each kind of page object needs its own handling. Holds as: on every page of the test sets, each text run, image, annotation and form field that PDFKit reports appears in the output as text or a marker, which goal G17 in [GOALS.md](GOALS.md) counts.
- **Text first, pixels on request.** Images come only when the agent asks for them. Cost: the agent can miss a visual cue it did not ask about. Holds as: only `crop`, `dump --figures`, `dump --tables` and `dump --embedded-images` write image files.

### Performance

- **First answer over full parse.** The requested page is parsed first, and the rest of the document follows in the background, at low priority. Cost: a page parsed alone lacks the whole document's context, such as heading levels and footnote numbering. Holds as: output from a partly parsed document is marked provisional, and the mark clears once the full parse ends.
- **Parallel by process.** Parsing runs in separate worker processes, and every parse on the Mac shares one pool of worker slots (see the decision on the pool below). Cost: each worker holds its own memory and loaded models. Holds as: no PDF engine call runs on two threads of one process, and no more workers run at once than the pool holds.

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

Task M1.2 built the repair and scored it the same way: 97.8% of spaces found, 99.9% of characters matching and 68 spaces added, with macOS 26's document recognizer. The text recognizer that older macOS versions use found 96.2% and added 93. A repaired page costs 0.64–0.8 s of OCR in one worker, and the whole 18-page paper took 6.9 s with four workers. The first page of the paper, unseen, came back in 1.33 s, inside goal G2's 2 s. Task M1.4 changed the rendering, leaving annotations out of the image and rounding its size down, and the score moved to 98.6% of spaces found and 81 added. With the sample check, the first page took 1.69 s.

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

Task M1.4 sends a page to OCR when its text layer is unusable:
- the page draws an image and has fewer than 10 letters and digits, or letters and digits make up under 30% of its characters, as in an old OCR layer of stray marks;
- at least a tenth of its characters, and at least 10, are replacement characters, private-use characters or controls;
- or its file failed the sample check (see Silent errors).

On the samples, no page of the ten born-digital papers went to OCR, and 3 of the scan's 30 pages did, one of them an old layer of 44 stray marks where OCR read 287 words. An OCR'd page took 0.4–1.0 s. Its boxes map back to the unrotated page: on a page turned 90°, 180° or 270°, OCR's blocks sat within 2.3% of the page from the text layer's.

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

## Decision: the library lists files by path, with their document's ID — 2026-10-15

The library list holds one entry per file path, with the file's document and its title. Every command that reads a file adds it, or points it at its new document when the file changed. A file already listed as it is costs one read of the list and no write, so a cached read stays fast. The ID that commands show is the first 8 hex digits of the document's ID, which hashes the page keys, so two copies of one file share an ID. `pdf rm` accepts any 4 digits or more from its start.

`pdf rm` forgets the file and drops every document and page result that no other file still uses. Picks stay: they are the agent's work, kept apart from the cache, and a file added again shows them again. `pdf gc` also forgets files that are gone or changed since they were indexed, results of older parser versions, and the locks of runners that are gone. It then rebuilds the database to give the space back, and empties SQLite's write-ahead log after the rebuild, since the rebuild writes through it: without that, a trial freed nothing.

A cleanup never takes what a read still needs:
- A runner saves a document, its file and the pages its index could not read in one transaction, and `pdf gc` deletes a file's entry only while it still holds the state it read, so a parse in progress keeps its rows.
- The rebuild holds SQLite's write lock, which would make a runner's writes fail, so it runs only while no runner is alive.
- A file is gone only when it is missing from a volume that is mounted. A file on an unplugged drive or an offline share keeps its rows and its library entry, and `pdf ls` shows it as out of reach.
- A cache upgrade marks each file to be indexed again on its next read, instead of forgetting it: forgetting every file let a `pdf gc` right after an upgrade drop every cached page, OCR results included, as the M1.5 review found.

| Option | For | Against |
|---|---|---|
| **One entry per path** | A moved or deleted file shows as such, and `pdf rm` takes the path the agent knows. | Two copies of a file are two entries with one ID. |
| One entry per document | One line per PDF, however many copies. | The list cannot say which path to read, and loses track of a moved file. |

## Decision: a password reaches the workers in their environment — 2026-10-15

`pdf add --password` hands the password to the runner it starts, and the runner's workers inherit it, in an environment variable. Any user on the Mac can read another user's command lines with `ps`, and only the same user can read a process's environment: on the M3, `ps` showed root's command lines and none of root's environments. `pdf add --password <pw>` itself still shows the password in its own command line while it runs, so `--password-stdin` reads it from standard input instead. The password is not stored: a later read of the file comes from the cache, and a file that changes needs `pdf add --password` again. A file the cache knows as locked is indexed again when a password comes. A read without the password that needs a page not yet cached fails the file as locked, and caches no failure for the page.

| Option | For | Against |
|---|---|---|
| **The environment** | Hidden from other users. Nothing stored. | Visible to the user's own processes while the parse runs. |
| A command-line argument | Simple. | Every user on the Mac can see it in `ps`. |
| The macOS keychain | Stored safely, so a changed file opens without asking again. | A keychain prompt in the middle of an agent's work, and a secret kept after the agent is done. |

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

## Decision: a shared pool of worker slots, with pages nobody waits for in the background — 2026-10-15

Every parse by one user on the Mac shares one pool of worker slots, kept in that user's cache folder: half the performance cores, and at least 2. That is 2 on the M3 with 4 performance cores. Before, each runner started one worker per performance core for its own file, so an agent reading three new files ran up to twelve workers, and the author's Mac lagged while task M1.3's measurements ran.

- A slot is an exclusive `flock` on a file in the cache folder. The kernel frees the lock when its holder exits, so a crashed runner never keeps a slot.
- Slot 0 is kept for work a command waits on: the pages it asked for, and a new file's index and sample check. The command hands its pages to the runner it starts, so the runner's first batch already knows them. A pool of one slot keeps nothing apart.
- Pages nobody asked for take the other slots, and their workers put themselves in macOS's background state, which runs them at the lowest priority. A CPU loop ran 2.4 times slower in that state, as on the efficiency cores, where [Eclectic Light's measurements](https://eclecticlight.co/2025/05/09/what-is-quality-of-service-and-how-does-it-matter/) find background work kept.
- When a command asks for a page that a background worker holds, the runner signals the worker, and the worker leaves the background state. macOS lets only a process move itself into that state or out of it.
- A page that runs out of time in the background gets one more try at full speed before it fails, because the 30 s limit counts wall time, and a throttled worker can pass it through no fault of the page.

Measured with the release build on the M3:

| File | Page 1, unseen | Page 2 right after | The rest, in the background | Every page, waited on |
|---|---|---|---|---|
| A paper, 11 pages | 0.78 s | 0.08 s | 1.4 s | |
| The paper that needs the space repair, 18 pages | 1.40 s | 0.52 s | 49 s | 8.2 s, against 6.9 s with four workers before |
| The NACA scan, 30 pages | 1.08 s | 0.94 s | 6.9 s | |
| The 456-page file | 0.79 s | 0.06 s | 43 s | 7.6 s |

The pages an agent waits on keep their speed, because OCR leans on the graphics and neural chips more than on the cores. The cost falls on pages nobody waits for: a file that needs OCR finishes in the background about seven times slower.

| Option | For | Against |
|---|---|---|
| **A shared pool of `flock` slots, with background workers that a request promotes** | Caps the whole Mac, however many files an agent reads at once. The page the agent waits on runs at full speed. Nothing to install. | A runner checks for a free slot every 20 ms, and a file that needs OCR finishes in the background about seven times slower. |
| One worker per performance core in each runner | The fastest full parse. | Three files at once run twelve workers, and the Mac lags. |
| A counting semaphore | One call takes a slot. | A process that crashes while holding a slot never gives it back. |
| A queue in a background service | Exact fairness between files. | A service to install and run, which the decision on worker processes above rejects. |

Holds as: `scripts/test-cache.sh` reads three new files at once and never sees more than two workers, a page asked for while a background worker holds it brings that worker out of the background state, and a page that hangs only in the background reads at its full-speed try.

## Decision: paragraph numbers in text, positions in JSON — 2026-10-15

In text output, each page starts with a heading such as `## p.2`, and each block starts with its number on the page, as in `¶5`. `--json` gives every block its page, its number and its position, and every doubt in either output carries the command that crops it. An agent cites "p.2 ¶5", and `pdf read --from p2.5` goes back to it.

On the ten arXiv samples, the full address on every block, as in `p.2 ¶5 · 0.12,0.41,0.37,0.19`, took about 22% of a read's tokens by the tool's estimate, which likely counts digits low. The number alone takes about 7%: a page came to about 1,030 tokens instead of 1,230. The user chose the number alone.

| Option | For | Against |
|---|---|---|
| **The number in text, the position in JSON** | About 15% fewer tokens on every read. | An agent that wants a block's position reads `--json`. |
| The full address on every block | Every position in plain sight. | About a fifth of every read spent on numbers an agent rarely uses. |

## Decision: a 5,000-token default budget over no default — 2026-10-15

`read` and `search` stop at 5,000 tokens unless the agent passes `--budget`. The default keeps the stance "No whole document by default" in [PHILOSOPHY.md](PHILOSOPHY.md) true for an agent that passes no flags. Search has no default result count, so the budget alone decides how many hits fit, about 60 by estimate.

A sample-paper page holds about 950 tokens of text, so 5,000 tokens is about 5 pages, or 20,000 characters. Claude Code shows a command's output in full up to about 30,000 characters and moves the rest to a file, according to third-party reports. Our cut lands between blocks and ends with the command that continues. Claude Code's cut lands anywhere.

Task M1.7 built it. Tokens are estimated as one per four characters of Latin text and one per character of other scripts. A text block goes out together with the doubts that follow it, and the cut falls between such units, with a `next:` line that names the block to go on from, as in `--from p4.27`. Every read moves on: the first unit after a page's heading goes out even when it alone is larger than the budget. A text block is cut inside, after a word, and the next read goes on from that character, as in `--from p3.2:200`; a failure block or text shown with `--raw` goes out whole. Counts and flags in the summary line come only from what went out. Following each `next:` line rebuilt the full read exactly on five sample files at budgets of 55, 120 and 300 tokens. With full block addresses, a sample page came to about 1,230 tokens, and with paragraph numbers alone to about 1,030, so the default read shows about 5 pages.

| Option | For | Against |
|---|---|---|
| **5,000 tokens** | A typical paper section in one call, inside Claude Code's 30,000 characters. | A long section takes two calls. |
| 2,000 tokens | Cheaper per call. | More calls for the same section. |
| No default | The agent always gets everything it asked for. | A flagless read of a 300-page book sends about 285,000 tokens, and Claude Code cuts it mid-sentence. |

## Decision: each character's glyph box matched to its selection — 2026-10-15

PDFKit's `characterBounds(at:)` counts glyphs, not characters. After a ligature such as "fl", one glyph for two characters, it returns the box of the character after the one asked for, and the shift carries on down the page. On an arXiv title, "Dataset Distillation by Influence Matching", the last letter got the box of the next line's first letter, so the title's box spanned two lines. Task M1.7 found it while building the superscript marks.

A selection lands in the right place across the line, but spans the line's full height. Each line is now checked first: when the glyph boxes for its first and last characters, at the shift carried from the lines before, sit inside the line's selection, the line keeps its glyph boxes at that shift. A ligature moves the line's last box off the line, and only then does each character take the glyph box that sits where its own selection does, searching wider after a jump. Lines got their true height, and blocks group into whole paragraphs: the ten arXiv samples went from 43.6 blocks per page to 27.3.

The marks for raised and lowered characters read each character's font size and baseline from PDFKit's attributed string of the page. Together with the boxes, the new work costs a plain text page about 22 ms: on the 456-page file, a page went from 16 ms to 38 ms, and a full read that a command waits on from 6.5 s to 19.8 s with two workers. One selection per character, tried first, cost 51 ms a page.

| Option | For | Against |
|---|---|---|
| **Glyph boxes, checked line by line against selections** | True heights and true places. | One more PDFKit call per line, and per character on lines with a ligature. |
| `characterBounds` alone | One call. | Wrong boxes after every ligature. |
| Selections alone | Right places. | Every character takes the line's height. |
| Glyph positions read from the content stream | Exact. | A text engine of our own, which the PDFKit decision keeps out. |

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

Task M1.3 checked what a PDFKit save writes: it sets the producer to "macOS Version … Quartz PDFContext", keeps the creator, such as "arXiv GenPDF" or "Microsoft Word", and sets both dates to the time of the save. A file that macOS made in the first place, as the print dialog's "Save as PDF" makes one, carries the same producer, and nothing in the file tells the two apart. So the warning says "made or last saved by macOS PDFKit", and it also shows on files that no save damaged.

| Option | For | Against |
|---|---|---|
| **A new file, with a warning** | Nothing wrong is ever served, and the agent learns why the text may be poor. | The file is parsed again, and its damaged text is what the agent reads. |
| The earlier copy's pages, reused while the character positions line up | The agent keeps the good text. | A real edit that keeps the positions would be served stale, and wrong is way worse than missing. |
| The earlier copy's reading offered beside the new one, to pick with `pdf pick` | Nothing lost and nothing silently wrong. | Needs a history of each file's earlier copies. |

## Decision: two OCR readings compared, over OCR's own confidence — 2026-10-15

Every page that OCR reads is read a second time, and the share of the first reading's words that the second also finds is the page's OCR score. Under 0.85, the page, or a block with at least 20 words of four letters or more, is `low-quality`. When the second reading fails, the page is judged on the first alone. On macOS 26 the second reading comes from the older text recognizer. Before macOS 26 that recognizer is the only one, so it reads the image again at 70% of its size. Words of four letters or more are compared, and in Chinese, Japanese and Korean text, pairs of neighbouring characters.

Task M1.3 made 33 scans from three pages, two arXiv papers and the 1951 NACA report, at 40–200 dpi, some blurred or noisy, and compared each signal with the share of OCR's words that were right:

| Signal | Pages with at least 90% right | Pages under 80% right | Verdict |
|---|---|---|---|
| **Two engines' word agreement (macOS 26)** | 0.89–1.00 | 0.83 or less | Separates them |
| **The older recognizer against itself at 70% size** | 0.89–1.00 | 0.83 or less | Separates them |
| The older recognizer's confidence | 0.97–1.00 | up to 0.99 | Overlaps: 0.94 at 47% right |
| The document recognizer's confidence | 0.51–0.62 | 0.18–0.73 | Overlaps: 0.52 at 15% right |
| Share of words in macOS's word list | 0.74–0.94 | up to 0.82 | Overlaps, and favours English |
| The older recognizer, accurate against fast | 0.14–0.97 | 0.00–0.01 | The fast mode fails good pages |

Pages between 80% and 90% right fell on either side. On the real samples, the two synthetic scans scored 0.98–1.00, and two NACA pages 0.91. The NACA cover scored 0.78: its small print had come back as "Corernment Printing Ofice.-Wathingion", and the check flagged it. Its blocks are too short to judge one by one, so the whole page went out as a failure block. The second reading costs about 0.8 s per page: a scan's first page came back in 1.74 s, against 0.90 s without it. Scans are outside goals G2 and G3.

The quality is judged when a page is read, from the measures the parse stored, so a threshold tuned later applies to every cached page without parsing it again.

| Option | For | Against |
|---|---|---|
| **A second reading compared with the first** | Tracks accuracy on every macOS version. Any script compares, Chinese, Japanese and Korean by pairs of characters, though only English pages were measured. | About 0.8 s more per page read by OCR. |
| OCR's own confidence | Free. | Does not track accuracy, as the table shows. |
| The share of dictionary words | Cheap. | Overlaps, and flags every page that is not in English. |

## Decision: second readings from OCR's breaks and common words, shown as unsure blocks — 2026-10-15

Where the space repair leaves a word in doubt, the output shows the text layer's reading and a second one, and the agent picks with `pdf pick`. The second reading never changes a letter, only where words break, so the agent judges by language alone. It comes from three sources, each tried on the samples:

- **OCR's breaks just after a misread.** The repair skips a break at the start of a run where PDFKit and OCR agree, because the alignment there may be a character off. On the paper that loses its spaces, 53 such words were offered, and most were wrong, as "T able" and "syste m". A break now counts only where macOS's word list backs it: the letters on each side form words and the letters across it do not, as in "overall shift", or it separates a maths letter from a word, as in "𝑁 test". The 20 words left were all right.
- **The same letters elsewhere in OCR's text.** PDFKit and OCR can put a line in different places in the page's order, and the alignment then leaves it unmatched. A word that is still run together, with more than 25 letters in a row, takes OCR's breaks where its letters occur exactly once in OCR's text. It fixed "nineALW/WOAHeditionsviatheACLAnthology" on the Word-made paper.
- **Common English words.** Where OCR runs the letters together too, they are split into the fewest common words, from the word embedding macOS ships (about 57,000 words, loaded in 73 ms), as "single dataset per condition and should be treated". The full word list holds rare words, such as "sare" and "ora", which split "datasetsare" wrongly. A word that common words cover by at least 60% but that splits no clean way, such as one cut at a line end, gets an unsure block with its one reading and a crop to look at. A German compound, which common English words do not cover, stays as it is.

Names from code and web addresses, such as "SpaceRepairRelocateRunTogetherWords" or a long URL path, run together in both readers because they are written that way. A word with "://", an underscore, two slashes, a dot between small letters, or three capitals after small letters gets no second reading.

On the eleven samples, nine papers got no unsure block, and the two that lose spaces got 28 second readings and one word to look at, over 12 pages. All 28 readings were right when checked by eye. A pick lives apart from the cache and applies only while the page offers the same readings, so a page parsed differently never takes a pick made for other words.

| Option | For | Against |
|---|---|---|
| **A second reading where a word list backs it, picked by the agent** | Fixes what the repair leaves, without a guess in the text. | English only, and an unsure block costs about 60 tokens. |
| Every OCR break applied | No agent step. | Wrong breaks in plain words, such as "T able". |
| Words left run together, unflagged | No noise. | Search misses the merged words, silently. |

## Decision: one Homebrew binary over a Python package — 2026-10-14

The tool installs with one Homebrew command. Models that the base install leaves out download in a separate setup step. A Python package would bring PyTorch, an install measured in gigabytes.

## Decision: no LLM inside the tool — 2026-10-14

The tool returns text, crops and failure reports, and the calling agent does all the reasoning. The reason lives in [PROPOSAL.md → What we don't want](PROPOSAL.md#what-we-dont-want).

## Open questions

- How to measure reading-order doubt on layouts beyond LaTeX papers, such as Word reports, magazines and textbooks with sidebars. The M0 spike's count of jumps between the left and right halves of a page is a candidate, tested only on two-column LaTeX papers.
- The embedding model for search by meaning: Apple's built-in embeddings, or a small MLX model.
- The quality thresholds that make a page `low-quality`. They get tuned until goal G11 in [GOALS.md](GOALS.md) passes. The OCR agreement's 0.85 rests on 33 scans made from three pages.
- How to find the lines in doubt on a scan whose blocks are too short to judge alone, so the failure block covers less than the whole page.
- How to check, page by page, a scan's old OCR text layer that passed the sample check. The NACA report's third page reads "TECH LM3ARY" from its old layer, unflagged.
- How to serve the first page of a very long file within goal G2. The runner reads every page's key and font check before it parses any page, at about 2.4 ms per page, so a file of more than about 700 pages likely misses G2's 2 s. A 456-page file gave its first page in 1.52 s.
