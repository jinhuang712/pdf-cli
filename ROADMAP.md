<!-- what-we-build: drafted 2026-10-18 -->
# Roadmap

**Current milestone:** M1. An agent reads born-digital and scanned PDFs through the cache.

## Overview

- ✅ **M0 — Spike.** Proven: Swift and Apple's engines carry the design. About 2 weeks.
- ⬜ **M1 — Daily reader.** Usable: an agent reads born-digital and scanned PDFs through the cache, with keyword search and page crops. About 5–7 weeks, after M0.
- ⬜ **M2 — Accurate layout.** Proven: two-column papers, footnotes, citations and figures read right. About 2–3 months, after M1.
- ⬜ **M3 — Complete.** Usable: search by meaning, tables across pages, formulas and a one-command install; then a final wrap-up of detailed tests and tuning. About 1–2 months, after M2.

Each milestone groups its tasks by feature, in the order the tasks are built. A feature's number points to [FEATURES.md](FEATURES.md), and "Later" names the task that finishes it. A task's ID, such as M1.1, names its branches and commits.

## M0 — Spike ✅

The spike shipped no features. It answered the riskiest questions.

- **Build**
  - [x] M0.1 A Swift package with a `pdf` command, built as one universal binary. `scripts/build-universal.sh` builds each architecture and joins them with `lipo`, because a one-step universal build needs Xcode.
- **Text**
  - [x] M0.2 Text from PDFKit and from PDFium on 10 sample PDFs, compared side by side. PDFKit is the text source, with an Apple OCR repair for fonts that hide spaces.
  - [x] M0.3 Apple's document recognizer run on rendered born-digital pages, with its reading order checked by hand. It reads scans and repairs spaces, and PDFKit stays the main text source.
- **Layout**
  - [x] M0.3b Figures found from PDFKit text and drawing commands, without a model: 54 of 54 figures on 116 pages, at about 9 ms per page.
  - [x] M0.4 One layout model converted to Core ML and timed on the M3. Docling's heron and egret-medium convert, under Apache-2.0, at 15–29 ms per page. Both stay out of the default until a goal needs one.
- **Project**
  - [x] M0.5 The answers to M0.2–M0.4 recorded as decisions in DESIGNS.md, on 2026-10-15.
  - [x] M0.6 The binary's name, checked against Homebrew and common tools for a clash: `pdf`, chosen 2026-10-14. Homebrew's core catalogue has no formula named `pdf` or `pdf-cli`.
  - [x] M0.7 The repo's licence: MIT, chosen 2026-10-14.

**Exit criteria:** DESIGNS.md → Open questions on the text source, the reading order and Core ML conversion are answered, and GOALS.md G2 holds on the 10 sample PDFs.

✅ Met 2026-10-15. The three questions became dated decisions in DESIGNS.md. For G2, the full text of a file plus the figures on page 1 took at most 0.30 s per file on the 10 arXiv papers, timed three times each by a helper agent that did not write the code. The real `pdf read --page N` is not built yet, so G2 stays open in GOALS.md.

## M1 — Daily reader ⬜

- **Under the hood:** what every feature below stands on
  - [x] M1.1 Worker processes with time and memory limits, and results cached in SQLite by page content
  - [x] M1.2 The text layer, with ligatures, hyphenation and Unicode cleaned up, the font check, and the space repair for at-risk files
  - [x] M1.4 Apple OCR for scanned and garbled pages
  - [x] M1.15 One pool of worker slots for the whole Mac, with pages nobody waits for parsed in the background
- **Failure reports** (F8): every bad page says so
  - [x] M1.3 Quality checks on every page, failure blocks with crop commands, unsure blocks with `pdf pick`, and `--raw` for the text they set aside, the old OCR layer of a scan included, plus the warning on files that PDFKit saved
  - Later: thresholds tuned on the open test set (M2.12)
- **Add** (F1) and **Library** (F11): adding, listing and cleaning up
  - [x] M1.5 `pdf add`, `pdf ls`, `pdf rm` and `pdf gc`
- **Info** (F2): the outline, page labels and section sizes
  - [x] M1.6 `pdf info` from bookmarks, page labels and the text layer, with the counts of comments, highlights and form fields, and the list of attachments and scripts
  - Later: the figure list, with figure detection (M2.6)
- **Read** (F3) and **Output basics** (F7): by page, printed page and section, with nothing dropped without a trace
  - [x] M1.7 `pdf read`, with addresses, `--json`, the budget, the provisional mark, and the marks for superscripts and subscripts
  - [x] M1.13 Comments, sticky notes, highlights, filled-in form fields and link targets, each at its position
  - [x] M1.14 Every image and drawing marked in place, with its crop command
- **Search** (F4): by keyword and by pattern
  - [x] M1.8 `pdf search` by keyword and with `--regex`
  - Later: search by meaning (M3.1)
- **Crop** (F5): whole pages and regions
  - [x] M1.9 `pdf crop` for pages and regions
  - Later: figures, tables and equations (M2.6)
- **Hidden text** (F9)
  - [x] M1.10 Hidden text replaced by a marker in place, with its words shown on request, text in layers switched off included
- **Agent guide** (F13)
  - [x] M1.11 `pdf agent-guide` and its Claude Code skill
- **Tests**
  - [x] M1.12 A smoke set of 10 PDFs, and a safety set of broken PDFs and hidden-text PDFs. The safety set holds one hidden-text PDF per trick: text in the background's color, tiny, clipped, covered by an image, off the page and in a layer switched off, plus white text on a dark box, which counts as visible. It also holds PDFs with comments, form fields, links, attachments and scripts.

**Exit criteria:** GOALS.md G2, G4, G9, G12, G13, G16 and G17, plus the author's own report after one week of daily use.

## M2 — Accurate layout ⬜

- **Tests:** M2.1–M2.3, the sets the accuracy goals are measured on, wait for the final wrap-up, below.
- **Under the hood**
  - [ ] M2.4 The layout model running on Core ML, only if a goal fails with rules alone. See DESIGNS.md → the decision on rules over a default layout model.
  - [x] M2.5 Reading order across columns, with running headers, footers and publisher stamps set aside, counted in the summary line and shown with `--headers`
- **Crop** (F5) and **Info** (F2): figures, tables and equations
  - [x] M2.6 Figures, tables and equations detected, listed by `pdf info` and cropped with `pdf crop`. Each table's and figure's text gives way to its block and stays behind `--raw`, and alt text shows with its figure. Found from numbered captions, M1.14's pictures and drawn shapes, and horizontal rules; an equation from its number set apart. Alt text is hidden text, shown only with `--include-hidden` (the user, 2026-10-17).
  - [ ] M2.13 Equations as LaTeX, read by the agent: it reads an equation's crop and writes the LaTeX back with a command, as `pdf pick` saves a choice; the cache keeps it with the page, so later reads show the LaTeX in place, labelled as the agent's reading, with no crop. The tool rebuilds no LaTeX itself (the user, 2026-10-18). See DESIGNS.md → "Decision: the agent reads figures, tables and equations from their crops, and its LaTeX is kept".
  - Later: tables that continue across pages (M3.2)
- **Notes** (F14)
  - [ ] M2.7 Footnotes, endnotes, headnotes, margin notes and author notes
- **Citations and references** (F15)
  - [ ] M2.8 Citations, references and cross-references
- **Dump** (F6)
  - [ ] M2.9 `pdf dump`, with attachments saved and scripts written as text, never opened or run
- **Reparse** (F10)
  - [ ] M2.10 `pdf reparse`, plain and with `--step ocr`
- **Setup and doctor** (F12)
  - [ ] M2.11 `pdf setup` and `pdf doctor`, with the licence notice of every model `pdf setup` downloads: MIT covers only our own code. `pdf setup` asks how much memory parsing may take, as light, balanced or fastest with their numbers, or a number; the worker count follows from it and the cores, OCR pages weigh more, and fewer workers run under memory pressure. An agent says how soon it needs the pages, never how many workers. See DESIGNS.md → "Decision: the user sets parsing's memory, the tool the worker count".
- **Failure reports** (F8): M2.12, the quality thresholds tuned until G11 passes, waits for the final wrap-up.

**Exit criteria:** GOALS.md G3, G5, G6, G7, G8 and G11, measured at the final wrap-up.

## M3 — Complete ⬜

- **Search** (F4): by meaning
  - [ ] M3.1 The embedding model chosen, and `pdf search` by meaning, Chinese queries included
- **Crop** (F5): tables across pages
  - [ ] M3.2 Tables that continue across pages, linked as one table with a crop per page
- **Install**
  - [ ] M3.5 A Homebrew release that installs with one command
**Exit criteria:** GOALS.md G1, G10, G14 and G15, measured at the final wrap-up.

## Final wrap-up ⬜

Until every milestone is built, each task gets its unit and end-to-end tests and one quick review; the detailed tests, measurements and tuning wait for here (the user, 2026-10-17).

  - [ ] M2.1 The open test set: 60 open-access PDFs, labelled, from the local set in `private/testset/`, which stays out of git
  - [ ] M2.2 The question set: 200 questions, each with its answer and page
  - [ ] M2.3 A scorer that weighs a wrong block 3× a missing one, and a Docling baseline run on the same Mac
  - [ ] M2.12 The quality thresholds, tuned until G11 passes, and the check for an uncertain reading order, which waits for that tuning (moved from M2.5, 2026-10-17)
  - [ ] M3.6 The question set run in Claude Code with pdf-cli and with the built-in Read tool, which measures G1 and G15
  - [ ] Each worker's memory, on text pages and on OCR pages, which sets the budgets `pdf setup` offers; and how fast OCR runs one, two or three at a time
  - [ ] Every goal measured, M1's again in full

## Later

- `pdf memo` (F16), moved out of M3 on 2026-10-17: the user finds it not essential.

See [FEATURES.md → Later, if needed](FEATURES.md#later-if-needed).
