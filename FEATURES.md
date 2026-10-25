<!-- what-we-build: drafted 2026-10-25 -->
# Features

✅ built · 🚧 built with a gap · ⬜ planned

F1 and F11 are ✅ built, F2, F3, F4, F5, F7, F8, F9, F10, F13 and F14 are 🚧 built with a gap, and every other feature is ⬜ planned. The commands and output samples show the intended behavior.

## F1 — Add ✅

Adds PDFs to the library once, so every later command reads from the cache.

| Command | What happens |
|---|---|
| `pdf add <paths…>` | Parses each PDF and caches it. Accepts files, folders and globs. A folder adds every PDF in it and in its subfolders. Prints each PDF's ID, title, page count and status, such as `1f9472ae · Dataset Distillation by Influence Matching · 11 pages · ok · paper.pdf`; a path that failed prints `<path>: failed: <reason>`. `--json` gives one object: `files`, an entry for each path (the line's parts, or the failure shape), and the counts `added`, `flagged` and `failed`. |
| `pdf add <paths…> -j N` | Parses with fewer workers than the Mac allows: N is capped at the worker count the user's memory budget gives (F12), so `-j` can slow a parse down and never speed it past the budget. An agent does not set it. By default, every parse on the Mac shares a pool of half the performance cores, at least 2, until `pdf setup` sets a budget, and pages nobody waits for parse at the lowest priority, so the Mac stays responsive. |
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
| `--show raw,hidden,headers` | Shows what normal output set aside, in place and labelled; any of the three values, as a comma list or the flag repeated. `headers`: the running headers, footers, page numbers and publisher stamps, labelled `[header]`, `[footer]` or `[publisher stamp]`. `raw`: shows the text that normal output set aside, in place, each part labelled with its reason: `[low-quality]`, `[unsure]`, `[table text: rows and columns lost]`, `[figure text]`, `[equation text: its layout lost]` or `[PDF text layer]`. `hidden`: the words of text a reader cannot see, each after its reason, in place of the markers (F9). Another value ends 64 and lists the three. `--raw`, `--include-hidden` and `--headers` are gone and end 64 with a pointer |

Without a page or section flag, `pdf read` starts at the first page and stops at the default budget (see F7). A page asked for is parsed first, and a read that the budget stops early waits only for the pages it shows.

Gap:
- `--section` takes one section per read so far. `--styles` and `--format html` come later.
- An image or a drawing outside every figure and table is a marker of its own, after the block it sits on: `[image] crop: pdf crop paper.pdf --page 3 --bbox …`, or `[drawing]` for shapes the page draws, as a chart. A drawing is a group of shapes that holds a curve or a slanted line, or two bars, 1% of the page or more; rules alone, as a table's borders, are none, nor a box with rounded corners, a bar with text on it, as a shaded cell, or a bar at the page's edge. Its crop takes in the text within 12 pt, its labels. A figure's panels side by side join, and so do two figures in two columns closer than 30 pt; panels stacked, or far apart, are a marker each. A scan's page has no image marker: its image is the page. Stamps, ink and shapes a reader drew are `[stamp]`, `[ink]` and `[shape]`, with their crop; a stamp's name shows only when it is one of the PDF standard's 14.
- An annotation goes after the block its center lies in, or the nearest block on its line, or the last block above it: a comment on a word in a paragraph comes after the whole paragraph.
- The words under a mark or a link are the longest run of PDFKit's selection there that the blocks under it show in the same order: a mark over text a reader cannot see shows no words, and a link over it is hidden. A link goes inline where its block's text holds its words as one run, on the run nearest the link's place on the page, a whole word where one is, never inside another link or a note's mark: the back-references of a list of references, each a link on a "1", each take their own. Else it stands after the block.
- A password field shows "a password, not shown", a choice the text its list shows, and a checked box "checked". An annotation the file hides by its flags, by a layer switched off, by no opacity, by no size, by lying mostly off the page, or as a reply to a hidden comment, is a hidden-text marker.
- A paragraph's annotations take about 1,000 tokens at most; a line counts the rest. An author's name or a comment may hold text shaped like the tool's own markers, on the comment's own line.
- Columns are found on pages read from their text layer: the gap that the fewest lines cross in the middle half of the text, and lines across both columns, as a title or a caption, part the page into bands. Only a band whose two sides each hold two lines or more that fill their column moves, and a page of three columns keeps PDFKit's order; each column keeps PDFKit's order, and lines that are no running text, as a table's cells, a grid of authors or a figure's labels, keep their place. A caption across the page keeps PDFKit's place too, which on one smoke page is after the columns below it. A page read by OCR keeps the recognizer's order.
- A running header, footer or stamp sits in the page's top or bottom 12%, as its outermost text there, or its outer 10% at a side, holds three lines at most and no hidden text, and repeats at the same edge of a page within 4: its letters and digits the same once a page number at either end is dropped, or, for OCR's misreadings, nine in ten alike; a short one, on two pages. A page number alone, as "12" or "Page 12 of 30", needs no repeat but must agree with the page's own number or a page number nearby, and arXiv's stamp in the margin counts alone. Only pages parsed so far count, so while a file parses a header can show until its neighbours are parsed; the summary line says the read is provisional. The side margin counts only text set sideways (a block taller than twice its width), as arXiv's stamp: an upright margin note that repeats a word is the text's. A block that starts with a raised note marker, `^{2}`, is a footnote, never a header or footer, however alike it is on each page (M2.22). A block of a table, a figure or an equation is never one, so a table's header row repeated on each page of a long table stays the table's.
- A table drawn without horizontal rules, as one of shaded rows, is not found, and its cells read as text; a table of sentences set in the body's size, as some prompts, may end at its first such rows, the rest reading as text. A figure with no numbered caption, or one whose picture is another figure's, as a single image holding two figures, keeps its pictures' markers. A table's notes read as text after its block. Pages read by OCR have no figures, tables or equations: OCR's lines carry no drawing commands. An equation's number at its left, as `leqno` sets it, one PDFKit joins to the next column's text, or one set closer than 1.5 em to the maths before it, is not found, and a display of several rows that PDFKit gives in scraps, as a bracket over three rows, can crop only the rows next to its number. A caption's text follows the reading order, so where PDFKit reads a caption out of order it can start mid-sentence.
- At most 1,000 links a page are kept, and 1,000 other annotations, 100,000 of each kind in a file, 512 KB of text on a page and 32 MB in a file; one annotation that many pages list is kept once. A page that leaves some out says so in one line with the reason, `[10 more annotations on this page, past 1.0k links and as many others, not shown]`, and `pdf info` counts all that were left out. TeX Live's PGF manual holds 44,655 links, which all show on their pages. They are kept per page, and the words under a page's links are read when the page is first read, by a worker, for that page only, so the index does not wait for them and the same file gives the same words however busy the machine is. A link to a page of the file with no words under it is counted in the page's line, not shown; a link to a web address stays, for its address. The words under the first 5,000 marks (highlights and the like) of a file come with the facts. Other annotations, as a sound or a file's icon, show nothing; a link that starts a program is a script, which `pdf info` lists.

Apple OCR reads a scanned page, a page whose text layer is stray marks or broken characters, and every page of a file whose text layer disagrees with its own image. Its blocks carry addresses like any other, and the text layer it replaced shows with `--show raw`, labelled `[PDF text layer]`, whether a scan's old OCR layer or a born-digital page's own text (the summary line counts them as `replaced text layers`). The JSON keeps its old names: the block kind `old-ocr` and `setAside.oldOCRLayers`.

A table appears as a table block in place of its cells, where its caption or its first cell stands: its number, its caption and the command that crops it. The agent reads the cells from the image, and `--show raw` shows the table's flat text, labelled. The first line counts the blocks set aside so.

```text
¶12 [table 3] Forecasting results on multivariate benchmarks. Bold: best.
  crop: pdf crop paper.pdf --page 6 --table 3
```

A figure appears the same way, as a figure block with its caption and the command that crops it; its labels, as a chart's ticks, go aside as `[figure text]`. A numbered equation is a block with its number and its crop, its symbols aside as `[equation text: its layout lost]`, since PDFKit gives a display's lines out of place. The agent reads a table or an equation from its crop and keeps what it read with `pdf transcribe`, below. A figure's alt text, which a tagged file gives for readers who cannot see it, is text a reader of the page never sees: a hidden-text marker after the figure, `alt text, the file's words for a picture`, and its words only with `--show hidden` (F9). An image or a drawing outside every figure and table, such as a logo, a signature or a chart without a caption, gets a marker in place, its alt text marked the same way:

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

The tool rebuilds no LaTeX or table itself, as rules cannot promise them right; what it keeps is the agent's, and the label says so. `--clear` removes a kept reading. With `--dry-run` the command reads the text from standard input, checks it as the real run does, says what it would keep (its size in characters), replace or remove, and keeps nothing.

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

`--notes` and `--refs`, which choose where the cited notes and references show, stay. (`--show raw,hidden,headers` replaced `--raw`, `--include-hidden` and `--headers` in M2.17, and `pdf note` and `pdf ref` replaced `--footnote` and `--ref` in M2.16; the old flags are hidden and end 64 with a pointer. DESIGNS.md → "Decision: `read` reads, `note` and `ref` look up, `--show` shows what was set aside, `doctor` cleans".)

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
| `--show headers` | Brings back the hits on running headers, footers, page numbers and publisher stamps, each labelled `[header]`, `[footer]` or `[publisher stamp]` (`--json`: `runningHeader`). Without it they are left out and counted in the first line, `running headers and footers: 12 hits left out (show: --show headers)` (`--json`: `setAside.runningHeaders`). Any other value ends 64. |

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
- Running headers, footers and page numbers stay in the index, and are judged when a search runs, by the same rule as `pdf read` (F14), against the pages parsed so far (DESIGNS.md → Decision: search judges running headers on the query). Before the pages around a page are parsed, nothing repeats yet, so a header can still show as a hit; the first line then adds a line of its own saying that headers are judged on the pages parsed so far. Only text a read would set aside is left out, so a search and a read of the same pages agree; where the rule is wrong, as for a text that repeats on each page in the footer area, both are. A search by pattern leaves them out after matching, so the 10,000-match cap counts them, and a match that starts in a running header and runs on is left out. When every block that holds all the words is a running header, the answer is no hit and the left-out line, not the some-words fallback, which is for a search where no block at all holds every word. The whole list of hits is judged before `--top` or the budget cuts it, so the left-out count is exact; a search for a word on every page of a long file reads each of those pages (0.9 s for 3,678 hits in 625 pages, release build).

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

`--figure`, `--table` and `--equation` look in the pages parsed so far, and then parse the rest in batches of 40 pages from the start, stopping at the first batch that holds the number, or at 60 s, when the failure says how many pages it searched and to run the command again (the pages stay parsed) or add `--page`; `--page` narrows them to one page, and is needed where two pages hold the same number, as an appendix that numbers its tables again. An unknown number fails with the numbers found, once the whole file is parsed, or, on a long file, with how many pages it searched at the 60 s limit; a batch that began before the limit ends, so the command can take up to a batch longer, still under the 120 s many agents give a command. When a number is found before the whole file is parsed, the output says which pages were not searched (`not searched:`, `--json` `notSearched`), since another figure with that number there would make the answer ambiguous. `--equation` and `--table` also print the LaTeX or Markdown the agent kept, to check against the image, or else the `pdf transcribe` command that keeps it.

The image is in color, and it is sized so small text in a chart stays readable. `pdf crop` prints the absolute path of the image file. The file stays for 7 days, and the same command makes it again after that.

```sh
$ pdf crop paper.pdf --page 2 --bbox 0.08,0.07,0.85,0.3
/Users/me/Library/Caches/pdf-cli/crops/b430b72936d6cf8b/p2-0.08,0.07,0.85,0.30.png  (~1.5k image tokens, 1568×716 px)
```

A region uses the same fractions as the positions in `pdf read --json` and the crop commands in failure blocks, taken on the page as stored, before any rotation; the image comes out upright. A region is rounded outward to hundredths of the page, so it always holds all of what was asked for. An image fits Claude's standard limits, 1,568 px on its long edge and about 1,568 image tokens, so a whole page costs about 1,500 tokens and a small region comes out enlarged, up to 6 times. It shows comments and highlights as a reader sees them. The same crop asked again within 7 days comes from the cache folder at once, and `pdf doctor --clean` removes older ones. `--password-stdin` opens a locked PDF, and `--json` gives the image's path, size and tokens, and the LaTeX or Markdown kept.

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

`--json` lists what was written, with the folder in the same form as the paths (links above it resolved, `/private/tmp/…`). `-o /tmp` and the like are macOS's own aliases and are accepted; any other link as the folder itself is refused. A file is never overwritten: a name taken gets a number. Attachments keep the PDF's quarantine mark. An attachment is saved by the last part of its name alone, with no leading dot and no execute permission, and a name taken gets a number. `--password-stdin` opens a locked PDF for what the file itself must give, `--figures`, `--tables`, `--attachments` and `--scripts`; `--markdown`, `--text`, `--notes` and `--refs` come from the cache of a file added before. A locked file that was added and is dumped without the password ends 3, with the command again as typed plus `--password-stdin`; where `--markdown` or `--text` could write, they are written first.

Gap:
- `-o /tmp` writes into the shared `/tmp` itself, with its own `figures`, `tables`, `attachments` and `scripts` folders: another local user can pre-create `/tmp/figures`, and a link there is refused but a plain folder is not. Give a folder of your own for anything that matters.
- `--html` and `--embedded-images` are not built. A table's PNG carries no notes below it (as F5's gap says). The words of `notes.json` and `references.json` are the text as parsed, with no marker for hidden words. Two figures that share a number on one page give the first one's image twice.
- Attachments and scripts are read by a worker under the usual time and memory limits, so a file that exhausts them loses its attachments and scripts, said so in the output. A stream with stacked filters, or one over 256 MB decoded, is left out and said so; a dump writes at most 1,000 files and 1 GB, and a stream shared by many places is saved once. A launch action is written as a note on what it names, never started. A link in the way of the output folder or its `attachments` and `scripts` folders stops the writing there.

Settings: none.

## F7 — Output basics 🚧

Every command follows the same rules, so an agent learns them once.

- Every block shows its page and its number on the page: a heading such as `## p.12` starts each page, and `¶3` starts its third block. `--json` gives each block's position on the page too, such as `0.10,0.40,0.80,0.30`, and every doubt comes with the command that crops it. The page is its position in the file. When the number printed on the page differs, the page's heading says so, as in `## p.12 (printed 237)`.
- Superscripts and subscripts keep a mark, as in `10^{-5}` and `x_{2}`. Footnote markers and citation numbers have their own marks (see F14 and F15).
- A word that a hyphen splits across two lines comes back whole when the page or macOS's word list knows it. Otherwise the hyphen stays, as in `self-attention`.
- Every command accepts `--json`, and ends with the exit codes of F8. A failure has one shape, `<path>: failed: <reason>`, or `{"file": …, "failed": …}` under `--json`; `path` is the file, or what the command was given (`pdf rm`'s target, `pdf add`'s own path inside its `files` list); a command with no file puts its own name there: `pdf ls`, `pdf doctor`, `pdf setup`, `pdf agent-guide`, `pdf add` and a library-wide `pdf search`. The commands that write say what they did under `--json`: `pdf pick` gives `file`, `page`, `block`, `picked` and `text`; `pdf transcribe` gives `file`, `page`, `kind`, `number` and `kept`, or `removed` with `--clear`, and `sameNumber` when the page numbers several the same; `pdf rm` gives `id` (absent for a file the cache knows that never joined the library), `title`, `files` and `cachedPages`; `pdf doctor` gives what F12 lists, and with `--clean` also `clean`, an object of `removed` (counts), `freedBytes` and `compacted`, with `dryRun` under `--dry-run`; `pdf setup` gives what F12 lists; `pdf ls` gives `documents`; `pdf add` gives `files`, one object for each path, with `id`, `title`, `pages` and `flagged` or, in the failure shape, `failed`, and the counts `added`, `flagged` and `failed`; `pdf reparse` gives what F10 lists; `pdf agent-guide` gives `guide`, or with `--install` `file`, `installed`, `warnings` (the text's warnings, word for word, with the `this one is …` detail) and `hint` (the `/reload-skills` line of the text, absent when the skill was up to date). The commands that change what is kept (`pick`, `transcribe`, `rm`, and `doctor` with `--clean`) take `--dry-run` (DESIGNS.md → Decision: a dry run answers from what is kept and never parses): the text starts `dry run: `, the object holds the real run's keys and `"dryRun": true`, and the exit code is the real run's. It changes no row, schema or file content of either database, the cache's log included; it opens both read-only, and SQLite may still create or touch the cache's shared-memory index (`-shm`), which holds no data. It parses nothing and starts no runner, so it answers only from what the cache holds: for a file or page not cached for this version of the file and of `pdf` it fails, exit 1, naming the `pdf read` to run (the one case where its exit code differs from the real run's); a cache from an older schema, or one SQLite cannot open read-only, fails the same way in one sentence. Besides the real keys, a dry run's object holds, always, `replaces`: `pdf pick` gives the letter of the pick it would replace (the same letter when it is picked again), `pdf transcribe` the day of the reading it would replace, each null when there is none, and `characters` (the size) when it keeps; `pdf rm` gives `picksKept`, `transcriptsKept` and `sharedWith` (the other files whose results stay).
- Output starts with a one-line summary: the pages read, the pages flagged and what normal output set aside.
- A file that macOS Preview or another app saved through PDFKit carries a warning in its summary line: such a save can damage the text, and an earlier copy may read better.
- Nothing is dropped without a trace. What normal output sets aside leaves a marker in place, or a count in the summary line, with the flag that shows it: `--show raw` for doubtful text, `--show hidden` for hidden text and `--show headers` for running headers, footers and publisher stamps.
- `--budget N` stops the output at about N tokens, between blocks, and ends it with a line that continues the read, such as `next: pdf read paper.pdf --from p4.27`. A text block larger than the whole budget is cut inside, and the next read goes on from the cut. A failure block, or text shown with `--show raw`, larger than the budget goes out whole, so every read moves on. `read` and `search` stop at 5,000 tokens by default, about 5 pages of a paper, and `--budget all` turns the limit off.
- While a document is still parsing, the summary line says `provisional`, with how many pages are parsed so far, because headings and note numbers can change once the whole document is known.

Gap: a search whose pattern runs too long (`--regex`, past 10 s) still stops with an `Error:` line on standard error and exit 1, not in the failure shape.

Settings: none.

## F8 — Failure reports 🚧

Makes every failure loud, and tells the agent how to read the page instead.

When a page fails to parse, or reads below the quality bar, its text is replaced by a failure block:

```text
⚠ p.1 low-quality: two OCR readings of the page disagree (score 0.78)
  read it as an image: pdf crop scan.pdf --page 1
  raw: pdf read scan.pdf --page 1 --show raw
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

When only one block is in doubt, only that block is replaced, and the rest of the page reads normally. Text PDFKit left out has no block: a failure block for each place, at most 20 a page, numbered after the page's blocks, gives a crop command for it. What its strings spell never goes out, even with `--show raw`: the check of what a reader sees there cannot tell every way of hiding a string, and a font with no text map need not spell what it shows. So a string hidden in a way the check misses, as white text between two lines or a line squeezed by its text matrix, can flag its page and cost a crop, but its words stay out. A dashed arrow or a symbol of display maths that PDFKit leaves out, drawn as 3 letters or digits or more, flags its page too. A word PDFKit leaves out inside a line it keeps goes unflagged where PDFKit lays the next words' boxes over it, as it does for a Type 3 font with a font descriptor. A page whose drawn text PDFKit left out by 30% or more is read by OCR instead, where OCR reads clearly more. A damaged part of a page has no block either: a content stream that declares 64 bytes or more and holds no operator, as one whose filter its data does not match, which macOS draws as nothing and reports nowhere. One failure block after the page's blocks says so, with no command, since the page's image lacks it too; on a page in doubt as a whole, it goes with the page's failure block. A stream damaged partway, which still gives operators, a damaged form the page draws, a stream whose length is missing or no number, and the streams of a page with no resources go unflagged. The crop command covers the smallest region that holds the doubt, with the lines around it: a few lines, a paragraph, a table or the whole page. A small crop costs the agent fewer image tokens and stays sharp.

When two readings of a word differ in where its words break, the paragraph keeps the text layer's reading, and an unsure block after it shows both, limited to the words that differ:

```text
⚠ p.2 ¶5 unsure: two readings differ
  [a] CTRLperforms … overallshift
  [b] CTRL performs … overall shift
  pick: pdf pick paper.pdf p2.5 a  (or b)
  look: pdf crop paper.pdf --page 2 --bbox 0.11,0.40,0.39,0.06
```

Reading [a] is the text layer's. Reading [b] breaks the words where Apple OCR does, or splits letters that both readers run together into common English words, as in "single dataset per condition". English words run together that no reading splits, as when a line-end break cut one, get an unsure block with their one reading and a `look:` crop. Names from code and web addresses, such as `SpaceRepairRelocate`, stay as they are.

`pdf pick paper.pdf p2.5 b` saves the agent's choice for page 2, paragraph 5. Later reads show the chosen words in place, labelled `[picked 2026-10-15]`, and `pdf reparse` keeps a pick while the page it reads again still offers the readings the pick was made for, and clears it when the readings differ. `--dry-run` says what the pick would keep, and whether it replaces an earlier one, and keeps nothing. A pick takes only one of the readings shown, for every unsure word of its paragraph. When two readings differ in digits, table cells or formulas, the passage comes as a failure block with a crop, because the text alone cannot show which reading is right. `--show raw` shows both readings.

- The summary line at the top counts every flagged page, with its status: `failed`, `low-quality` or `unsure`. It also counts what normal output set aside, such as doubtful blocks and a scan's replaced text layer, with the flag that shows them.
- A low-quality page is flagged the same way as a failed one, with its reason and its score.
- A file that PDFKit cannot open fails as a whole, in one line that names the reason: not a PDF, damaged, locked by a password, or slow to open, past 90 s. A file slow to open gives commands that verdict for 10 minutes, and then a command tries it again. A locked file points to `pdf add <path> --password-stdin`; `pdf crop`, and the parts of `pdf dump` that draw or open the file (`--figures`, `--tables`, `--attachments`, `--scripts`), end 3 for a locked file that reads from the cache, and for any other file that does not open, and name the command again as typed plus `--password-stdin`; with a wrong password they say the password does not open it instead. A path under macOS's aliases `/tmp`, `/var` and `/etc` is kept without `/private`, whether or not the file exists (`pdf rm /private/tmp/x.pdf` finds the entry `/tmp/x.pdf` after the file is gone). `pdf transcribe` checks the file before it reads standard input.
- A page whose content stream (also a form, a glyph procedure or a pattern) holds more than 20 million drawing operators, as one built to inflate 1,000 times, fails at once, in about a second and a few megabytes: `failed: too many drawing commands to read: …`, with the crop command to read it as an image. A stream of few operators that inflates past the memory limit is still stopped by that limit.
- The exit code tells success from failure:

| Exit code | Meaning |
|---|---|
| 0 | Every requested page read well. `info`, `search`, `crop` and `dump` of a file with flagged pages also end 0 and name the pages in their output. `doctor` and `setup` end 0 whatever they find: `doctor` lists its problems, and `doctor --clean` ends as the clean did. |
| 1 | The command could not run, such as on a file that does not exist (every command: `<path>: failed: no such file`), or when it could not write what it was asked to. |
| 2 | Some pages failed, are low-quality or hold unsure words. The rest of the output is valid. Only `read`, `add`, `reparse` (also when it stopped at its time limit, or after some chunks, before the last page) and `dump` (when the document it writes has flagged pages) end with it. |
| 3 | The file failed to open (not a PDF, locked, damaged), on every command that takes a file, or no requested page holds text to show: each one failed or is in doubt as a whole. |
| 64 | The command was used wrongly, such as with an unknown flag. The parser ends with it, and prints the usage. |

`pdf add` of several paths ends 2 when some failed or some pages are flagged, 3 when every path failed and one of them failed to open, and 1 when none could be tried (every path missing). `pdf dump` ends 1 when it could not write to its folder (a link in the way, also for figures, tables and attachments), else 3 when its `read` of the document failed, else 2 when the document has flagged pages; the files it did write stay, and its output lists them with a note for each that was not written. A look-up that matches nothing (`pdf read --section`, `--printed-page`, `pdf note`, `pdf ref`) is a failure in the one shape, exit 1, listing what exists (M2.16).

Gap:
- The blocks reach the agent once `pdf read` is built (M1.7). Until then, the hidden `pdf debug-read` shows them. Their crop commands work once `pdf crop` is built (M1.9), and `pdf reparse` reads a page again (F10).
- An uncertain reading order is not checked yet: the check and its threshold wait for the final wrap-up, with M2.12's tuning.
- The word lists that back second readings are English, so words in other languages get none.

Settings: none.

## F9 — Hidden text 🚧

Marks where a reader's eye would miss text, and keeps that text's words out of the agent's way until it asks.

Text that renders invisible, such as text in the color behind it, tiny text, clipped text, text covered by an image, a shape or an annotation, text off the page or text in a layer switched off, is replaced by a marker in normal output. The marker sits where the text sat, and gives its size, how it was hidden and the command that shows it:

```text
¶3 Visible start of a line, [hidden: 3 words, in the color behind it · show: pdf read paper.pdf --page 1 --show hidden] visible end.
```

White text on a dark box stays in, because a reader can see it. The summary line says how many hidden places the output marks, and on which pages. `--show hidden` shows their words in place, each labelled with its reason, as in `[hidden, in the color behind it: …]`. The text layer on a scanned page is read normally. A hidden run is words, so a run of fewer than 3 letters or digits stays in. Hidden words stay out of `pdf search`, by keyword and by pattern, and out of the title and sections `pdf info` finds.

Very faint text, under a contrast of 1.3 to 1 with what lies behind it, as #EEEEEE on white, counts as hidden; pale grey such as #D9D9D9 reads as text. A page where the check stopped at a limit says so in place.

A picture's alt text, the words a tagged file gives for readers who cannot see the picture, is hidden text too: a reader of the page never sees it, so a hostile file can plant a line there. A figure, or a picture outside every figure, whose drawing the file's structure tree gives alt text, carries a marker, `[hidden: 12 words, alt text, the file's words for a picture, which the page does not show · show: …]`, counted with the page's hidden places, and its words only with `--show hidden`. It is found through the marked content the page draws the picture in, so alt text on a structure element that marks no drawing on the page, or only text, or a drawing too small to be a picture, is not read; at most 1,000 characters a picture, and past 5,000 marked drawings on a page the page says its check is incomplete. The page's cache key holds the alt text, so a file that gains it is parsed again.

A page read by OCR, as a scan is, or by `pdf reparse --step ocr`, keeps its hidden text hidden too: OCR reads what PDFKit draws, which includes text under an annotation and in a layer switched off, so each OCR line that lies over words the page's text layer hides, or over a string of text PDFKit leaves out that a rendering draws and no reader sees (in a layer switched off, or under an annotation), goes under the same marker, and stays out of search.

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
- A string in a form switched off, nine forms deep or more, is out of the check's reach: a page read by OCR says its check is incomplete, and the string reads as text.
- A line OCR reads that holds a hidden word among visible ones, as a word whited out by an annotation inside a line, goes under the marker whole, since OCR gives no box for a word: `--show hidden` shows it.
- Text in a layer switched off that PDFKit's text holds, drawn over a visible line, as the language layers of layered manuals are, reads as plain text, with no OCR: the layer's words are not marked unless a form or marked content switched off holds them in a way the drawing check finds. `pdf crop` draws such a layer through PDFKit, so a crop shows it.
- A layer a viewer hides by its usage alone, as one for print only, reads as text: macOS's viewers show it, and only Acrobat applies the usage. So does content whose visibility expression nests past 32 levels: its layers decide.

Settings: none.

## F10 — Reparse 🚧

Reads pages again, with the usual method on the running macOS or with a stronger one.

| Command | What happens |
|---|---|
| `pdf reparse <path>` | Reads every page again with the usual method, and replaces the cached results. `--page 7` limits it (`3`, `3-5`, `3,7-9`, as `pdf read` takes them). |
| `pdf reparse <path> --page 7 --step ocr` | Reads page 7 again with the Mac's OCR, and replaces the cached result. `--step` takes `ocr` only; without `--page` it reads every page by OCR. |
| `pdf reparse <path> --password-stdin` | Opens a locked PDF, as `pdf add` does (`--password` too). A locked file that already reads from the cache keeps its results when the password is missing or wrong, and the failure line names this command. |

It prints one summary line, the pages replaced, how many kept their old result, how many are flagged now, how many changed status, the picks it kept (the page offers the same readings) and the picks it cleared (it offers other ones) and the file, then the flagged pages and the pages that changed, `p.7: low-quality -> ok` or `p.4: ok, text changed`, at most 20 of each, ending `and N more`. `--json` gives `file`, `id`, `step` (`usual` or `ocr`), `reparsed` and `pages` (the pages replaced), `flagged`, `flaggedPages`, `changes` (`page`, `before`, which is null for a first reading, `after`, `textChanged`), `kept` (`page`, `reason`), `picksKept`, `picksCleared`, and `neverRead`, `changedSinceRead` or `toolUpdated` when they hold; page numbers are numbers. It ends 0, 2 when a page it read is flagged or kept its old result, or it stopped at the time limit before the last page, 3 when none of those it replaced reads, 1 for a missing file or a page past the end, and 64 for a wrong flag or an unknown `--step` (the exit codes of F8).

- **Picks stay while they apply, transcripts stay.** After each chunk is replaced, a pick on its pages stays if its paragraph still offers the same readings, the rule a read applies a pick by, and is cleared if not; a page that kept its old result keeps its picks. The summary and `--json` count both (revised 2026-10-25, M2.23; a reparse used to clear every pick). A transcript (F3) is kept by the page's key, which a reparse does not change, so it shows again at once, beside the new reading.
- **Replaced a chunk at a time.** The pages go in chunks of 50. The old results of a chunk stay until every new one of it is in, then the chunk is replaced in one step, with the keyword index (F4) following. A command that is stopped, or a Mac that loses power, half way keeps the chunks it finished and leaves the old results in the one it was on; a file of more than one chunk prints `reparsed N of M pages` on stderr as each is done. A page whose new reading fails keeps its old result, which reads well: the summary counts it (`1 kept the old result`), a line names the page and the reason, and the command ends 2. A page with no good result takes the failure.
- **Big files stop at 90 s.** No chunk starts after 90 s, under the 120 s that many agents give a command. As measured, 231 pages plain take about 18 s, OCR about 0.4 s a page (about 200 pages fill 90 s) and pages whose fonts lose spaces about 0.3 s. A run that stops there ends 2 with `stopped at the time limit of 90 s with N pages not read` and the command that reads them, `pdf reparse <path> --page 151-300`; `--json` gives `remaining` (the pages) and `next` (the command). The chunks before it stay replaced. A chunk that began before the limit ends, so the command can take up to a chunk longer (about 25 s for OCR), under 120 s. An error after some chunks (the parser stopped, another reparse kept it waiting) ends the same way, `stopped: …` with the pages not read, and the picks of the chunks replaced are already settled. No progress lines come under `--json`.
- **Gentle.** It reads through the shared pool of workers, as `pdf add` does, but never in the pool's first slot, which stays free for the first page of a file another command waits on, and leaves nothing parsing when it returns: a file never read has only the pages asked for parsed.
- A file never read is just parsed, and the line says so. A file changed since it was read, or while it was read again, is read in its current version, and the line says so; a file that an older `pdf` indexed is indexed again, and the line says that. A file that failed to open is tried again.

Gap:
- A page's key stays, so a copy of the file, or another file with a page that draws the same, shares the new result and loses its picks too. `--step ocr` on a page that has a text layer stores the OCR reading under that key; the layer's reading comes back with a plain `pdf reparse`.
- It reads pages only: the file's facts (outline, links, annotations) and the sample check that decides whether a scan is read by OCR stay as the first read left them.
- `--step ocr` reads what PDFKit draws, which includes text under an annotation and in a layer switched off; such text stays under its `[hidden: …]` marker, found from the text layer's own words (F9). Text PDFKit leaves out of its text is found from the page's drawing commands (strings in a layer switched off, or with ink in the page drawn without annotations and none in the page as a reader sees it) and stays under its marker too (M2.19, parser version 20); the limits are F9's Gap.

Settings: none.

## F11 — Library ✅

Shows and cleans up what the tool has cached.

| Command | What happens |
|---|---|
| `pdf ls` | Lists every PDF in the library, with its ID, title, page count, flagged pages and path (`--json`: `documents`). A PDF not fully parsed shows how far it is. A file that is gone shows `file missing`, one changed since it was read says so, and one on a drive not plugged in shows as out of reach. |
| `pdf rm <path or ID>` | `--json`. `--dry-run` says what would go and what would stay, and removes nothing. Removes one PDF from the library and its results from the cache. Results that another copy of the file still uses stay, and so do the agent's picks, which show again if the PDF comes back. |
| `pdf doctor --clean` | Took over `pdf gc` (F12). `pdf gc` itself is gone: it ends 64 and names this command. |

Parse results and crop images live in `~/Library/Caches/pdf-cli/`. The library list, picks, transcripts and memos live in `~/Library/Application Support/pdf-cli/`. The cache keeps every parse result until `pdf rm` or `pdf doctor --clean` removes it, and `pdf doctor` shows its size. A macOS update leaves cached results as they are, and `pdf reparse` reads a file again on the running macOS.

Settings: none.

## F12 — Setup and doctor ✅

Gets the tool ready, says what works on this Mac, and cleans up.

| Command | What happens |
|---|---|
| `pdf setup` | Asks the user how much memory parsing may take: `light` (one worker), `balanced` (what the Mac does when nothing is set) or `fastest` (a worker for each performance core), each as workers of 2 GB, so the numbers are shown for this Mac (a Mac with 6 performance cores: 2, 6 and 12 GB), or a size such as `3GB`, `3072MB` or `1TB`. It asks only at a terminal; with `--memory light\|balanced\|fastest\|<size>\|default` it does not ask, and with neither it changes nothing and shows the setting, so an agent's shell never waits. A bare number is megabytes, and one under 64 is refused with a hint to add the unit; 512 MB is the least and 1 TB the most; hex, exponent and signed forms are refused. `default` clears the setting. `--json` gives `memoryMB` and `preset` (null when not set), `workers`, `workerLimitMB`, `performanceCores`, `changed`, `prompted`, `file`, `overriddenBy`, `warnings` and `models`; every key is always there. It also lists the models to download: today there are none, and it says so. |
| `pdf doctor` | Shows the macOS version and what a newer one would unlock, the parser version, the models installed, the size and counts of the cache and the library, the parsing settings in force with where each comes from, what runs now, and the problems it found. It changes nothing and parses nothing, and ends 0 and lists its problems, as `info`, `search` and `crop` do. A state that the next normal command repairs is a `note`, not a problem: a cache of an older schema, a cache whose log files are gone, a cache a cut-off run left half written. A problem is something only the user can fix: a cache or library SQLite cannot open (it names the next step), a library entry for a file that no longer exists, a leftover runner lock, a settings file that is not valid or cannot be read, a folder it cannot read. `--json` gives `macOS`, `parserVersion`, `models`, `cache`, `library`, `parsing`, `running`, `cleanable` (what `--clean` would remove now), `missing` (each missing piece and what it would unlock), `problems`, `notes` and `fixedByClean` (the problems `--clean` fixes); a value that is not set is null. |
| `pdf doctor --clean` | Took over `pdf gc`. Removes cached results for files that no longer exist or changed and for old parser versions, the library entries of files that no longer exist, the locks of runners that are gone and crops older than 7 days; a file on a drive not plugged in keeps both its results and its entry. A lock is left over only when its process is gone or its heartbeat is ten minutes old: a runner that was stopped keeps its lock and its cache. Then it rebuilds the cache to give space back, if no process holds a lock, and prints what it freed ("compacted the cache, freed X"; the space includes what rows removed earlier left, so it can be above 0 when the counts are 0). It ends 0, or 1 when it could not run. `--json` adds `clean`: `removed` (counts), `freedBytes`, `compacted` and `parseRunning`. |
| `pdf doctor --clean --dry-run` | Says what `--clean` would remove, and changes nothing: both databases open read-only, nothing is parsed, and the exit code is the real run's (DESIGNS.md → Decision: a dry run answers from what is kept and never parses). Its `freedBytes` is a floor: the crop images and the free space in the database now. A cache from an older schema, or one SQLite cannot open read-only, fails in the one failure shape, exit 1, naming a normal command to run first. `--dry-run` alone is a usage error, 64. |

What the macOS version unlocks, as the code uses it: before macOS 26 a scanned page is read by Apple's older text recognizer, and pdf groups its lines into paragraphs by position, where macOS 26's document recognizer returns paragraphs itself and finds word breaks a little better; before macOS 13 OCR reads English, French, Italian, German, Spanish, Portuguese and Chinese, with no Japanese, Korean or language detection. The doctor says only these; it says nothing of tables, which go to the agent as crops on every macOS.

Parsing's memory is stored in `settings.json` in the agent's folder (`~/Library/Application Support/pdf-cli/`), where `Env` reads it for every process (DESIGNS.md → Decision: parsing's memory in `settings.json`, and `doctor --clean`). If that file is a link, `pdf setup` writes through it, and `--memory default` writes an empty object through it instead of deleting the link or its target. Only a file that is not there means nothing is set: one that cannot be read, is not valid or holds a size outside 512 MB to 1 TB is a problem in `doctor`, and the defaults hold. The workers' limits add up to at most the budget: the count is the budget over 2 GB, at least 1 and at most the greater of 2 and the performance cores, and a worker is stopped at 2 GB, or at the budget when that is smaller. Until `pdf setup` runs, the pool is what it was: half the performance cores, at least 2, each with 2 GB, which is exactly `balanced`, so the unset default is never above `fastest` or below `balanced`. Two things differ from before for every Mac: the pool runs fewer workers when macOS reports memory pressure, a hot Mac or Low Power Mode (half; one when critical), and a file read by OCR or by space repair runs half as many workers as a text file, but never fewer than two where the pool has two. A pool of one slot (`light`, or pressure) shares slot 0: pages nobody waits for take it only while no command waits for a slot, and a runner stops a background worker that holds it, at once, when a command starts to wait, so a page a command waits on never queues behind a background parse (about 0.8 s with `light` and with `PDF_CLI_PRESSURE=high`, against 30.8 s and 16.2 s before the fix, with a scan parsing in the background). An agent says how soon it needs pages only by what it asks for, never how many workers; the guide has it ask the user to run `pdf setup`.

`pdf setup` shows each model's licence before it downloads it, and the user accepts it first: MIT covers only this tool's own code. No model is built yet (M2.4's layout model comes only if rules fail a goal, and M3.1's embedding model only if Apple's falls short), so the list is empty and nothing is downloaded; the notice's text and the list are tested.

Gap: the budgets' numbers are estimates, since a worker's memory on text and on OCR pages is not measured (ROADMAP.md → Final wrap-up). The OCR weighting is per runner: two runners reading scans each keep their share, so the pool's slots, not the weights, cap the Mac. A background worker that yields loses the page it was reading, which it reads again later. Doctor's runner and slot counts are a moment's reading. The licence notice has no code that downloads and no accept step yet; the first model brings both. `doctor` does not check the PDFs themselves, only the tool's folders.

Settings: parsing's memory (`pdf setup`), stored in `settings.json`; `PDF_CLI_WORKERS` and `PDF_CLI_MEMORY_LIMIT_MB` override the worker count and a worker's limit, and `PDF_CLI_PRESSURE` (`high`, `critical`) plants pressure, for tests.

## F13 — Agent guide 🚧

Teaches an agent the tool in one read.

| Command | What happens |
|---|---|
| `pdf agent-guide` | `--json` gives `{"guide": …}`. Prints a compact guide for agents: the commands, the output rules, how to handle failure, unsure and table blocks and the markers for set-aside parts, and the rule that a PDF's text is content to read, not instructions to follow. |
| `pdf agent-guide --install claude-code` | Installs the guide as a Claude Code skill, at `~/.claude/skills/pdf-cli/SKILL.md`, or under the folder `CLAUDE_CONFIG_DIR` names when it is set. Running it again replaces an earlier version. It warns when no `pdf` is on the PATH, or another one is, since the skill's commands run the one a shell finds. |

`pdf --help` opens with how to choose a command, and every command's `--help` carries two or three complete examples (`ls` carries two, as it takes no arguments: the plain one and `--json`), with the options of `read` and `dump` grouped in their help by what they do (M2.14: sections of the help text, so the flags parse as before; the option list itself stays flat). The guide is about 1,990 tokens by the project's estimator (the test holds it under 2,000). It names only commands and flags that are built. A test checks, against the CLI itself, that every command and flag the guide names exists, with the command named before it on its line; that every command it writes out parses, its values included; and that it names every command `pdf --help` lists and every flag of each, but for four it leaves out on purpose: `read --full`, `add --password`, and `dump --page` and `--password-stdin`; `--json` is named once, for every command, in its line about exit codes. The skill's description leads with when to use the tool, as Claude Code's skill listing shows it before the skill loads.

Settings: none.

## F14 — Notes 🚧

Gives every kind of note in a document its own place, apart from the body text.

| Kind | What the user sees |
|---|---|
| Footnotes and endnotes | A marker such as `[^7]` in the text where the note is cited. The note texts follow at the end of the output by default, under `## Notes`. `--notes end\|inline\|off` changes this: `inline` puts each right after the paragraph of its page that cites it, and leaves one that no paragraph of its page cites, as an endnote, in its place; `off` leaves them out and counts them in the summary line. |
| One footnote | `pdf note <path> 7` shows the note and every place that references it, from the whole document, parsed first; it is not paged and not held to the budget, and takes `--json`. When numbering restarts in each chapter, the ID includes the series, as in `pdf note <path> 3.7`. A note that is not there, or an ID that names notes of several series, fails as `<path>: failed: no footnote or endnote is 99; it has *, 1, 2`, exit 1, listing the IDs that exist. |
| Headnote | A block labelled `[headnote]`, in place, at the start of its article or chapter |
| Running headers, footers and publisher stamps | Left out of the text, counted in the summary line and listed once by `pdf info`. `--show headers` keeps them in place. |
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

`pdf info` counts them: `notes read apart from the text: 12 footnotes, 3 margin notes (pdf read --notes end|inline|off; pdf note <pdf> ID)`, and lists the author notes as `author notes: [^*] Equal contribution.`. `--json` gives a note as a block of kind `note` with its `id`, its `status` (`footnote`, `endnote` or `author note`) and, for one listed after the text, its `place`.

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

`pdf info` counts them: `references: 46 entries, the list on p.9 (pdf ref <pdf> ID; pdf read --refs end)`. `--json` gives an entry that `--refs end` lists as a block of kind `reference` with its `id` and `place`, and `pdf ref` as the entry, its DOI and the places that cite it; `pdf crop --json` gives `mentionedOn`.

Settings: none.

Gap:
- Lists, entries and citations are found by rules, with no model, and judged when a page is read, against the pages parsed so far, as notes are (F14). On a first read of a file whose list is on a page not parsed yet, raised citations stay raised and `--refs end` lists nothing; the summary line says the read is provisional and, with `--refs end` and no entry listed yet, that no list was seen in the pages parsed so far (it does not parse the list's pages first), and `pdf ref` parses the whole file first.
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
| Table cells as text, CSV or Markdown | A rebuilt cell can be wrong and still look right, and the agent trusts it. Each table goes to the agent as an image instead, and `--show raw` shows its flat text, labelled as having lost its rows and columns. |
| A PDF parser or renderer of our own | Apple and Google maintain theirs. Ours would take years, with no difference a user could see. |
| A reading app with a window | Agents call commands. simple-pdf already covers a reader with a window. |
| Cloud parsing | Documents stay on the Mac. A hard page goes to a local model or to the agent's own image understanding. |
| Running PDF JavaScript or actions | Reading needs none of it, and running it is a security risk. |
| Translation | The agent translates. The tool hands it the text. |
