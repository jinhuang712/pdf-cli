<!-- what-we-build: approved 2026-10-15 -->
# Roadmap

**Current milestone:** M1. An agent reads born-digital and scanned PDFs through the cache.

## Overview

| Milestone | Delivers | Features | Depends on | Size (estimate) | Status |
|---|---|---|---|---|---|
| M0 — Spike | Proven: Swift and Apple's engines carry the design | None shipped | Nothing | About 2 weeks | ✅ |
| M1 — Daily reader | Usable: an agent reads born-digital and scanned PDFs through the cache, with keyword search and page crops | F1, F2, F3, F4 (keyword), F5 (pages and regions), F7, F8, F9, F11, F13 | M0 | About 4–6 weeks | ⬜ |
| M2 — Accurate layout | Proven: two-column papers, footnotes, citations and figures read right | F5 (figures, tables, equations), F6, F10, F12, F14, F15 | M1 | About 2–3 months | ⬜ |
| M3 — Complete | Usable: search by meaning, tables across pages, formulas, memos and a one-command install | F4 (meaning), F16 | M2 | About 1–2 months | ⬜ |

## M0 — Spike ✅

| ID | What it delivers | Note |
|---|---|---|
| M0.1 | A Swift package with a `pdf` command, built as one universal binary | ✅ `scripts/build-universal.sh` builds each architecture and joins them with `lipo`, because a one-step universal build needs Xcode. |
| M0.2 | Text from PDFKit and from PDFium on 10 sample PDFs, compared side by side | ✅ PDFKit is the text source, with an Apple OCR repair for fonts that hide spaces. |
| M0.3 | Apple's document recognizer run on rendered born-digital pages, with its reading order checked by hand | ✅ Not as the main source. It reads scans and repairs spaces. |
| M0.3b | Figures found from PDFKit text and drawing commands, without a model | ✅ 54 of 54 figures on 116 pages, about 9 ms per page |
| M0.4 | One layout model converted to Core ML and timed on the M3 | ✅ Docling's heron and egret-medium convert, under Apache-2.0, at 15–29 ms per page. Kept out of the default until a goal needs one. |
| M0.5 | The answers to M0.2–M0.4 recorded as decisions in DESIGNS.md | ✅ 2026-10-15 |
| M0.6 | The binary's name, checked against Homebrew and common tools for a clash | ✅ `pdf`, chosen 2026-10-14. Homebrew's core catalogue has no formula named `pdf` or `pdf-cli`. |
| M0.7 | The repo's licence | ✅ MIT, chosen 2026-10-14 |

**Exit criteria:** DESIGNS.md → Open questions on the text source, the reading order and Core ML conversion are answered, and GOALS.md G2 holds on the 10 sample PDFs.

✅ Met 2026-10-15. The three questions became dated decisions in DESIGNS.md. For G2, the full text of a file plus the figures on page 1 took at most 0.30 s per file on the 10 arXiv papers, timed three times each by a helper agent that did not write the code. The real `pdf read --page N` is not built yet, so G2 stays open in GOALS.md.

## M1 — Daily reader ⬜

| ID | What it delivers | Note |
|---|---|---|
| M1.1 | Worker processes with time and memory limits, and results cached in SQLite by page content | |
| M1.2 | The text layer, with ligatures, hyphenation and Unicode cleaned up, the font check, and the space repair for at-risk files | |
| M1.3 | Quality checks on every page, failure blocks with crop commands, and unsure blocks with `pdf pick` (F8) | |
| M1.4 | Vision OCR for scanned and garbled pages | |
| M1.5 | `pdf add`, `pdf ls`, `pdf rm` and `pdf gc` (F1, F11) | |
| M1.6 | `pdf info` from bookmarks, page labels and the text layer (F2) | The figure list needs M2's layout models. |
| M1.7 | `pdf read` by page, printed page and section, with the output basics (F3, F7) | |
| M1.8 | `pdf search` by keyword and with `--regex` (F4) | Search by meaning comes in M3. |
| M1.9 | `pdf crop` for pages and regions (F5) | Figure and table crops come in M2. |
| M1.10 | Hidden text kept out of the output (F9) | |
| M1.11 | `pdf agent-guide` and its Claude Code skill (F13) | |
| M1.12 | A smoke set of 10 PDFs, and a safety set of broken PDFs and hidden-text PDFs | One hidden-text PDF per trick: text in the background's color, tiny, clipped, covered by an image and off the page, plus white text on a dark box, which counts as visible |

**Exit criteria:** GOALS.md G2, G4, G9, G12, G13 and G16, plus the author's own report after one week of daily use.

## M2 — Accurate layout ⬜

| ID | What it delivers | Note |
|---|---|---|
| M2.1 | The open test set: 60 open-access PDFs, labelled | |
| M2.2 | The question set: 200 questions, each with its answer and page | |
| M2.3 | A scorer that weighs a wrong block 3× a missing one, and a Docling baseline run on the same Mac | |
| M2.4 | The layout model running on Core ML | Only if a goal fails with rules alone. See DESIGNS.md → the decision on rules over a default layout model. |
| M2.5 | Reading order across columns, with running headers, footers and publisher stamps removed | |
| M2.6 | Figures, tables and equations detected, and cropped with `pdf crop` (F5) | Each table's text gives way to its table block. |
| M2.7 | Footnotes, endnotes, headnotes, margin notes and author notes (F14) | |
| M2.8 | Citations, references and cross-references (F15) | |
| M2.9 | `pdf dump` (F6) | |
| M2.10 | `pdf reparse` with `--step ocr` (F10) | `--step vlm` comes in M3. |
| M2.11 | `pdf setup` and `pdf doctor` (F12) | |
| M2.12 | The quality thresholds, tuned until G11 passes | |

**Exit criteria:** GOALS.md G3, G5, G6, G7, G8 and G11.

## M3 — Complete ⬜

| ID | What it delivers | Note |
|---|---|---|
| M3.1 | The embedding model chosen, and `pdf search` by meaning, Chinese queries included (F4) | |
| M3.2 | Tables that continue across pages, linked as one table with a crop per page | |
| M3.3 | A local vision model for hard pages and formulas, with `pdf setup vlm` and `pdf reparse --step vlm` | |
| M3.4 | `pdf memo` (F16) | |
| M3.5 | A Homebrew release that installs with one command | |
| M3.6 | The question set run in Claude Code with pdf-cli and with the built-in Read tool | Measures G1 and G15 |

**Exit criteria:** GOALS.md G1, G10, G14 and G15.

## Later

See [FEATURES.md → Later, if needed](FEATURES.md#later-if-needed).
