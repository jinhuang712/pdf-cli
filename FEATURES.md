<!-- what-we-build: drafted 2026-10-16 -->
# Features

✅ built · 🚧 built with a gap · ⬜ planned

F1 and F11 are ✅ built, F2, F3, F4, F5, F7, F8 and F9 are 🚧 built with a gap, and every other feature is ⬜ planned. The commands and output samples show the intended behavior.

## F1 — Add ✅

Adds PDFs to the library once, so every later command reads from the cache.

| Command | What happens |
|---|---|
| `pdf add <paths…>` | Parses each PDF and caches it. Accepts files, folders and globs. A folder adds every PDF in it and in its subfolders. Prints each PDF's ID, title, page count and status, such as `1f9472ae · Dataset Distillation by Influence Matching · 11 pages · ok · paper.pdf`. |
| `pdf add <paths…> -j N` | Parses with up to N workers in parallel. By default, every parse on the Mac shares a pool of half the performance cores, at least 2, and pages nobody waits for parse at the lowest priority, so the Mac stays responsive. |
| `pdf add <path> --password <pw>` | Opens a password-protected PDF. Other users of the Mac can see the password in the command line while it runs. |
| `pdf add <path> --password-stdin` | Opens a password-protected PDF with the password read from standard input, as in `echo "$PW" \| pdf add paper.pdf --password-stdin`, which keeps it out of the command line. |

Any other command adds a PDF it has not seen before, on first use, and parses the requested page first. Adding an unchanged file again does nothing, and so does adding a file whose only change is highlights appended to it. A file that macOS Preview or another app saved through PDFKit counts as a new file (see F7).

Settings: none.

## F2 — Info 🚧

Gives a cheap first look at a PDF, so the agent can decide what to read.

```sh
$ pdf info paper.pdf
Residual Dropout for Robust Vision Models · Lee, Park, Chen · 2025 · doi:10.xxxx/…
30 pages · 2 columns · text layer on 30 pages · ~19k tokens
headnote: none · footnotes: 12 · references: 48 · flagged pages: p.7 (low-quality)

Section          pages    tokens
  1 Introduction p.1–3    1.8k
  4 Experiments  p.10–19  4.6k
  References     p.23–28  4.1k

Figures and tables
  fig 4  p.15  Accuracy vs. dropout rate (chart)
  tbl 1  p.12  Results on ImageNet
```

`pdf info` shows:

- The title, authors, year and DOI.
- The author notes, such as the corresponding author and equal contribution.
- The page count and layout: columns, two-page spreads and scanned pages.
- The outline, with each section's pages and size in tokens.
- Every figure and table, with its page and caption.
- The counts of headnotes, footnotes and references.
- The counts of comments, highlights and filled-in form fields.
- Every file attached to the PDF and every script in it, with its name and size, or the event that would start the script: the first 100 of each, and a count of the rest. None of them runs.
- The running headers, footers and publisher stamps, each once.
- Every page that is flagged, with its status.

The outline comes from the file's bookmarks, or, in a file with none, from the headings in its text, such as "2.1 Method" or "References". The output says which. `pdf info` answers once the file is indexed and its first page parsed: on a file not seen before, the sizes, the flags and the headings cover the pages parsed so far, and the output says how many those are. A section whose end lies on a page not parsed yet shows its size as `…`. `--json` gives every section, at every level.

When a file's comments, form fields, attachments and scripts cannot be read, as when a hostile file makes the reading run out of time, `pdf info` says they are unknown and why, and the pages read all the same.

Gap:
- The figures and tables come with M2.6, and the running headers, footers and publisher stamps with M2.5.
- The counts of headnotes, footnotes and references, and two-page spreads, come later.
- In a file without bookmarks, a heading set in the top 7.5% of its page, as on a page with a small margin, is taken for a running header and left out of the sections, until running headers are set aside in M2.5.

Settings: none.

## F3 — Read 🚧

Prints text in reading order. Every block shows its page and its number on the page, and `--json` gives its position too.

```text
paper.pdf · 11 pages · read p.1–4 · flagged: none

## p.1

¶1 Dataset Distillation by Influence Matching

¶2 Haoru Tan^{1,†} Wang Wang^{1,†} Sitong Wu^{2} Xiuzhe Wu^{3}
…

next: pdf read paper.pdf --from p4.27
```

| Flag | What it reads |
|---|---|
| `--page 3-5` | Pages by their position in the file, such as `3`, `3-5` or `3,7-9`. The flag can repeat. |
| `--printed-page 237` | A page by the number printed on it, such as "237" or "iv", from the file's page labels |
| `--section "Method"` or `--section 2.1` | A section by its title or its number, as `pdf info` lists them, from its heading to the next section at its level or above. The flag can repeat. |
| `--full` | The whole document, within the budget, as a read without a page flag does |
| `--from p4.27` | Goes on from where a read stopped, as its `next:` line says: a page, a block in it, and a character in the block after a colon, as in `p4.27:200` |
| `--format md\|text\|html` | The output format. The default is `md`. |
| `--styles` | Marks bold, italic and heading levels in the text |
| `--raw` | Shows the text that normal output set aside as doubtful, in place, each part labelled with its reason: `[low-quality]`, `[unsure]`, `[table text: rows and columns lost]`, `[figure text]` or `[old OCR]` |

Without a page or section flag, `pdf read` starts at the first page and stops at the default budget (see F7). A page asked for is parsed first, and a read that the budget stops early waits only for the pages it shows.

Gap:
- `--section` takes one section per read so far. `--styles` and `--format html` come later.
- Tables, figures and equations read as plain text until M2.6, and images and annotations get no marker until M1.13 and M1.14.

Apple OCR reads a scanned page, a page whose text layer is stray marks or broken characters, and every page of a file whose text layer disagrees with its own image. Its blocks carry addresses like any other, and the text layer it replaced shows with `--raw`, labelled `[old OCR]`.

A table appears as a table block in place of its cells: its number, its caption, its notes and the command that crops it. The agent reads the cells from the image, and `--raw` shows the table's flat text.

```text
[table 3] p.6 · Forecasting results on multivariate benchmarks
  read it as an image: pdf crop paper.pdf --table 3
```

A figure appears the same way, as a figure block with its caption, its alt text when the file has one, and the command that crops it. An image or a drawing outside every figure, such as a logo, a signature or a chart without a caption, gets a marker in place:

```text
[image] p.3 · 0.62,0.08,0.30,0.12 · crop: pdf crop paper.pdf --page 3 --bbox 0.62,0.08,0.30,0.12
```

The rest of the page reaches the text too, at its position:

| What | How it shows |
|---|---|
| Comments and sticky notes | `[comment · Reviewer 2] Please cite the 2019 baseline.`, with the author when the file names one |
| Highlights | `[highlight] the highlighted words`, with the comment attached to it, if any |
| Filled-in form fields | `[field: Name = …]` |
| Links | `[here](https://…)` in Markdown, and `here <https://…>` in plain text |

Settings: none.

## F4 — Search 🚧

Finds the right page, in one PDF or across the whole library.

| Command | What happens |
|---|---|
| `pdf search <path> <query>` | Searches by keyword and by meaning. Each result shows the page, the position, the section and a short snippet. |
| `pdf search <query>` | Searches every PDF in the library. |
| `pdf search <path> --regex <pattern>` | Finds exact matches, including matches that cross a line or column break. |
| `--in body\|notes\|refs\|memos\|all` | Limits the search to one part of the document. The default is `all`. |
| `--top N` | Shows at most N results. By default, search lists every hit in rank order, until the output budget stops it with a line such as `next: pdf search "dropout" --from 61`. |
| `--from N` | Starts the list at result N. |

A query in another language finds matches by meaning, for example a Chinese query on an English paper.

A hit inside a table names the table and the command that crops it. A hit inside hidden text shows as a marker, without the hidden words. While a PDF is still parsing, every result says how many of its pages were searched, so an empty result reads as partial.

```sh
$ pdf search paper.pdf influence matching
"influence matching" in paper.pdf · 16 hits · all 11 pages searched

p.3 ¶19 · Method · …our proposed dataset distillation framework, **Influence** **Matching** (Inf-**Match**). We…
p.2 ¶28 · Introduction · …can we directly distill data by **matching** its outcome **influence** on the final model…

read a hit: pdf read paper.pdf --from p3.19
next: pdf search paper.pdf 'influence matching' --from 11
```

A keyword finds its other forms, as "dropouts" finds "dropout", and ignores accents. Every word must be in the same paragraph; when no paragraph holds them all, the result lists paragraphs that hold some of them, and says so. A search of one PDF that is not fully parsed waits up to 10 s for its pages. A search of the library searches the pages parsed so far, starts no parse, and searches copies of one file once. `--json` gives each hit with its file, page, paragraph, section and snippet, within the same budget. A hit on a flagged page names the page's status. A pattern stops counting at 10,000 matches in a PDF, and one that runs longer than 10 s stops with an error that says so.

Gap:
- Search by meaning, and so queries in another language, come with M3.1.
- `--in` comes with notes, references and memos in M2.7, M2.8 and M3.4; search covers all the text until then.
- Hits name tables with M2.6 and hidden text with M1.10.

Settings: none.

## F5 — Crop 🚧

Turns one part of a page into an image, so the agent can look at it with its own image understanding.

| Flag | What it crops |
|---|---|
| `--figure 4` or `--figure 4b` | A figure or a sub-figure, with its caption |
| `--table 1` | A table, with its notes |
| `--equation 5` | A numbered equation |
| `--page 7` | A whole page |
| `--page 7 --bbox 0.1,0.4,0.8,0.3` | A region, given as x, y, width and height in fractions of the page |
| `--grid` | Draws a labelled grid over the page, to help the agent pick a region |

```sh
$ pdf crop paper.pdf --figure 4
~/Library/Caches/pdf-cli/3f9a…/fig4.png  (~1.2k image tokens)
caption: Accuracy vs. dropout rate · mentioned on p.15, p.20
```

The image is in color, and it is sized so small text in a chart stays readable. `pdf crop` prints the absolute path of the image file. The file stays for 7 days, and the same command makes it again after that.

```sh
$ pdf crop paper.pdf --page 2 --bbox 0.08,0.07,0.85,0.3
/Users/me/Library/Caches/pdf-cli/crops/b430b72936d6cf8b/p2-0.08,0.07,0.85,0.30.png  (~1.5k image tokens, 1568×716 px)
```

A region uses the same fractions as the positions in `pdf read --json` and the crop commands in failure blocks, taken on the page as stored, before any rotation; the image comes out upright. A region is rounded outward to hundredths of the page, so it always holds all of what was asked for. An image fits Claude's standard limits, 1,568 px on its long edge and about 1,568 image tokens, so a whole page costs about 1,500 tokens and a small region comes out enlarged, up to 6 times. It shows comments and highlights as a reader sees them. The same crop asked again within 7 days comes from the cache folder at once, and `pdf gc` removes older ones. `--password-stdin` opens a locked PDF, and `--json` gives the image's path, size and tokens.

Gap:
- `--figure`, `--table` and `--equation` come with figure, table and equation detection in M2.6.

Settings: none.

## F6 — Dump ⬜

Writes a PDF's content to files and prints their paths.

| Flag | What it writes |
|---|---|
| `--markdown`, `--text`, `--html` | The document, or the pages given with `--page` |
| `--figures` | Every figure as a PNG, vector charts included |
| `--embedded-images` | The image objects stored in the file, such as photos and scans |
| `--tables` | Every table as a PNG, with its caption and notes |
| `--notes` | Footnotes, endnotes and other notes, as JSON |
| `--refs` | The reference list, as JSON |
| `--attachments` | The files attached to the PDF, saved without being opened |
| `--scripts` | The PDF's scripts, as text files that never run |
| `-o <folder>` | The output folder. The default is a folder named after the PDF, in the current folder. |

Settings: none.

## F7 — Output basics 🚧

Every command follows the same rules, so an agent learns them once.

- Every block shows its page and its number on the page: a heading such as `## p.12` starts each page, and `¶3` starts its third block. `--json` gives each block's position on the page too, such as `0.10,0.40,0.80,0.30`, and every doubt comes with the command that crops it. The page is its position in the file. When the number printed on the page differs, the page's heading says so, as in `## p.12 (printed 237)`.
- Superscripts and subscripts keep a mark, as in `10^{-5}` and `x_{2}`. Footnote markers and citation numbers have their own marks (see F14 and F15).
- A word that a hyphen splits across two lines comes back whole when the page or macOS's word list knows it. Otherwise the hyphen stays, as in `self-attention`.
- Every command accepts `--json`.
- Output starts with a one-line summary: the pages read, the pages flagged and what normal output set aside.
- A file that macOS Preview or another app saved through PDFKit carries a warning in its summary line: such a save can damage the text, and an earlier copy may read better.
- Nothing is dropped without a trace. What normal output sets aside leaves a marker in place, or a count in the summary line, with the flag that shows it: `--raw` for doubtful text, `--include-hidden` for hidden text and `--headers` for running headers, footers and publisher stamps.
- `--budget N` stops the output at about N tokens, between blocks, and ends it with a line that continues the read, such as `next: pdf read paper.pdf --from p4.27`. A text block larger than the whole budget is cut inside, and the next read goes on from the cut. A failure block, or text shown with `--raw`, larger than the budget goes out whole, so every read moves on. `read` and `search` stop at 5,000 tokens by default, about 5 pages of a paper, and `--budget all` turns the limit off.
- While a document is still parsing, the summary line says `provisional`, with how many pages are parsed so far, because headings and note numbers can change once the whole document is known.

Gap: only `pdf read`, `pdf info`, `pdf search` and `pdf crop` accept `--json` so far, and `--headers` comes with M2.5.

Settings: none.

## F8 — Failure reports 🚧

Makes every failure loud, and tells the agent how to read the page instead.

When a page fails to parse, or reads below the quality bar, its text is replaced by a failure block:

```text
⚠ p.1 low-quality: two OCR readings of the page disagree (score 0.78)
  read it as an image: pdf crop scan.pdf --page 1
  raw: pdf read scan.pdf --page 1 --raw
```

A page reads below the quality bar when:

| Reason | Score |
|---|---|
| A scan's two OCR readings disagree, on the whole page or in one block | The share of words the readings share |
| The text layer looks garbled or disagrees with the page image, and OCR could not read the page | The share of the layer's characters that are letters or digits |
| The fonts hide the spaces between words, and OCR could not read the page to restore them | None |

When only one block is in doubt, only that block is replaced, and the rest of the page reads normally. The crop command covers the smallest region that holds the doubt, with the lines around it: a few lines, a paragraph, a table or the whole page. A small crop costs the agent fewer image tokens and stays sharp.

When two readings of a word differ in where its words break, the paragraph keeps the text layer's reading, and an unsure block after it shows both, limited to the words that differ:

```text
⚠ p.2 ¶5 unsure: two readings differ
  [a] CTRLperforms … overallshift
  [b] CTRL performs … overall shift
  pick: pdf pick paper.pdf p2.5 a  (or b)
  look: pdf crop paper.pdf --page 2 --bbox 0.11,0.40,0.39,0.06
```

Reading [a] is the text layer's. Reading [b] breaks the words where Apple OCR does, or splits letters that both readers run together into common English words, as in "single dataset per condition". English words run together that no reading splits, as when a line-end break cut one, get an unsure block with their one reading and a `look:` crop. Names from code and web addresses, such as `SpaceRepairRelocate`, stay as they are.

`pdf pick paper.pdf p2.5 b` saves the agent's choice for page 2, paragraph 5. Later reads show the chosen words in place, labelled `[picked 2026-10-15]`, and `pdf reparse` clears every pick on the page. A pick takes only one of the readings shown, for every unsure word of its paragraph. When two readings differ in digits, table cells or formulas, the passage comes as a failure block with a crop, because the text alone cannot show which reading is right. `--raw` shows both readings.

- The summary line at the top counts every flagged page, with its status: `failed`, `low-quality` or `unsure`. It also counts what normal output set aside, such as doubtful blocks and a scan's replaced text layer, with the flag that shows them.
- A low-quality page is flagged the same way as a failed one, with its reason and its score.
- A file that PDFKit cannot open fails as a whole, in one line that names the reason: not a PDF, damaged, or locked by a password. A locked file points to `pdf add <path> --password <pw>`.
- The exit code tells success from failure:

| Exit code | Meaning |
|---|---|
| 0 | Every requested page read well. |
| 1 | The command could not run, such as on a file that does not exist. |
| 2 | Some pages failed, are low-quality or hold unsure words. The rest of the output is valid. |
| 3 | No requested page holds text to show: each one failed or is in doubt as a whole. |
| 64 | The command was used wrongly, such as with an unknown flag. |

Gap:
- The blocks reach the agent once `pdf read` is built (M1.7). Until then, the hidden `pdf debug-read` shows them. Their crop commands work once `pdf crop` is built (M1.9), and `pdf reparse` comes later (F10).
- An uncertain reading order is not checked yet (M2.5).
- The word lists that back second readings are English, so words in other languages get none.

Settings: none.

## F9 — Hidden text 🚧

Marks where a reader's eye would miss text, and keeps that text's words out of the agent's way until it asks.

Text that renders invisible, such as text in the color behind it, tiny text, clipped text, text covered by an image, a shape or an annotation, text off the page or text in a layer switched off, is replaced by a marker in normal output. The marker sits where the text sat, and gives its size, how it was hidden and the command that shows it:

```text
¶3 Visible start of a line, [hidden: 3 words, in the color behind it · show: pdf read paper.pdf --page 1 --include-hidden] visible end.
```

White text on a dark box stays in, because a reader can see it. The summary line says how many hidden places the output marks, and on which pages. `--include-hidden` shows their words in place, each labelled with its reason, as in `[hidden, in the color behind it: …]`. The text layer on a scanned page is read normally. A hidden run is words, so a run of fewer than 3 letters or digits stays in. Hidden words stay out of `pdf search`, by keyword and by pattern, and out of the title and sections `pdf info` finds.

Very faint text, under a contrast of 1.3 to 1 with what lies behind it, as #EEEEEE on white, counts as hidden; pale grey such as #D9D9D9 reads as text. A page where the check stopped at a limit says so in place.

Gap:
- A word set at an angle, as a chart's slanted label, is checked for its size, but not for ink, since PDFKit's boxes for it miss its ink.
- On a page whose images cover most of it, as a scan's or a slide's background, text in the invisible mode, or drawn with no opacity, reads as text, as a scan's own text layer does; so does text drawn under opaque images that together cover most of the page, as a scan's text layer under its image. Text drawn to show there gets every check.
- Text over a photo always counts as seen: the photo's own ink cannot tell whether the text shows. So does white text with shapes drawn inside its box other than rules across it, as bars between its letters, and text in the invisible mode, or white, laid over other text that shows: the other text's ink stands for its own.
- Text under a shape drawn after it counts as hidden when the shape leaves no ink there, or is an opaque rectangle or an axial shading over it; under other shapes, as stripes, a pattern or a stamp annotation's picture, with ink of their own, it counts as seen.
- Text in a script OCR does not read, as Greek or Hebrew, under an image that lets part of it through by a blend mode, a stencil or a color key, counts as seen. A word OCR misreads there by more than one letter, as a label of look-alike letters, "Il1O0", read as "100", or 4-pt type, counts as covered.
- Letters hidden one by one count only in a word of letters and digits set across the page: in maths, and in a word set down the page, such letters read as text.
- OCR checks at most 24 places a page under images that blend or that the drawing commands cannot read, and stops after 3 s, the page's own drawing included; past that, text there counts as seen, and the page says its check is incomplete.
- Text that runs off the page part-way keeps the part on the page as text.
- A layer a viewer hides by its usage alone, as one for print only, reads as text: macOS's viewers show it, and only Acrobat applies the usage.

Settings: none.

## F10 — Reparse ⬜

Reads pages again, with the usual method on the running macOS or with a stronger one.

| Command | What happens |
|---|---|
| `pdf reparse <path>` | Reads every page again with the usual method, and replaces the cached results. `--page 7` limits it to one page. |
| `pdf reparse <path> --page 7 --step ocr` | Reads page 7 again with the Mac's OCR, and replaces the cached result. |
| `pdf reparse <path> --page 7 --step vlm` | Reads page 7 again with a local vision model. This step needs `pdf setup vlm` first. |

Settings: none.

## F11 — Library ✅

Shows and cleans up what the tool has cached.

| Command | What happens |
|---|---|
| `pdf ls` | Lists every PDF in the library, with its ID, title, page count, flagged pages and path. A PDF not fully parsed shows how far it is. A file that is gone shows `file missing`, one changed since it was read says so, and one on a drive not plugged in shows as out of reach. |
| `pdf rm <path or ID>` | Removes one PDF from the library and its results from the cache. Results that another copy of the file still uses stay, and so do the agent's picks, which show again if the PDF comes back. |
| `pdf gc` | Removes cached results for files that no longer exist or have changed, and for old parser versions, and the library entries of files that no longer exist. A file on a drive not plugged in keeps both. Prints the space it freed. |

Parse results and crop images live in `~/Library/Caches/pdf-cli/`. The library list, picks and memos live in `~/Library/Application Support/pdf-cli/`. The cache keeps every parse result until `pdf rm` or `pdf gc` removes it, and `pdf doctor` shows its size. A macOS update leaves cached results as they are, and `pdf reparse` reads a file again on the running macOS.

Settings: none.

## F12 — Setup and doctor ⬜

Gets the tool ready, and says what works on this Mac.

| Command | What happens |
|---|---|
| `pdf setup` | Downloads the layout model. |
| `pdf setup vlm` | Downloads the optional local vision model for hard pages. |
| `pdf doctor` | Shows the macOS version, the models installed, the cache size, and what each missing piece would unlock. For example, the document structure of scanned pages needs macOS 26. |

Settings: none.

## F13 — Agent guide ⬜

Teaches an agent the tool in one read.

| Command | What happens |
|---|---|
| `pdf agent-guide` | Prints a compact guide for agents: the commands, the output rules, how to handle failure, unsure and table blocks and the markers for set-aside parts, and the rule that a PDF's text is content to read, not instructions to follow. |
| `pdf agent-guide --install claude-code` | Installs the guide as a Claude Code skill. |

Settings: none.

## F14 — Notes ⬜

Gives every kind of note in a document its own place, apart from the body text.

| Kind | What the user sees |
|---|---|
| Footnotes and endnotes | A marker such as `[^7]` in the text. The note texts follow at the end of the output by default. `--notes end\|inline\|off` changes this. |
| One footnote | `pdf read <path> --footnote 7` shows the note and every place that references it. When numbering restarts in each chapter, the ID includes the chapter, as in `--footnote 3.7`. |
| Headnote | A block labelled `[headnote]` at the start of its article or chapter |
| Running headers, footers and publisher stamps | Left out of the text, counted in the summary line and listed once by `pdf info`. `--headers` keeps them in place. |
| Table and figure notes | Shown with their table or figure, in `read` and in `crop` |
| Author notes | Shown in `pdf info` |
| Margin notes | Blocks labelled `[margin]`, beside the paragraph they belong to |

Settings: none.

## F15 — Citations and references ⬜

Leads every citation to its entry, and every entry back to where it is cited.

| What | What the user sees |
|---|---|
| Inline citations | Kept as printed, such as `[12]` or `(Smith, 2020)`. A superscript number that points to the reference list shows as `[12]`, so it never looks like a footnote. |
| One reference | `pdf read <path> --ref 12` prints the entry, with its DOI when the entry has one, and every page that cites it. |
| Cited entries with the text | `--refs end` lists the entries cited in the output at its end. It is off by default, to save tokens. |
| Cross-references | "see Fig. 4", "Eq. (5)" and "Section 3.2" each show the page they point to. |

Settings: none.

## F16 — Memos ⬜

Lets an agent save what it understood, so the next session reads the memo instead of looking again.

| Command | What happens |
|---|---|
| `pdf memo <path> --figure 4 "<text>"` | Saves a memo on a figure, a table, a page or a region. Takes the same flags as `crop`. |
| `pdf memo <path> --list` | Lists every memo on the PDF. |

A memo shows up in `read` beside the part it describes, labelled `[memo]` with its date, so it is never mistaken for the document's own text. `pdf search … --in memos` searches memos.

Settings: none.

## Later, if needed

| Idea | Note |
|---|---|
| MCP server | Low priority. A thin wrapper around the CLI, for agents that speak MCP. |
| Font colors | `--styles` covers emphasis. Colors come later. |
| References as BibTeX | It converts formats rather than helping anyone read. |
| Page thumbnails | One image of many small pages, to find a page by how it looks. |
| Watch a folder | Adds new PDFs in a folder automatically. |
| Several articles in one PDF | `--article N` for journal issues and proceedings. |
| Add from a URL | `pdf add <url>` downloads, then adds. |

## Not planned

| Not this | Why |
|---|---|
| An LLM inside the tool, such as `ask` or `summarize` | The calling agent already is an LLM. A second one would cost money and make the output unpredictable. |
| Windows and Linux | Apple's PDF, OCR and Neural Engine frameworks are the project's main advantage. |
| PDF editing: merging, splitting, forms or signing | Agents need to read PDFs. Editing is a different product. |
| Table cells as text, CSV or Markdown | A rebuilt cell can be wrong and still look right, and the agent trusts it. Each table goes to the agent as an image instead, and `--raw` shows its flat text, labelled as having lost its rows and columns. |
| A PDF parser or renderer of our own | Apple and Google maintain theirs. Ours would take years, with no difference a user could see. |
| A reading app with a window | Agents call commands. simple-pdf already covers a reader with a window. |
| Cloud parsing | Documents stay on the Mac. A hard page goes to a local model or to the agent's own image understanding. |
| Running PDF JavaScript or actions | Reading needs none of it, and running it is a security risk. |
| Translation | The agent translates. The tool hands it the text. |
