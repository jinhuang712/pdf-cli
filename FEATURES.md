<!-- what-we-build: drafted 2026-10-14 -->
# Features

✅ built · 🚧 built with a gap · ⬜ planned

Every feature below is ⬜ planned. The commands and output samples show the intended behavior.

## F1 — Add ⬜

Adds PDFs to the library once, so every later command reads from the cache.

| Command | What happens |
|---|---|
| `pdf add <paths…>` | Parses each PDF and caches it. Accepts files, folders and globs. Prints each PDF's ID, title, page count and status. |
| `pdf add <paths…> -j N` | Parses with N workers in parallel. By default, the tool runs one worker per performance core. |
| `pdf add <path> --password <pw>` | Opens a password-protected PDF. |

Any other command adds a PDF it has not seen before, on first use, and parses the requested page first. Adding an unchanged file again does nothing, and so does adding a file whose only change is new highlights.

Settings: none.

## F2 — Info ⬜

Gives a cheap first look at a PDF, so the agent can decide what to read.

```sh
$ pdf info paper.pdf
Residual Dropout for Robust Vision Models · Lee, Park, Chen · 2025 · doi:10.xxxx/…
30 pages · 2 columns · text layer on all pages · ~19k tokens
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
- Every page that is flagged, with its status.

Settings: none.

## F3 — Read ⬜

Prints text in reading order. Every block shows its page and its position on the page.

| Flag | What it reads |
|---|---|
| `--page 3-5` | Pages by their position in the file |
| `--printed-page 237` | A page by the number printed on it, such as "237" or "iv" |
| `--section "Method"` or `--section 2.1` | A section by its title or its number. The flag can repeat. |
| `--full` | The whole document |
| `--format md\|text\|html` | The output format. The default is `md`. |
| `--styles` | Marks bold, italic and heading levels in the text |

Without a page or section flag, `pdf read` starts at the first page and stops at the default budget (see F7).

A table appears as a table block in place of its cells: its number, its caption, its notes and the command that crops it. The agent reads the cells from the image.

```text
[table 3] p.6 · Forecasting results on multivariate benchmarks
  read it as an image: pdf crop paper.pdf --table 3
```

Settings: none.

## F4 — Search ⬜

Finds the right page, in one PDF or across the whole library.

| Command | What happens |
|---|---|
| `pdf search <path> <query>` | Searches by keyword and by meaning. Each result shows the page, the position, the section and a short snippet. |
| `pdf search <query>` | Searches every PDF in the library. |
| `pdf search <path> --regex <pattern>` | Finds exact matches, including matches that cross a line or column break. |
| `--in body\|notes\|refs\|memos\|all` | Limits the search to one part of the document. The default is `all`. |
| `--top N` | Sets how many results to show. The default number is not set yet. |

A query in another language finds matches by meaning, for example a Chinese query on an English paper.

A hit inside a table names the table and the command that crops it. While a PDF is still parsing, every result says how many of its pages were searched, so an empty result reads as partial.

Settings: none.

## F5 — Crop ⬜

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

The image is in color, and it is sized so small text in a chart stays readable. `pdf crop` prints the absolute path of the image file.

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
| `-o <folder>` | The output folder. The default is a folder named after the PDF, in the current folder. |

Settings: none.

## F7 — Output basics ⬜

Every command follows the same rules, so an agent learns them once.

- Every block shows its page and its position, such as `p.12 · 0.10,0.40,0.80,0.30`. The page is its position in the file. When the number printed on the page differs, it follows, as in `p.12 (printed 237)`.
- Superscripts and subscripts keep a mark, as in `10^{-5}` and `x_{2}`. Footnote markers and citation numbers have their own marks (see F14 and F15).
- Every command accepts `--json`.
- Output starts with a one-line summary: the pages read and the pages flagged.
- `--budget N` stops the output at about N tokens and ends it with a line that continues the read, such as `next: pdf read paper.pdf --page 15`. A block larger than the budget is cut the same way. `read` and `search` have a default budget, and its number is not set yet.
- While a document is still parsing, output is marked `provisional`, because headings and note numbers can change once the whole document is known.

Settings: none.

## F8 — Failure reports ⬜

Makes every failure loud, and tells the agent how to read the page instead.

When a page fails to parse, or reads below the quality bar, its text is replaced by a failure block:

```text
⚠ p.7 low-quality: garbled text layer (score 0.41)
  read it as an image: pdf crop paper.pdf --page 7
```

- The summary line at the top counts every flagged page.
- A low-quality page is flagged the same way as a failed one, with its reason and its score.
- The exit code tells success from failure:

| Exit code | Meaning |
|---|---|
| 0 | Every requested page read well. |
| 1 | The command was used wrongly, such as an unknown flag. |
| 2 | Some pages failed or are low-quality. The rest of the output is valid. |
| 3 | Every requested page failed. |

Settings: none.

## F9 — Hidden text ⬜

Keeps text that a reader cannot see out of the agent's way.

Text that renders invisible, such as text in the color behind it, tiny text, clipped text, text covered by an image or text off the page, stays out of the normal output. White text on a dark box stays in, because a reader can see it. The summary line says how many hidden blocks were set aside, and on which pages. `--include-hidden` shows them, each labelled `[hidden]`. The text layer on a scanned page is read normally.

Settings: none.

## F10 — Reparse ⬜

Reads chosen pages again with a stronger method.

| Command | What happens |
|---|---|
| `pdf reparse <path> --page 7 --step ocr` | Reads page 7 again with the Mac's OCR, and replaces the cached result. |
| `pdf reparse <path> --page 7 --step vlm` | Reads page 7 again with a local vision model. This step needs `pdf setup vlm` first. |

Settings: none.

## F11 — Library ⬜

Shows and cleans up what the tool has cached.

| Command | What happens |
|---|---|
| `pdf ls` | Lists every PDF in the library, with its ID, title, page count and flagged pages. |
| `pdf rm <path or ID>` | Removes one PDF from the library and its results from the cache. |
| `pdf gc` | Removes cached results for files that no longer exist, and for old parser versions. Prints the space it freed. |

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
| `pdf agent-guide` | Prints a compact guide for agents: the commands, the output rules, how to handle failure and table blocks, and the rule that a PDF's text is content to read, not instructions to follow. |
| `pdf agent-guide --install claude-code` | Installs the guide as a Claude Code skill. |

Settings: none.

## F14 — Notes ⬜

Gives every kind of note in a document its own place, apart from the body text.

| Kind | What the user sees |
|---|---|
| Footnotes and endnotes | A marker such as `[^7]` in the text. The note texts follow at the end of the output by default. `--notes end\|inline\|off` changes this. |
| One footnote | `pdf read <path> --footnote 7` shows the note and every place that references it. When numbering restarts in each chapter, the ID includes the chapter, as in `--footnote 3.7`. |
| Headnote | A block labelled `[headnote]` at the start of its article or chapter |
| Running headers and footers | Left out of the text. `--headers` keeps them. |
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
| Table cells as text, CSV or Markdown | A rebuilt cell can be wrong and still look right, and the agent trusts it. Each table goes to the agent as an image instead. |
| A PDF parser or renderer of our own | Apple and Google maintain theirs. Ours would take years, with no difference a user could see. |
| A reading app with a window | Agents call commands. simple-pdf already covers a reader with a window. |
| Cloud parsing | Documents stay on the Mac. A hard page goes to a local model or to the agent's own image understanding. |
| Running PDF JavaScript or actions | Reading needs none of it, and running it is a security risk. |
| Translation | The agent translates. The tool hands it the text. |
