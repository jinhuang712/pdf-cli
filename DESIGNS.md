<!-- what-we-build: drafted 2026-10-29 -->
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
                         ──► its text stays behind `--show raw`

OFF BY DEFAULT: added only when a goal fails without them
   · Layout model on Core ML: labels footnotes and headings in one pass

(*) See the decision on fonts that hide spaces.
```

The "at risk" check comes from the M0 spike: a font that declares character 32 twice as wide as a normal space makes PDFKit drop the spaces between words.

## Principles

### Parsing

- **Apple's engines first.** PDFKit and Vision do the work by default, and a downloaded model joins only where the Base setup measurably falls short of a goal. Cost: some pages read worse than a model would read them, until a measurement shows the gap. Holds as: every model that `pdf setup` downloads is listed in this document with the goal it improves and its measured gain over Base.
- **The file's own structure first.** Tags, bookmarks, page labels and the text layer win over inference, and models fill only the gaps. Cost: a badly tagged PDF misleads the parser until a quality check catches it. Holds as: every block records its source (`file`, `layout` or `ocr`), and a model-made block appears only where the file states nothing.
- **Escalate per page.** Each page goes through the text layer, the layout model when it is installed, and OCR, in that order, and stops at the first step that reads it well; what none reads well goes to the agent as a crop. Cost: one document mixes methods, so quality varies from page to page. Holds as: every page record names the step that produced it.

### Failure

- **A failed page always holds a failure block.** A page that fails to parse, or reads below the quality bar, gets a failure block in its place: the page, the reason and the quality score. Cost: output on hard documents gets noisy, and agents must handle failure blocks. Holds as: every page read gets a status (`ok`, `unsure`, `low-quality` or `failed`) with its reasons, and the output writer turns every failed or low-quality page or block into a failure block.
- **Every failure names its way out.** The way out is the agent's own image understanding: each failure block carries the ready-to-run `pdf crop` command for the smallest region that holds the doubt, with the lines around it. Each block that replaced doubtful text also names `--show raw`, which shows that text, labelled with its reason. A failed page has no text to show. Cost: the agent pays image tokens for each crop it reads, and a region found too small hides context. Holds as: the output writer emits no failure block without a crop command, no low-quality block without a `--show raw` line, and the crop covers the block's own region, or its page when the whole page is in doubt.
- **The agent judges what language can show.** When two readings of a passage differ in words, such as spacing or a sentence spliced across columns, the block shows both readings, and the agent picks one with `pdf pick`. Readings that differ in digits, table cells or formulas go out as a crop, with both readings behind `--show raw`. Cost: extra tokens for the words that differ, and a wrong pick lasts until `reparse`. Holds as: `pdf pick` accepts only one of the tool's own readings, picks live in their own table apart from the parsed pages, and every picked span carries a `[picked]` label in the output.
- **Failure is reported three times.** It appears in place, in the summary line at the top of the output, and in the exit code, so an agent that reads only one of them still sees it. Cost: the same failure shows up in three places. Holds as: the exit code for partial failure differs from the codes for success and total failure, and the summary counts every page that is not `ok`.
- **Doubt counts as failure.** A garbled text layer, an uncertain reading order or OCR readings that disagree give the page, or the block, the status `low-quality`, reported like a failure. Cost: more warnings on hard documents. Holds as: each quality check has a threshold, and a page or block below any threshold gets the status `low-quality`.

### Silent errors

A page can read wrong while it looks right, and the agent believes what it is handed. Each trap found so far gets its own check.

- **Table regions replace their text.** PDFKit turns a table into a stream of numbers without rows or columns, as the M0 spike showed. The text inside a detected table stays out of normal output, and the table goes out as an image (see the decision on tables below). `--show raw` shows the text in place, labelled as flat text that lost its rows and columns. The words inside a figure, such as a chart's axis labels, follow the same rule. Cost: a table the detector misses still leaks its flat numbers. Holds as: the output writer moves every text block inside a table or figure region behind `--show raw` and emits one table or figure block in its place, and goal G8 in [GOALS.md](plan/GOALS.md) scores table detection.
- **Raised and lowered characters keep a mark.** Plain text turns 10⁻⁵ into "10−5", as the M0 spike showed. PDFKit reports each run of text with its font size and how far its baseline is raised. A character set smaller than its line's main text, and raised or lowered against it, is a superscript or a subscript, as in `10^{-5}`, `LLM_{tea}` and `Haoru Tan^{1,†}`. Main-size text that PDFKit reports a little raised, as in some table cells, keeps no mark. Cost: a font that reports odd sizes gets wrong marks. Holds as: every character set smaller and off the line's baseline leaves the text layer with a superscript or subscript mark, or as a footnote or citation marker.
- **One sample page per file is checked against its image.** A broken font table can map shapes to wrong letters, and an old OCR layer in a scan can hold misreads. Both look like real words. Apple OCR reads a band around the densest paragraph of the first page among the first ten with at least 300 letters, and the check counts the share of OCR's words, four letters or longer, that the text layer spells the same, with spaces left out so a layer that lost its spaces still matches. A share under 0.7 fails. On the eleven samples it was 0.90–0.99, the scan's old OCR layer 0.94 included, and a layer with every letter shifted by one scored 0.00. Cost: 0.35–0.6 s per new file, in a worker of its own beside the index. Holds as: a file whose sample fails has every page read by OCR and cached apart, and its old text layer stays behind `--show raw`, labelled `[PDF text layer]` (it was `[old OCR]` until M2.20, which could not tell a scan's old OCR layer from a born-digital page's own text without a parser change).
- **Spaces are checked before and after reading.** A font that declares character 32 wider than a normal space makes PDFKit drop the spaces between words, as the M0 spike found. A Word-made spike paper also loses 1–2 spaces per page, for a reason still unknown. Before reading, the font check measures each word gap in a page's text operations against half its font's declared width for character 32, counting only body fonts, the fonts that hold at least a quarter of the page's gaps: a maths font can declare a wide character 32 harmlessly. A file with at least 5% risky gaps, and at least 20, is "at risk", and so is a page with at least 10%, and at least 10, for a file that mixes papers. On the eleven samples, the paper that loses its spaces had 29%, and the ten others had none on any page. After reading, a count of run-together words, letter runs longer than 25, checks every page, and a page with any gets the space repair too: the Word-made paper had 1–2 on four pages. A word still in doubt after the repair gets a second reading (see the decision on second readings). Cost: about 0.3 ms per page for the check, and 0.7 s of OCR for each page with run-together words. Holds as: every page record stores its run-together word count, and every page with run-together words goes through the space repair.

### Cache

- **Pay once, read many times.** Results are keyed by page content and parser version, and failed pages are cached with their reasons too. Cost: disk space, and a cache that must stay correct. Holds as: no command parses a page whose key is already in the cache, except `reparse`.
- **Annotations leave the cache alone.** The key hashes what each page draws, its boxes, content streams and resources, not the file's bytes, so a highlight appended to the file leaves every page key unchanged. Comments, highlights and form values are cached apart, by the file's bytes, so a new highlight re-reads only the annotations. Cost: hashing every page takes time when a file is added, about 1.3 ms per page on a 456-page file. Holds as: a test appends a highlight the way Acrobat saves one, and every page key stays the same. A file that PDFKit saved is the exception (see the decision on PDFKit saves).
- **Same file, same answer.** Models are pinned and decoding never samples. Cost: the project gives up the extra accuracy that sampling sometimes buys. Holds as: two parses of the same file with the same version produce byte-identical output.

### Output

- **Every claim has an address.** Every block carries its page and its number on the page, and its position in `--json` (see the decision on paragraph numbers). Cost: a few tokens per block. Holds as: every block type in the output schema has `page` and `bbox`.
- **Nothing goes missing without a trace.** Every part of a page reaches normal output as text or as a marker in its place, as the stance in [PHILOSOPHY.md](PHILOSOPHY.md) says: images outside any figure, comments, highlights, form values, link targets, and everything set aside as hidden or doubtful. A marker names what sits there, why it was set aside and the command that shows it. Cost: a few tokens per marker, and each kind of page object needs its own handling. Holds as: on every page of the test sets, each text run, image, annotation and form field that PDFKit reports appears in the output as text or a marker, which goal G17 in [plan/GOALS.md](plan/GOALS.md) counts.
- **Text first, pixels on request.** Images come only when the agent asks for them. Cost: the agent can miss a visual cue it did not ask about. Holds as: only `crop`, `dump --figures`, `dump --tables` and `dump --embedded-images` write image files.

### Performance

- **First answer over full parse.** The requested page is parsed first, and the rest of the document follows in the background, at low priority. Cost: a page parsed alone lacks the whole document's context, such as heading levels and footnote numbering. Holds as: output from a partly parsed document is marked provisional, and the mark clears once the full parse ends.
- **Parallel by process.** Parsing runs in separate worker processes, and every parse on the Mac shares one pool of worker slots (see the decision on the pool below). Cost: each worker holds its own memory and loaded models. Holds as: no PDF engine call runs on two threads of one process, and no more workers run at once than the pool holds.

### Safety

- **Untrusted files stay in a child process.** Each parse runs in a worker with a time limit and a memory limit. Cost: a process starts for each job. Holds as: only workers open PDF content, the CLI process reads only the cache, and a worker that hits a limit yields a `failed` page instead of a crash. A content stream is counted by its operators before anything copies it (plan/decisions/052-a-content-stream-is-counted-by-its-operators-before-anything.md → Decision: a content stream is counted by its operators before anything copies it).
- **Invisible text leaves a marker, not its words.** Text that a reader cannot see is flagged, and a marker takes its place in normal output: text drawn in the color behind it, tiny, clipped, covered by an image, off the page or in a layer switched off. The marker gives the hidden text's size, how it was hidden and the command that shows it, so nothing goes missing without a trace. Cost: visibility depends on what is drawn behind the text, so every text block needs a look at the layers below it, and an OCR text layer is invisible by design, so it needs its own rule. Holds as: invisible text over a scanned image counts as a text layer, white text on a dark box counts as visible, and every other invisible block reaches normal output as a marker, with its words only behind an explicit flag.
- **Parsing stays offline.** Models download only during setup. Cost: a missing model needs a setup step before first use. Holds as: a test parses the open test set under a network monitor and sees zero connections.
- **PDF actions never run.** JavaScript, launch actions and embedded files stay inert. `pdf info` lists them, so the agent knows they exist, and `pdf dump` saves attachments and prints scripts as text. Cost: none for reading. Holds as: workers call no engine API that runs a document action, and `dump` writes attachments and scripts without opening or running them.

### Testing

- **Real PDFs are the test.** Every change and every macOS release reruns a test set of real documents with expected output. Cost: building and labelling the set takes real work. Holds as: CI runs the open set on every pull request. The open set holds only open-access PDFs, such as arXiv papers under CC-BY, and a private set of the user's own PDFs stays local.
- **Scoring weighs wrong over missing.** A wrong block costs a test more than a missing one, as the philosophy says. Cost: a parser that returns less can outscore one that returns more. Holds as: the scorer applies a heavier weight to wrong blocks, and the weight lives in [plan/GOALS.md](plan/GOALS.md).

## Decisions

Each decision is a file in [plan/decisions/](plan/decisions), with the options it beat. The newest is last.

| No. | Decision | Decided |
|---|---|---|
| 001 | [Swift over Rust, Go and Python](plan/decisions/001-swift-over-rust-go-and-python.md) | 2026-10-14 |
| 002 | [macOS only](plan/decisions/002-macos-only.md) | 2026-10-14 |
| 003 | [macOS 11 as the oldest supported version](plan/decisions/003-macos-11-as-the-oldest-supported-version.md) | 2026-10-15 |
| 004 | [Apple PDFKit over PDFium and a parser of our own](plan/decisions/004-apple-pdfkit-over-pdfium-and-a-parser-of-our-own.md) | 2026-10-14 |
| 005 | [Apple OCR word breaks over PDFium for fonts that hide spaces](plan/decisions/005-apple-ocr-word-breaks-over-pdfium-for-fonts-that-hide-spaces.md) | 2026-10-14 |
| 006 | [line-end hyphens resolved by the page and macOS's word list](plan/decisions/006-line-end-hyphens-resolved-by-the-page-and-macos-s-word-list.md) | 2026-10-15 |
| 007 | [Apple Vision over Tesseract and RapidOCR](plan/decisions/007-apple-vision-over-tesseract-and-rapidocr.md) | 2026-10-14 |
| 008 | [Core ML on the Neural Engine over a Python Docling worker](plan/decisions/008-core-ml-on-the-neural-engine-over-a-python-docling-worker.md) | 2026-10-14 |
| 009 | [Rules on PDFKit's fonts and positions over a default layout model](plan/decisions/009-rules-on-pdfkit-s-fonts-and-positions-over-a-default-layout.md) | 2026-10-14 |
| 010 | [columns from PDFKit's lines, moved only where both sides hold running text](plan/decisions/010-columns-from-pdfkit-s-lines-moved-only-where-both-sides-hold.md) | 2026-10-17 |
| 011 | [Tables as images over rebuilt cells](plan/decisions/011-tables-as-images-over-rebuilt-cells.md) | 2026-10-14 |
| 012 | [figures, tables and equations from captions, pictures and rules](plan/decisions/012-figures-tables-and-equations-from-captions-pictures-and-rules.md) | 2026-10-17 |
| 013 | [equations as blocks now, LaTeX rebuilt from the page next](plan/decisions/013-equations-as-blocks-now-latex-rebuilt-from-the-page-next.md) | 2026-10-17 |
| 014 | [the agent reads figures, tables and equations from their crops, and its LaTeX is kept](plan/decisions/014-the-agent-reads-figures-tables-and-equations-from-their-crops.md) | 2026-10-18 |
| 015 | [`pdf transcribe` takes the LaTeX on standard input and keeps it beside the picks](plan/decisions/015-pdf-transcribe-takes-the-latex-on-standard-input-and-keeps-it.md) | 2026-10-18 |
| 016 | [no local vision model; PDFKit and Apple's OCR read, the agent looks](plan/decisions/016-no-local-vision-model-pdfkit-and-apple-s-ocr-read-the-agent.md) | 2026-10-18 |
| 017 | [notes by size, marker and position; their words after the text, and a series names them](plan/decisions/017-notes-by-size-marker-and-position-their-words-after-the-text-and.md) | 2026-10-18 |
| 018 | [citations judged at read time by rules; cross-references as links to a page](plan/decisions/018-citations-judged-at-read-time-by-rules-cross-references-as-links.md) | 2026-10-19 |
| 019 | [alt text as hidden text, shown only with `--include-hidden`](plan/decisions/019-alt-text-as-hidden-text-shown-only-with-include-hidden.md) | 2026-10-17 |
| 020 | [SQLite over qmd and Tantivy](plan/decisions/020-sqlite-over-qmd-and-tantivy.md) | 2026-10-14 |
| 021 | [macOS's Library folders, with no size limit](plan/decisions/021-macos-s-library-folders-with-no-size-limit.md) | 2026-10-15 |
| 022 | [the library lists files by path, with their document's ID](plan/decisions/022-the-library-lists-files-by-path-with-their-document-s-id.md) | 2026-10-15 |
| 023 | [a password reaches the workers in their environment](plan/decisions/023-a-password-reaches-the-workers-in-their-environment.md) | 2026-10-15 |
| 024 | [a file's facts kept with its entry, apart from its pages](plan/decisions/024-a-file-s-facts-kept-with-its-entry-apart-from-its-pages.md) | 2026-10-15 |
| 025 | [sections from bookmarks, else from headings in the text](plan/decisions/025-sections-from-bookmarks-else-from-headings-in-the-text.md) | 2026-10-15 |
| 026 | [macOS updates leave the cache alone](plan/decisions/026-macos-updates-leave-the-cache-alone.md) | 2026-10-15 |
| 027 | [a worker process per job over a background service](plan/decisions/027-a-worker-process-per-job-over-a-background-service.md) | 2026-10-15 |
| 028 | [a shared pool of worker slots, with pages nobody waits for in the background](plan/decisions/028-a-shared-pool-of-worker-slots-with-pages-nobody-waits-for-in-the.md) | 2026-10-15 |
| 029 | [paragraph numbers in text, positions in JSON](plan/decisions/029-paragraph-numbers-in-text-positions-in-json.md) | 2026-10-15 |
| 030 | [a 5,000-token default budget over no default](plan/decisions/030-a-5-000-token-default-budget-over-no-default.md) | 2026-10-15 |
| 031 | [a keyword index of every paragraph, kept with the page's result](plan/decisions/031-a-keyword-index-of-every-paragraph-kept-with-the-page-s-result.md) | 2026-10-15 |
| 032 | [crops sized to Claude's standard image limits](plan/decisions/032-crops-sized-to-claude-s-standard-image-limits.md) | 2026-10-15 |
| 033 | [each character's glyph box matched to its selection](plan/decisions/033-each-character-s-glyph-box-matched-to-its-selection.md) | 2026-10-15 |
| 034 | [a marker in place of hidden text over its words with a label](plan/decisions/034-a-marker-in-place-of-hidden-text-over-its-words-with-a-label.md) | 2026-10-15 |
| 035 | [hidden text found by ink, with the drawing commands for what ink cannot tell](plan/decisions/035-hidden-text-found-by-ink-with-the-drawing-commands-for-what-ink.md) | 2026-10-15 |
| 036 | [what an image over text hides, from the drawing commands, with OCR where they cannot tell](plan/decisions/036-what-an-image-over-text-hides-from-the-drawing-commands-with-ocr.md) | 2026-10-16 |
| 037 | [one guide, printed or installed as a skill](plan/decisions/037-one-guide-printed-or-installed-as-a-skill.md) | 2026-10-16 |
| 038 | [one output contract for every command](plan/decisions/038-one-output-contract-for-every-command.md) | 2026-10-25 |
| 039 | [`read` reads, `note` and `ref` look up, `--show` shows what was set aside, `doctor` cleans](plan/decisions/039-read-reads-note-and-ref-look-up-show-shows-what-was-set-aside.md) | 2026-10-25 |
| 040 | [a loud failure for a file PDFKit cannot open](plan/decisions/040-a-loud-failure-for-a-file-pdfkit-cannot-open.md) | 2026-10-15 |
| 041 | [the user sets parsing's memory, the tool the worker count](plan/decisions/041-the-user-sets-parsing-s-memory-the-tool-the-worker-count.md) | 2026-10-17 |
| 042 | [parsing's memory in `settings.json`, and `doctor --clean`](plan/decisions/042-parsing-s-memory-in-settings-json-and-doctor-clean.md) | 2026-10-25 |
| 043 | [annotations from the file's facts, their words checked against what a reader sees](plan/decisions/043-annotations-from-the-file-s-facts-their-words-checked-against.md) | 2026-10-17 |
| 044 | [annotations per page, in a table of their own](plan/decisions/044-annotations-per-page-in-a-table-of-their-own.md) | 2026-10-25 |
| 045 | [a file that PDFKit saved counts as a new file, with a warning](plan/decisions/045-a-file-that-pdfkit-saved-counts-as-a-new-file-with-a-warning.md) | 2026-10-15 |
| 046 | [two OCR readings compared, over OCR's own confidence](plan/decisions/046-two-ocr-readings-compared-over-ocr-s-own-confidence.md) | 2026-10-15 |
| 047 | [second readings from OCR's breaks and common words, shown as unsure blocks](plan/decisions/047-second-readings-from-ocr-s-breaks-and-common-words-shown-as.md) | 2026-10-15 |
| 048 | [one Homebrew binary over a Python package](plan/decisions/048-one-homebrew-binary-over-a-python-package.md) | 2026-10-14 |
| 049 | [no LLM inside the tool](plan/decisions/049-no-llm-inside-the-tool.md) | 2026-10-14 |
| 050 | [a dry run answers from what is kept and never parses](plan/decisions/050-a-dry-run-answers-from-what-is-kept-and-never-parses.md) | 2026-10-25 |
| 051 | [a reparse keeps the page's key and replaces results in one transaction per chunk](plan/decisions/051-a-reparse-keeps-the-page-s-key-and-replaces-results-in-one.md) | 2026-10-25 |
| 052 | [a content stream is counted by its operators before anything copies it](plan/decisions/052-a-content-stream-is-counted-by-its-operators-before-anything.md) | 2026-10-25 |
| 053 | [OCR hides text PDFKit leaves out when the page draws it and no reader sees it](plan/decisions/053-ocr-hides-text-pdfkit-leaves-out-when-the-page-draws-it-and-no.md) | 2026-10-25 |
| 054 | [search judges running headers on the query](plan/decisions/054-search-judges-running-headers-on-the-query.md) | 2026-10-25 |
| 055 | [search keeps a summary of each page's edge blocks](plan/decisions/055-search-keeps-a-summary-of-each-page-s-edge-blocks.md) | 2026-10-26 |
| 056 | [the space repair reads with the text recognizer](plan/decisions/056-the-space-repair-reads-with-the-text-recognizer.md) | 2026-10-25 |
| 057 | [an OCR line that reads as prose is no "too small to read" text](plan/decisions/057-an-ocr-line-that-reads-as-prose-is-no-too-small-to-read-text.md) | 2026-10-25 |
| 058 | [no search by meaning](plan/decisions/058-no-search-by-meaning.md) | 2026-10-26 |
| 059 | [a table's parts are linked at read time, only on a continued caption and the same place on both pages](plan/decisions/059-a-table-s-parts-are-linked-at-read-time-only-on-a-continued.md) | 2026-10-26 |
| 060 | [one command, one job; clean split from doctor](plan/decisions/060-one-command-one-job-clean-split-from-doctor.md) | 2026-10-26 |
| 061 | [ink that other strings draw does not make a word with no ink of its own visible](plan/decisions/061-ink-that-other-strings-draw-does-not-make-a-word-with-no-ink-of.md) | 2026-10-26 |
| 062 | [macOS 12 as the oldest supported version](plan/decisions/062-macos-12-as-the-oldest-supported-version.md) | 2026-10-29 |

## Open questions

- How to measure reading-order doubt on layouts beyond LaTeX papers, such as Word reports, magazines and textbooks with sidebars. The M0 spike's count of jumps between the left and right halves of a page is a candidate, tested only on two-column LaTeX papers.
- The quality thresholds that make a page `low-quality`. They get tuned until goal G11 in [plan/GOALS.md](plan/GOALS.md) passes. The OCR agreement's 0.85 rests on 33 scans made from three pages.
- How to find the lines in doubt on a scan whose blocks are too short to judge alone, so the failure block covers less than the whole page.
- How to check, page by page, a scan's old OCR text layer that passed the sample check. The NACA report's third page reads "TECH LM3ARY" from its old layer, unflagged.
