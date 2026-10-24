<!-- what-we-build: drafted 2026-10-25 -->
# Features

✅ built · 🚧 built with a gap · ⬜ planned

F1 and F11 are ✅ built, F2, F3, F4, F5, F7, F8, F9, F13 and F14 are 🚧 built with a gap, and every other feature is ⬜ planned. The commands and output samples show the intended behavior.

## F1 — Add ✅

Adds PDFs to the library once, so every later command reads from the cache.

| Command | What happens |
|---|---|
| `pdf add <paths…>` | Parses each PDF and caches it. Accepts files, folders and globs. A folder adds every PDF in it and in its subfolders. Prints each PDF's ID, title, page count and status, such as `1f9472ae · Dataset Distillation by Influence Matching · 11 pages · ok · paper.pdf`; a path that failed prints `<path>: failed: <reason>`. `--json` gives one object: `files`, an entry for each path (the line's parts, or the failure shape), and the counts `added`, `flagged` and `failed`. |
| `pdf add <paths…> -j N` | Parses with up to N workers in parallel. By default, every parse on the Mac shares a pool of half the performance cores, at least 2, and pages nobody waits for parse at the lowest priority, so the Mac stays responsive. |
| `pdf add <path> --password <pw>` | Opens a password-protected PDF. Other users of the Mac can see the password in the command line while it runs. |
| `pdf add <path> --password-stdin` | Opens a password-protected PDF with the password read from standard input, as in `echo "$PW" \| pdf add paper.pdf --password-stdin`, which keeps it out of the command line. On a terminal it asks for the password and hides it as it is typed. The password is taken as typed, spaces included. |

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
  tbl 1    p.12   Results on ImageNet
  fig 4    p.15   Accuracy vs. dropout rate
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

The outline comes from the file's bookmarks, or, in a file with none, from the headings in its text, such as "2.1 Method" or "References". The output says which. `pdf info` answers once the file is indexed and its first page parsed: on a file not seen before, the sizes, the flags and the headings cover the pages parsed so far, and the output says how many those are. A section whose end lies on a page not parsed yet shows its size as `…`. The table shows the top two levels, at most 40 rows: past that, the top level alone where it holds 10 to 40 sections, as a book's chapters, and otherwise the first 40 rows, so a book with hundreds of bookmarks costs a few hundred tokens, as a paper does. `--json` gives every section, at every level.

When a file's comments, form fields, attachments and scripts cannot be read, as when a hostile file makes the reading run out of time, `pdf info` says they are unknown and why, and the pages read all the same.

The figures and tables are those `pdf read` finds (F3), in page order, each with its caption cut to 70 characters, at most 40 rows; `--json` gives them all, with their whole captions.

Gap:
- The counts of headnotes, footnotes and references, and two-page spreads, come later.

Settings: none.

## F3 — Read 🚧

Prints text in reading order. Every block shows its page and its number on the page, and `--json` gives its position too. On a page of columns each column reads whole, the left one first, or the right one in Hebrew and Arabic. Running headers, footers, page numbers and publisher stamps are left out and counted in the summary line (F14).

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
| `--headers` | Shows the running headers, footers, page numbers and publisher stamps in place, labelled `[header]`, `[footer]` or `[publisher stamp]` |
| `--raw` | Shows the text that normal output set aside, in place, each part labelled with its reason: `[low-quality]`, `[unsure]`, `[table text: rows and columns lost]`, `[figure text]`, `[equation text: its layout lost]` or `[old OCR]` |

Without a page or section flag, `pdf read` starts at the first page and stops at the default budget (see F7). A page asked for is parsed first, and a read that the budget stops early waits only for the pages it shows.

Gap:
- `--section` takes one section per read so far. `--styles` and `--format html` come later.
- An image or a drawing outside every figure and table is a marker of its own, after the block it sits on: `[image] crop: pdf crop paper.pdf --page 3 --bbox …`, or `[drawing]` for shapes the page draws, as a chart. A drawing is a group of shapes that holds a curve or a slanted line, or two bars, 1% of the page or more; rules alone, as a table's borders, are none, nor a box with rounded corners, a bar with text on it, as a shaded cell, or a bar at the page's edge. Its crop takes in the text within 12 pt, its labels. A figure's panels side by side join, and so do two figures in two columns closer than 30 pt; panels stacked, or far apart, are a marker each. A scan's page has no image marker: its image is the page. Stamps, ink and shapes a reader drew are `[stamp]`, `[ink]` and `[shape]`, with their crop; a stamp's name shows only when it is one of the PDF standard's 14.
- An annotation goes after the block its center lies in, or the nearest block on its line, or the last block above it: a comment on a word in a paragraph comes after the whole paragraph.
- The words under a mark or a link are the longest run of PDFKit's selection there that the blocks under it show in the same order: a mark over text a reader cannot see shows no words, and a link over it is hidden. A link goes inline where its block's text holds its words as one run, on the run nearest the link's place on the page, a whole word where one is, never inside another link or a note's mark: the back-references of a list of references, each a link on a "1", each take their own. Else it stands after the block.
- A password field shows "a password, not shown", a choice the text its list shows, and a checked box "checked". An annotation the file hides by its flags, by a layer switched off, by no opacity, by no size, by lying mostly off the page, or as a reply to a hidden comment, is a hidden-text marker.
- A paragraph's annotations take about 1,000 tokens at most; a line counts the rest. An author's name or a comment may hold text shaped like the tool's own markers, on the comment's own line.
- Columns are found on pages read from their text layer: the gap that the fewest lines cross in the middle half of the text, and lines across both columns, as a title or a caption, part the page into bands. Only a band whose two sides each hold two lines or more that fill their column moves, and a page of three columns keeps PDFKit's order; each column keeps PDFKit's order, and lines that are no running text, as a table's cells, a grid of authors or a figure's labels, keep their place. A caption across the page keeps PDFKit's place too, which on one smoke page is after the columns below it. A page read by OCR keeps the recognizer's order.
- A running header, footer or stamp sits in the page's top or bottom 12%, as its outermost text there, or its outer 10% at a side, holds three lines at most and no hidden text, and repeats at the same edge of a page within 4: its letters and digits the same once a page number at either end is dropped, or, for OCR's misreadings, nine in ten alike; a short one, on two pages. A page number alone, as "12" or "Page 12 of 30", needs no repeat but must agree with the page's own number or a page number nearby, and arXiv's stamp in the margin counts alone. Only pages parsed so far count, so while a file parses a header can show until its neighbours are parsed; the summary line says the read is provisional. A table's header row repeated at the top of each page of a long table counts as a running header.
- A table drawn without horizontal rules, as one of shaded rows, is not found, and its cells read as text; a table of sentences set in the body's size, as some prompts, may end at its first such rows, the rest reading as text. A figure with no numbered caption, or one whose picture is another figure's, as a single image holding two figures, keeps its pictures' markers. A table's notes read as text after its block. Pages read by OCR have no figures, tables or equations: OCR's lines carry no drawing commands. An equation's number at its left, as `leqno` sets it, one PDFKit joins to the next column's text, or one set closer than 1.5 em to the maths before it, is not found, and a display of several rows that PDFKit gives in scraps, as a bracket over three rows, can crop only the rows next to its number. A caption's text follows the reading order, so where PDFKit reads a caption out of order it can start mid-sentence.
- At most 1,000 links a file are read, and 1,000 other annotations, the words under them for at most 3 s; `pdf info` counts the rest. TeX Live's PGF manual holds 44,700 links. Other annotations, as a sound or a file's icon, show nothing; a link that starts a program is a script, which `pdf info` lists.

Apple OCR reads a scanned page, a page whose text layer is stray marks or broken characters, and every page of a file whose text layer disagrees with its own image. Its blocks carry addresses like any other, and the text layer it replaced shows with `--raw`, labelled `[old OCR]`.

A table appears as a table block in place of its cells, where its caption or its first cell stands: its number, its caption and the command that crops it. The agent reads the cells from the image, and `--raw` shows the table's flat text, labelled. The first line counts the blocks set aside so.

```text
¶12 [table 3] Forecasting results on multivariate benchmarks. Bold: best.
  crop: pdf crop paper.pdf --page 6 --table 3
```

A figure appears the same way, as a figure block with its caption and the command that crops it; its labels, as a chart's ticks, go aside as `[figure text]`. A numbered equation is a block with its number and its crop, its symbols aside as `[equation text: its layout lost]`, since PDFKit gives a display's lines out of place. The agent reads a table or an equation from its crop and keeps what it read with `pdf transcribe`, below. A figure's alt text, which a tagged file gives for readers who cannot see it, is text a reader of the page never sees: a hidden-text marker after the figure, `alt text, the file's words for a picture`, and its words only with `--include-hidden` (F9). An image or a drawing outside every figure and table, such as a logo, a signature or a chart without a caption, gets a marker in place, its alt text marked the same way:

```text
¶7 [equation 2] crop: pdf crop paper.pdf --page 4 --equation 2

[image] crop: pdf crop paper.pdf --page 3 --bbox 0.62,0.08,0.30,0.12
```

An equation or a table the agent has read is read once. `pdf transcribe` keeps the LaTeX of an equation, or with `--table 2` the Markdown of a table, that the agent read from its crop, given on standard input, and every later read shows it in the block, labelled as the agent's reading with its day, with the crop to check it by:

```sh
$ pdf transcribe paper.pdf --page 4 --equation 2 <<'EOF'
\mathcal{L} = -\sum_{i} \log p(y_{i} \mid x_{i})
EOF
kept the LaTeX of equation 2 on p.4; pdf read shows it there, labelled [equation 2, transcribed 2026-10-18]
```

```text
¶7 [equation 2, transcribed 2026-10-18]
    $$
    \mathcal{L} = -\sum_{i} \log p(y_{i} \mid x_{i})
    $$
  crop: pdf crop paper.pdf --page 4 --equation 2

¶12 [table 3, transcribed 2026-10-18] Forecasting results on multivariate benchmarks. Bold: best.
    | Model | ETTh1 | ETTh2 |
    |---|---|---|
    | Ours | 0.412 | 0.338 |
  crop: pdf crop paper.pdf --page 6 --table 3
```

The tool rebuilds no LaTeX or table itself, as rules cannot promise them right; what it keeps is the agent's, and the label says so.

- LaTeX goes between `$$` lines, unless it is a display environment of its own, as `align`, or holds its own `$` or `\(` signs; the `$$`, `\[ \]` or `\( \)` the agent put around the whole, and a code fence around a table, are dropped.
- Each line goes out four spaces in, below the block's own `crop:` line, so none passes for a page, a block, a command or a Markdown heading or fence of its own.
- `--json` gives it as the block's `latex` or `markdown`, with `transcribed`.
- It is kept by the page's key and the number the page gives the region, beside the picks in the agent's own folder: it holds for the same page in any file, a page that changes leaves it, and deleting the cache keeps it. A number typed in another case, as `s1`, keeps it for `S1`.
- Where a page numbers two equations alike, it goes with the first, which `pdf crop` crops, and both commands say so.
- Another transcribe replaces it, and `--clear` removes it, even for a region the page no longer shows.
- At most 4,000 characters for an equation and 12,000 for a table, each combining mark counted; 100,000 bytes of input at most, in UTF-8. What could reorder, hide or break the output goes: control and format characters, those a renderer ignores, and line separators, which become newlines.
- `pdf search` does not search it.

Figures, tables and equations are found by rules on the page's lines and drawing commands, with no model:

- A caption is a line that starts "Figure 4", "Fig. 4", "Fig 4", "Table 2", "TABLE IV", "图 3", "表 1", "図 1－2", "Рисунок 2", "Таблица 1", "Abbildung 3", "Tabelle 2", "Tableau 1", "Figura 1" or "Tabla 1", with the lines below it that go on with it, until a rule, a picture or a change of size. Its number's dashes, as full-width "－", read as "-": `--figure 1-2`. A line that only goes on from a line of running text above it, as "… as shown in" over "Figure 1. We …", is none. Every caption is a block of its own, found its figure or not.
- A figure is the pictures nearest its caption in its column, above it, or below it where those are much nearer, within 15% of the page, with the pictures stacked within 24 pt and the short lines around them. No line of running text is its: no sentence, nor a paragraph's short last line, and a picture beyond two lines of running text is not the caption's. With no picture there, as a chart whose bars carry their values or a heatmap's cells, it is the shapes the page draws there, joined within 6 pt, 1% of the page or more, with no running text inside.
- A table is the horizontal rules that chain from its caption, the first within 30 pt, until a gap of 30% of the page, another caption, or two lines of running text across it, five words or more each, in another size than its rows, or, before its first rows, in the size of the page's running text outside it and its captions: two rules at least, with text between. A rule drawn in pieces, a piece a column, is one rule; only rules about as wide as the first chain, so a footnote's short rule and a rule across the page under a table in one column are not its, nor a rule in the page's top 5% or bottom 7%, as a footer's. A table ruled only around its header goes on down its rows, each close under the one before, until a blank, a sentence, a rule or a caption.
- An equation is a line that ends in its number, as "(5)", set 1.5 em or more apart from the rest, or a number alone on its line beside maths, with the lines of maths above and below it and the rest of each of their rows: in its column on a page of two, none that reads as a sentence, as "where ε is …", and those below it no further than those above. A table's header of column numbers, "(1) (2) (3)", is none. At most 300 numbers a page are looked at.
- A block that holds hidden text stays in the text with its markers, inside a region or not. The words of a running header are never a region's, and a table's header row repeated on each page of a long table is the table's, not a running header. Unsure words inside a region go aside with its text and flag no page.
- A read that goes on from a block inside a region, as a search hit's, shows the region's block.

The rest of the page reaches the text too, at its position:

| What | How it shows |
|---|---|
| Comments and sticky notes | `[comment · Reviewer 2] Please cite the 2019 baseline.`, with the author when the file names one; `[reply · …]` for a reply, `[note] …` for a note typed on the page |
| Highlights | `[highlight] the highlighted words`, with the comment attached to it, if any, as `· comment: …`; `[underline]`, `[squiggly]` and `[strikeout]` alike |
| Filled-in form fields | `[field: Name = …]` |
| Links | `[here](https://…)` in Markdown, and `here <https://…>` in plain text; `[here](#p.12)` for a page of the file |
| An annotation the file hides | A hidden-text marker, `an annotation the file hides` (F9) |

They come from the file's facts, read for each version of the file, not from its pages' parse: a file that only gains highlights shows them without a page read again (GOALS.md → G9).

Planned (DESIGNS.md → "Decision: `read` reads, `note` and `ref` look up, `--show` shows what was set aside, `doctor` cleans"): `--show raw,hidden,headers` replaces `--raw`, `--include-hidden` and `--headers` (M2.17). Until it is built, the flags it replaces work as written in this document; when it is built, this document and the F8, F9, F14 and F15 sections change with it. (`pdf note` and `pdf ref` replaced `--footnote` and `--ref` in M2.16.) `--notes` and `--refs`, which choose where the cited notes and references show, stay.

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
- `--in` comes with notes and references in M2.7 and M2.8, and memos when `pdf memo` is built, later; search covers all the text until then.
- A hit inside a figure, a table or an equation names it, with its crop command, as `in table 3 (crop: pdf crop paper.pdf --page 6 --table 3)`, and a hit inside hidden text shows as a marker.
- Running headers, footers and page numbers stay in the index, so a word of one is a hit on each of its pages (TODO.md).

Settings: none.

## F5 — Crop 🚧

Turns one part of a page into an image, so the agent can look at it with its own image understanding.

| Flag | What it crops |
|---|---|
| `--figure 4` | A figure, with its caption, by the number its caption gives |
| `--table 1` | A table, with its caption |
| `--equation 5` | A numbered equation |
| `--page 7` | A whole page |
| `--page 7 --bbox 0.1,0.4,0.8,0.3` | A region, given as x, y, width and height in fractions of the page |
| `--grid` | Draws a labelled grid over the page, to help the agent pick a region |

```sh
$ pdf crop paper.pdf --figure 4
/Users/me/Library/Caches/pdf-cli/crops/b430b72936d6cf8b/p15-0.51,0.34,0.38,0.25.png  (~1.6k image tokens, 1137×1058 px)
p.15 · caption: Accuracy vs. dropout rate
mentioned on p.12, p.15
```

`--figure`, `--table` and `--equation` look in the pages parsed so far, and in the whole file once it is parsed when those do not hold it; `--page` narrows them to one page, and is needed where two pages hold the same number, as an appendix that numbers its tables again. An unknown number fails with the numbers found, once the whole file is parsed: on a long file that is not yet, that takes as long as its parse, 2 minutes for a 517-page textbook. `--equation` and `--table` also print the LaTeX or Markdown the agent kept, to check against the image, or else the `pdf transcribe` command that keeps it.

The image is in color, and it is sized so small text in a chart stays readable. `pdf crop` prints the absolute path of the image file. The file stays for 7 days, and the same command makes it again after that.

```sh
$ pdf crop paper.pdf --page 2 --bbox 0.08,0.07,0.85,0.3
/Users/me/Library/Caches/pdf-cli/crops/b430b72936d6cf8b/p2-0.08,0.07,0.85,0.30.png  (~1.5k image tokens, 1568×716 px)
```

A region uses the same fractions as the positions in `pdf read --json` and the crop commands in failure blocks, taken on the page as stored, before any rotation; the image comes out upright. A region is rounded outward to hundredths of the page, so it always holds all of what was asked for. An image fits Claude's standard limits, 1,568 px on its long edge and about 1,568 image tokens, so a whole page costs about 1,500 tokens and a small region comes out enlarged, up to 6 times. It shows comments and highlights as a reader sees them. The same crop asked again within 7 days comes from the cache folder at once, and `pdf gc` removes older ones. `--password-stdin` opens a locked PDF, and `--json` gives the image's path, size and tokens, and the LaTeX or Markdown kept.

Gap:
- `--figure 4b` crops a sub-figure only where a caption numbers it so; a figure's panels are not found one by one. A table's notes below it are not part of its crop. `mentioned on` names the pages whose text names it, as "Fig. 4" or "Table 2" does (F15), in the pages parsed so far.

Settings: none.

## F6 — Dump 🚧

Writes a PDF's content to files and prints their paths.

| Flag | What it writes |
|---|---|
| `--markdown`, `--text` | The document as `pdf read` gives it, `document.md` or `document.txt`, or the pages given with `--page` |
| `--figures` | Every figure as a PNG, vector charts included |
| `--tables` | Every table as a PNG |
| `--notes` | Footnotes, endnotes and other notes, as `notes.json` |
| `--refs` | The reference list, as `references.json` |
| `--attachments` | The files attached to the PDF, saved without being opened |
| `--scripts` | The PDF's scripts, as text files that never run, each headed by what starts it |
| `-o <folder>` | The output folder. The default is a folder named after the PDF, in the current folder. |

`--json` lists what was written, with the folder in the same form as the paths (links above it resolved, `/private/tmp/…`). A file is never overwritten: a name taken gets a number. Attachments keep the PDF's quarantine mark. An attachment is saved by the last part of its name alone, with no leading dot and no execute permission, and a name taken gets a number. `--password-stdin` opens a locked PDF for everything but `--markdown` and `--text`.

Gap:
- `--html` and `--embedded-images` are not built. A table's PNG carries no notes below it (as F5's gap says). The words of `notes.json` and `references.json` are the text as parsed, with no marker for hidden words. Two figures that share a number on one page give the first one's image twice.
- Attachments and scripts are read by a worker under the usual time and memory limits, so a file that exhausts them loses its attachments and scripts, said so in the output. A stream with stacked filters, or one over 256 MB decoded, is left out and said so; a dump writes at most 1,000 files and 1 GB, and a stream shared by many places is saved once. A launch action is written as a note on what it names, never started. A link in the way of the output folder or its `attachments` and `scripts` folders stops the writing there.

Settings: none.

## F7 — Output basics 🚧

Every command follows the same rules, so an agent learns them once.

- Every block shows its page and its number on the page: a heading such as `## p.12` starts each page, and `¶3` starts its third block. `--json` gives each block's position on the page too, such as `0.10,0.40,0.80,0.30`, and every doubt comes with the command that crops it. The page is its position in the file. When the number printed on the page differs, the page's heading says so, as in `## p.12 (printed 237)`.
- Superscripts and subscripts keep a mark, as in `10^{-5}` and `x_{2}`. Footnote markers and citation numbers have their own marks (see F14 and F15).
- A word that a hyphen splits across two lines comes back whole when the page or macOS's word list knows it. Otherwise the hyphen stays, as in `self-attention`.
- Every command accepts `--json`, and ends with the exit codes of F8. A failure has one shape, `<path>: failed: <reason>`, or `{"file": …, "failed": …}` under `--json`; `path` is the file, or what the command was given (`pdf rm`'s target, `pdf add`'s own path inside its `files` list); a command with no file puts its own name there: `pdf ls`, `pdf gc`, `pdf agent-guide`, `pdf add` and a library-wide `pdf search`. The commands that write say what they did under `--json`: `pdf pick` gives `file`, `page`, `block`, `picked` and `text`; `pdf transcribe` gives `file`, `page`, `kind`, `number` and `kept`, or `removed` with `--clear`, and `sameNumber` when the page numbers several the same; `pdf rm` gives `removed`, `files` and `cachedPages`; `pdf gc` gives `removed` (counts), `freedBytes` and `compacted`; `pdf ls` gives `documents`; `pdf add` gives `files`, one object for each path, with `id`, `title`, `pages` and `flagged` or, in the failure shape, `failed`, and the counts `added`, `flagged` and `failed`; `pdf agent-guide` gives `guide`, or with `--install` `file`, `installed` and `warnings`. The commands that change the cache (`pick`, `transcribe`, `rm`) take `--dry-run`, which says what they would do and does nothing.
- Output starts with a one-line summary: the pages read, the pages flagged and what normal output set aside.
- A file that macOS Preview or another app saved through PDFKit carries a warning in its summary line: such a save can damage the text, and an earlier copy may read better.
- Nothing is dropped without a trace. What normal output sets aside leaves a marker in place, or a count in the summary line, with the flag that shows it: `--raw` for doubtful text, `--include-hidden` for hidden text and `--headers` for running headers, footers and publisher stamps.
- `--budget N` stops the output at about N tokens, between blocks, and ends it with a line that continues the read, such as `next: pdf read paper.pdf --from p4.27`. A text block larger than the whole budget is cut inside, and the next read goes on from the cut. A failure block, or text shown with `--raw`, larger than the budget goes out whole, so every read moves on. `read` and `search` stop at 5,000 tokens by default, about 5 pages of a paper, and `--budget all` turns the limit off.
- While a document is still parsing, the summary line says `provisional`, with how many pages are parsed so far, because headings and note numbers can change once the whole document is known.

Gap: no command takes `--dry-run` yet (M2.18). A search whose pattern runs too long (`--regex`, past 10 s) still stops with an `Error:` line on standard error and exit 1, not in the failure shape.

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
| OCR read the page, but its second reading, which checks the first, failed | None |
| The page draws text a reader sees that PDFKit left out of its text, as a Type 3 font's line with no text map | None |
| Part of the page's drawing commands is damaged and could not be read, so what it draws is missing from the text and the image | None |

When only one block is in doubt, only that block is replaced, and the rest of the page reads normally. Text PDFKit left out has no block: a failure block for each place, at most 20 a page, numbered after the page's blocks, gives a crop command for it. What its strings spell never goes out, even with `--raw`: the check of what a reader sees there cannot tell every way of hiding a string, and a font with no text map need not spell what it shows. So a string hidden in a way the check misses, as white text between two lines or a line squeezed by its text matrix, can flag its page and cost a crop, but its words stay out. A dashed arrow or a symbol of display maths that PDFKit leaves out, drawn as 3 letters or digits or more, flags its page too. A word PDFKit leaves out inside a line it keeps goes unflagged where PDFKit lays the next words' boxes over it, as it does for a Type 3 font with a font descriptor. A page whose drawn text PDFKit left out by 30% or more is read by OCR instead, where OCR reads clearly more. A damaged part of a page has no block either: a content stream that declares 64 bytes or more and holds no operator, as one whose filter its data does not match, which macOS draws as nothing and reports nowhere. One failure block after the page's blocks says so, with no command, since the page's image lacks it too; on a page in doubt as a whole, it goes with the page's failure block. A stream damaged partway, which still gives operators, a damaged form the page draws, a stream whose length is missing or no number, and the streams of a page with no resources go unflagged. The crop command covers the smallest region that holds the doubt, with the lines around it: a few lines, a paragraph, a table or the whole page. A small crop costs the agent fewer image tokens and stays sharp.

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
- A file that PDFKit cannot open fails as a whole, in one line that names the reason: not a PDF, damaged, locked by a password, or slow to open, past 90 s. A file slow to open gives commands that verdict for 10 minutes, and then a command tries it again. A locked file points to `pdf add <path> --password-stdin`.
- The exit code tells success from failure:

| Exit code | Meaning |
|---|---|
| 0 | Every requested page read well. `info`, `search`, `crop` and `dump` of a file with flagged pages also end 0 and name the pages in their output. |
| 1 | The command could not run, such as on a file that does not exist (every command: `<path>: failed: no such file`), or when it could not write what it was asked to. |
| 2 | Some pages failed, are low-quality or hold unsure words. The rest of the output is valid. Only `read`, `add` and `dump` (when the document it writes has flagged pages) end with it. |
| 3 | The file failed to open (not a PDF, locked, damaged), on every command that takes a file, or no requested page holds text to show: each one failed or is in doubt as a whole. |
| 64 | The command was used wrongly, such as with an unknown flag. The parser ends with it, and prints the usage. |

`pdf add` of several paths ends 2 when some failed or some pages are flagged, 3 when every path failed and one of them failed to open, and 1 when none could be tried (every path missing). `pdf dump` ends 1 when it could not write to its folder (a link in the way, also for figures, tables and attachments), else 3 when its `read` of the document failed, else 2 when the document has flagged pages; the files it did write stay, and its output lists them with a note for each that was not written. A look-up that matches nothing (`pdf read --section`, `--printed-page`, `pdf note`, `pdf ref`) is a failure in the one shape, exit 1, listing what exists (M2.16).

Gap:
- The blocks reach the agent once `pdf read` is built (M1.7). Until then, the hidden `pdf debug-read` shows them. Their crop commands work once `pdf crop` is built (M1.9), and `pdf reparse` comes later (F10).
- An uncertain reading order is not checked yet: the check and its threshold wait for the final wrap-up, with M2.12's tuning.
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

A picture's alt text, the words a tagged file gives for readers who cannot see the picture, is hidden text too: a reader of the page never sees it, so a hostile file can plant a line there. A figure, or a picture outside every figure, whose drawing the file's structure tree gives alt text, carries a marker, `[hidden: 12 words, alt text, the file's words for a picture, which the page does not show · show: …]`, counted with the page's hidden places, and its words only with `--include-hidden`. It is found through the marked content the page draws the picture in, so alt text on a structure element that marks no drawing on the page, or only text, or a drawing too small to be a picture, is not read; at most 1,000 characters a picture, and past 5,000 marked drawings on a page the page says its check is incomplete. The page's cache key holds the alt text, so a file that gains it is parsed again.

Gap:
- A word set at an angle, as a chart's slanted label, is checked for its size, but not for ink, since PDFKit's boxes for it miss its ink.
- On a page whose images, filling their bounds and drawn to show, cover most of it, as a scan's or a slide's background, text in the invisible mode, or drawn with no opacity, reads as text, as a scan's own text layer does; so does text drawn under opaque such images, as a scan's text layer under its image. That holds only where ink lies along the word's line, within three times the word's width, and no string drawn to show, of about the word's size, lies there. The ink need not be the image's: such text reads as text whatever it says over a scan's inked lines, beside a visible heading of another size, an underline, a form field's border or fill, a dotted leader or a picture on a blank background. On a scan lightened to a fifth of its ink, the layer's words in its palest lines count as hidden. Text drawn to show there gets every check.
- Letters stacked on one spot count as too small to read where most of a string's letters are, word by word: a few words stacked inside a string of ordinary ones read as text, and so do stacked words carried on by small moves of the pen to a blank glyph.
- Glyphs PDFKit boxes on one spot, with no string about their size drawn there, count as too small to read, as letters stacked to hide them do: a chord's notes in a music font, whose boxes stand a third as tall as their strings, among them. On MusiXTeX's pages, whose text PDFKit leaves out, OCR reads the page instead.
- White words with a letter raised a few points, so that PDFKit's box for the word reaches the next line's ink, read as text between close lines.
- Text in the invisible mode laid over a dense dotted leader or a dashed rule reads as text where their ink fills its letters' boxes.
- Text over a photo always counts as seen: the photo's own ink cannot tell whether the text shows. So does white text with shapes drawn inside its box other than rules across it, as bars between its letters, and text in the invisible mode, or white, laid over other text that shows: the other text's ink stands for its own.
- Text under a shape drawn after it counts as hidden when the shape leaves no ink there, or is an opaque rectangle or an axial shading over it; under other shapes, as stripes, a pattern or a stamp annotation's picture, with ink of their own, it counts as seen.
- Text in a script OCR does not read, as Greek or Hebrew, under an image that lets part of it through by a blend mode, a stencil or a color key, counts as seen. A word OCR misreads there by more than one letter, as a label of look-alike letters, "Il1O0", read as "100", or 4-pt type, counts as covered.
- Letters hidden one by one count only in a word of letters and digits set across the page: in maths, and in a word set down the page, such letters read as text.
- OCR checks at most 24 places a page under images that blend or that the drawing commands cannot read, and stops after 3 s, the page's own drawing included; past that, text there counts as seen, and the page says its check is incomplete.
- Text that runs off the page part-way keeps the part on the page as text.
- A layer a viewer hides by its usage alone, as one for print only, reads as text: macOS's viewers show it, and only Acrobat applies the usage. So does content whose visibility expression nests past 32 levels: its layers decide.

Settings: none.

## F10 — Reparse ⬜

Reads pages again, with the usual method on the running macOS or with a stronger one.

| Command | What happens |
|---|---|
| `pdf reparse <path>` | Reads every page again with the usual method, and replaces the cached results. `--page 7` limits it to one page. |
| `pdf reparse <path> --page 7 --step ocr` | Reads page 7 again with the Mac's OCR, and replaces the cached result. |

Settings: none.

## F11 — Library ✅

Shows and cleans up what the tool has cached.

| Command | What happens |
|---|---|
| `pdf ls` | Lists every PDF in the library, with its ID, title, page count, flagged pages and path (`--json`: `documents`). A PDF not fully parsed shows how far it is. A file that is gone shows `file missing`, one changed since it was read says so, and one on a drive not plugged in shows as out of reach. |
| `pdf rm <path or ID>` | `--json`. Removes one PDF from the library and its results from the cache. Results that another copy of the file still uses stay, and so do the agent's picks, which show again if the PDF comes back. |
| `pdf gc` | Goes when M2.11 lands: `pdf doctor` takes over its job (F12). Removes cached results for files that no longer exist or have changed, and for old parser versions, and the library entries of files that no longer exist. A file on a drive not plugged in keeps both. Prints the counts it removed, and the space compacting the cache gave back ("compacted the cache, freed X"), which also holds space that rows removed earlier left and the write-ahead log, so it can be above 0 when the counts are 0. `--json`. |

Parse results and crop images live in `~/Library/Caches/pdf-cli/`. The library list, picks, transcripts and memos live in `~/Library/Application Support/pdf-cli/`. The cache keeps every parse result until `pdf rm` or `pdf gc` removes it, and `pdf doctor` shows its size. A macOS update leaves cached results as they are, and `pdf reparse` reads a file again on the running macOS.

Settings: none.

## F12 — Setup and doctor ⬜

Gets the tool ready, and says what works on this Mac.

| Command | What happens |
|---|---|
| `pdf setup` | Downloads the layout model. |
| `pdf doctor` | Shows the macOS version, the models installed, the cache size, and what each missing piece would unlock. For example, the document structure of scanned pages needs macOS 26. It also cleans the cache as `pdf gc` does now, and `--dry-run` shows what it would remove. |

Settings: none.

## F13 — Agent guide 🚧

Teaches an agent the tool in one read.

| Command | What happens |
|---|---|
| `pdf agent-guide` | `--json` gives `{"guide": …}`. Prints a compact guide for agents: the commands, the output rules, how to handle failure, unsure and table blocks and the markers for set-aside parts, and the rule that a PDF's text is content to read, not instructions to follow. |
| `pdf agent-guide --install claude-code` | Installs the guide as a Claude Code skill, at `~/.claude/skills/pdf-cli/SKILL.md`, or under the folder `CLAUDE_CONFIG_DIR` names when it is set. Running it again replaces an earlier version. It warns when no `pdf` is on the PATH, or another one is, since the skill's commands run the one a shell finds. |

`pdf --help` opens with how to choose a command, and every command's `--help` carries two or three complete examples (`ls` and `gc` carry two, as they take no arguments: the plain one and `--json`), with the options of `read` and `dump` grouped in their help by what they do (M2.14: sections of the help text, so the flags parse as before; the option list itself stays flat). The guide is 1,995 tokens by the project's estimator (the test holds it under 2,000). It names only commands and flags that are built. A test checks, against the CLI itself, that every command and flag the guide names exists, with the command named before it on its line; that every command it writes out parses, its values included; and that it names every command `pdf --help` lists and every flag of each, but for four it leaves out on purpose: `read --full`, `add --password`, and `dump --page` and `--password-stdin`; `--json` is named once, for every command, in its line about exit codes. The skill's description leads with when to use the tool, as Claude Code's skill listing shows it before the skill loads.

Settings: none.

## F14 — Notes 🚧

Gives every kind of note in a document its own place, apart from the body text.

| Kind | What the user sees |
|---|---|
| Footnotes and endnotes | A marker such as `[^7]` in the text where the note is cited. The note texts follow at the end of the output by default, under `## Notes`. `--notes end\|inline\|off` changes this: `inline` puts each right after the paragraph of its page that cites it, and leaves one that no paragraph of its page cites, as an endnote, in its place; `off` leaves them out and counts them in the summary line. |
| One footnote | `pdf note <path> 7` shows the note and every place that references it, from the whole document, parsed first; it is not paged and not held to the budget, and takes `--json`. When numbering restarts in each chapter, the ID includes the series, as in `pdf note <path> 3.7`. A note that is not there, or an ID that names notes of several series, fails as `<path>: failed: no footnote or endnote is 99; it has *, 1, 2`, exit 1, listing the IDs that exist. |
| Headnote | A block labelled `[headnote]`, in place, at the start of its article or chapter |
| Running headers, footers and publisher stamps | Left out of the text, counted in the summary line and listed once by `pdf info`. `--headers` keeps them in place. |
| Table and figure notes | Shown with their table or figure, in `read` and in `crop` (M2.6 leaves them as text after the block: see the Gap) |
| Author notes | A footnote on the first two pages that tells about the authors, as "equal contribution" or an affiliation set under a sign: shown in `pdf info`, and in `pdf read` as a footnote |
| Margin notes | Blocks labelled `[margin]`, after the paragraph they stand beside |

```text
paper.pdf · 4 pages · read p.1–4 · flagged: none

## p.2

¶5 The model was trained on public data[^3], and the rest of the paper follows.

## Notes

[^*] (p.1) Equal contribution.

[^3] (p.2) Source-Limited Track: https://www.codabench.org/competitions/11279/
```

```sh
$ pdf note paper.pdf 3
paper.pdf · footnote 3 · p.2

[^3] Source-Limited Track: https://www.codabench.org/competitions/11279/

referenced:
  p.2 ¶5: …trained on public data[^3], and the rest of the paper…
```

`pdf info` counts them: `notes read apart from the text: 12 footnotes, 3 margin notes (pdf read: --notes end|inline|off; pdf note ID)`, and lists the author notes as `author notes: [^*] Equal contribution.`. `--json` gives a note as a block of kind `note` with its `id`, its `status` (`footnote`, `endnote` or `author note`) and, for one listed after the text, its `place`.

Settings: none.

Gap:
- Notes are found by rules, with no model, from font sizes, positions and markers. Pages read by OCR have none: OCR's lines carry no sizes.
- A **footnote** is a block in the lower 60% of the page, set at least 7% and half a point smaller than the page's text (its size is the largest that 5% of the page's characters have, so footnotes that outweigh the text do not make it), which starts with its marker, a raised number or sign, or a number when the text raises the same number and the page sets no running text in the note's size in its upper 40%, with no body-size text below it in its column. A journal page set in 10 and 9 points can start a Methods paragraph with a citation's number that lost its raise: such a paragraph stays text, and so does a footnote with an unraised number on a page whose abstract is set in its size. The smaller blocks that go on right below it, within a line's height, join it; a footnote under a sign right below a numbered one can join it too. A part of a note's line that PDFKit gives as a block of its own, as a URL in another font, stays in the text where it stands. A footnote set in the body's size, as some books do, is not found, and a footnote that goes on over the page's end reads on the next page as a small block of running text. Lines that start with a raised marker, or with the next number in a run of small lines, begin a block, since a column of notes set with no gap would join into one. A table's notes right under a table that M2.6 finds stay text after its block; under a table it does not find, they can read as a footnote.
- A reference is a raised marker after a punctuation mark or a word of two letters or more, in the text a reader sees: `x^{2}`, `10^{3}` and `(a+b)^{2}` stay as the PDF spells them, and so do a marker after a closing bracket, `see (1)^{2}`, and a unit's power after a number, `5 cm^{2}`. A marker set as full-size text, as `[7]`, is not a reference. Each marker leads to one note: a footnote's is the next raised marker of its number on its page that no note has taken, unless the next note's comes first, and where no other note of the page has its number, the page's other markers of it lead to it too, as authors' to the affiliation they share. A note whose marker nothing cites is shown all the same, in its place with `--notes inline`. A note the read keeps as text leaves its marker as the PDF has it on its own page, but an endnote's marker on another page can still read `[^7]` with no note after the output.
- An **endnote** is an entry of a run of three or more numbers that go up, under a heading "Notes", "Endnotes" or "Notes to Chapter 3", which may be a running header, and on the pages that go on from it, with a number after the last, or 1 again for the next chapter's. A heading of another part, as "References", "Bibliography" or "Appendix", ends the list, and the page after it does not go on. A list the text never cites, as numbered steps under a heading "Notes", is none, and so is a numbered list of references with no such heading. Entries set as running text, with the next number inside a line, as the 9/11 Commission Report's, come apart there; an entry whose number PDFKit runs into its first word, as `192.Ibid`, is not found, and where a chapter's first entry is lost the list breaks there, so a page that holds it reads as text. An entry that goes on over a page's end reads on the next page as a block of text. Footnotes the size rule above leaves out, as three under a table's cells set in their size (WorldFAIR's p.123), can be taken for such a list; a list's own page cites none of it, so they read as text with their numbers. The references of all the endnotes are the most of them matched in order to the raised markers before each note's list, on pages that are no list, and of such matchings the one whose references are latest, closest to each list: all the notes at a book's end, or a chapter's after the chapter, find their chapter's text though a list between was missed, and a chapter whose markers the text lost leaves its own notes unmatched, not its neighbours'. A series whose references straddle the text's numbering starting again, a 1 that a 2 and a 3 follow within a few markers and three pages, keeps those after it; a lone `^{1}`, as a figure's, starts nothing. Where the text holds the same numbers in two places that fit equally, as two chapters whose lists were both missed, a note can still cite the wrong one.
- A note's ID is its marker, as `7`. Numbering that restarts, a note numbered no higher than the one before, or the next list of endnotes, makes a new series, and its notes' IDs carry its number, as `3.7`; the first series' IDs stay plain, so an ID does not change while later pages parse. "Series" counts the restarts, so it is the chapter's number only where every chapter has a note and every list is found: in the 9/11 Commission Report, a list broken where an entry is lost makes 17 series of 13 chapters. A document that numbers its footnotes from 1 on each page has an ID such as `12.1` for the first note of the twelfth page that has notes. A sign is its own ID, `*`, or `p3*` where the sign stands on more than one page, and `p3*2` for the second on its page; `pdf note <path> '*'` names one of them, or lists them. `pdf note <path> 7` asks which note it means when other series have a 7 too. Series come from the pages parsed so far, so while a file parses, a note read from the middle of it can change its ID, as the summary line's `provisional` says. `pdf note paper.pdf 7` parses the whole file first; it takes `--json` and nothing else, and an ID it does not find is a failure in the one shape, exit 1.
- A note goes out after the output when the read passes the block that cites it on its page, or its own block where none does, and a read that starts inside a note, as from a search hit, shows it. Notes count against the budget, which stops a read at a note's block as at a paragraph's, so a page of endnotes reads over several reads. A page's notes take 4,000 tokens at most and one note 800; the rest is counted, as `3 more notes on this page, not shown`, and `--footnote` shows any note whole.
- An **author note** is a footnote on the first two pages under a sign, or with words as "equal contribution", "corresponding author", "e-mail" or "affiliation". Affiliations a paper sets in its byline, as arXiv papers do, are text.
- A **headnote** is the paragraph right under the page's first heading, in a size smaller than the body's, of two lines and 25 words or more, with body-size text after it, and no label as "Abstract". A summary under a title that is no headnote can look like one, and a headnote set in the body's size is text.
- A **margin note** is a block of four words of three letters or more, no more than 0.3 of the page wide, set wholly beside the page's columns of text, in horizontal lines: PLOS's sidebar of the article's citation and funding is one. The columns are the blocks in the body's size, or in the size most of the wide blocks' words have, where a lead paragraph in large type would be the body's. A chart's labels, a subfigure's caption or a table's cells that no region holds, set outside the columns, can still read as one, as can a page of figures with a few paragraphs. Pages of vertical text have none. A paragraph's margin notes take about 1,000 tokens, as its annotations do; the rest read as text in their place, within the budget.
- A note's block that a read marks as doubtful or unsure, or sets aside as a running header, stays text where it stands.

## F15 — Citations and references 🚧

Leads every citation to its entry, and every entry back to where it is cited.

| What | What the user sees |
|---|---|
| Inline citations | Kept as printed, such as `[12]` or `(Smith, 2020)`. A raised number that cites the list of references shows as `[12]`, so it never looks like a footnote. |
| One reference | `pdf ref <path> 12` prints the entry, with its DOI when its words or a link over them give one, and every place that cites it. An entry of a list by author and year is named by its first author's surname and its year, as `pdf ref <path> Smith2020a` or `pdf ref <path> "Smith 2020"`; one with a printed key by the key, as `pdf ref <path> BK06`; one of a list after the first with the list's number, as `pdf ref <path> 2.12`. It parses the whole file first, is not paged and not held to the budget, and takes `--json`. An entry that is not there, or an ID that names several, fails as `<path>: failed: no entry of the reference list is 999; it has 1, 2, 3`, exit 1, listing the IDs that exist. |
| Cited entries with the text | `--refs end` lists the entries the output cites after it, under `## References`, each once. It is off by default, to save tokens. |
| Cross-references | "see Fig. 4", "Eq. (5)" and "Section 3.2" lead to the page that holds what they name, as a link of the file to a page does: `[Fig. 4](#p.7)`. `pdf crop --figure 4` says on which pages the text mentions it. |

```text
¶3 Five-year survival after surgery is only 50%[2,3], as before [12] and (Smith, 2020); see [Fig. 4](#p.7).

## References

[2] (p.11) Bernier, J. et al. Postoperative irradiation with or without concomitant chemotherapy for locally advanced head and neck cancer. N. Engl. J. Med. 350, 1945–1952 (2004).
```

```sh
$ pdf ref paper.pdf 15
paper.pdf · reference 15 · p.9

[15] Xuehai He, Yichen Zhang, Luntian Mou, Eric Xing, and Pengtao Xie. Pathvqa: 30000+ questions for medical visual question answering. arXiv preprint arXiv:2003.10286, 2020. 2, 6, 7

cited:
  p.6 ¶7: … public medical VQA benchmarks: SLAKE [27], VQA-RAD [23], and PathVQA [15]. Following the evaluation protocol…
```

`pdf info` counts them: `references: 46 entries, the list on p.9 (pdf ref ID; pdf read: --refs end)`. `--json` gives an entry that `--refs end` lists as a block of kind `reference` with its `id` and `place`, and `pdf ref` as the entry, its DOI and the places that cite it; `pdf crop --json` gives `mentionedOn`.

Settings: none.

Gap:
- Lists, entries and citations are found by rules, with no model, and judged when a page is read, against the pages parsed so far, as notes are (F14). On a first read of a file whose list is on a page not parsed yet, raised citations stay raised and `--refs end` lists nothing; the summary line says the read is provisional, and `pdf ref` parses the whole file first.
- A **list** starts after a heading of one or two lines, "References", "Bibliography", "Literature Cited", "Works Cited", "References and Notes" and the like, and goes on over the pages after it, while each is parsed, until a heading of another part, as "Appendix", "Supplementary", "Acknowledgements" or "Chapter 2", or a numbered or lettered heading set larger than its entries; a list by author and year ends where four blocks of words in a row hold no year. A list with no heading is not found. Running headers and page numbers at a page's edge stay out of it.
- An **entry** of a numbered list, `[12]` or `12.`, starts where its number, the one after the last, stands: at a block's start, where a number up to three past it is taken too, so a lost entry costs only itself; or inside a block that holds several. Where a list sets its numbers in a column of their own, as PLOS and JMIR do, PDFKit gives the numbers in one run, and the entries after them are matched to them by the authors' names that start each, only when the names count as many as the numbers: on the test set, 016's list comes out in part, and 019's and 095's not at all. An entry with a printed key, `[BK06]`, starts at its key. In a list by author and year, a block that starts at its column's left edge with a capital starts an entry, and the parse, since parser version 18, parts the entries a hanging indent sets; inside a block, an entry starts where a surname and initials follow the end of the one before. Such an entry is named by its first author's surname, as "Smith, J." or "Smith J" or "John Smith" give it, and its year; one with no year is left out. An entry's words are PDFKit's, with LaTeX's back-references, as "2, 6, 7", at its end.
- A **citation** in brackets names entries by number, range or key, as `[3, 5–7]` or `[BK06, Thm. 2]`, and counts only where every one it names is in the list. A raised number cites the list only in a document that cites so more often than in brackets, and not where M2.7 leads it to a note; it may follow a word, a punctuation mark, a per cent sign or a closing bracket. A citation by author and year, `(Smith, 2020; Lee and Kim, 2019a)` or `Smith et al. (2020)`, leads to the entries of that first author and year, a year without its letter to all of them, a second author narrowing them; a surname with a particle set in capitals, as "Le Bris", can miss. A citation leads to the nearest list after it of its kind, or else the last before it, so chapters that each end in their own list cite their own. Citations in captions, notes and tables read as printed and count for no `--refs end`.
- A **cross-reference** is "Fig. 4" or "Figure 4", "Table 2", "Eq. (5)" or "Equation 5", "Section 3.2", "Sec. 3.2" or "§3.2", and "Appendix A", in any case. It leads to the one page whose figure, table or equation M2.6 found with that number, or whose section the bookmarks or a numbered heading number so: a number that pages far apart hold, as an appendix that numbers its tables again, leads nowhere, and a table on pages that follow one another to its first. "Table 1 of [12]", another paper's table, leads to this one's. A lettered heading counts only after the list of references or as "Appendix A", so a title "A Survey of …" names no appendix. Where the file links the words already, its link stays.

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
