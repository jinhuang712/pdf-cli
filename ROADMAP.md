<!-- what-we-build: approved 2026-10-14 -->
# Roadmap

**Current milestone:** M0. Prove that Swift and Apple's engines can carry the design.

## Overview

| Milestone | Delivers | Features | Depends on | Size (estimate) | Status |
|---|---|---|---|---|---|
| M0 — Spike | Proven: Swift and Apple's engines carry the design | None shipped | Nothing | About 2 weeks | ⬜ |
| M1 — Daily reader | Usable: an agent reads born-digital and scanned PDFs through the cache, with keyword search and page crops | F1, F2, F3, F4 (keyword), F5 (pages and regions), F7, F8, F9, F11, F13 | M0 | About 4–6 weeks | ⬜ |
| M2 — Accurate layout | Proven: two-column papers, footnotes, citations and figures read right | F5 (figures, tables, equations), F6, F10, F12, F14, F15 | M1 | About 2–3 months | ⬜ |
| M3 — Complete | Usable: search by meaning, tables, formulas, memos and a one-command install | F4 (meaning), F16 | M2 | About 1–2 months | ⬜ |

## M0 — Spike ⬜

| ID | What it delivers | Note |
|---|---|---|
| M0.1 | A Swift package with a `pdf` command, built as one universal binary | |
| M0.2 | Text from PDFKit and from PDFium on 10 sample PDFs, compared side by side | Answers which engine is the main text source |
| M0.3 | Apple's document recognizer run on rendered born-digital pages, with its reading order checked by hand | Answers whether its reading order is usable |
| M0.4 | One layout model converted to Core ML and timed on the M3 | Answers which models convert. Check the weight licence first. |
| M0.5 | The answers to M0.2–M0.4 recorded as decisions in DESIGNS.md | |
| M0.6 | The binary's name, checked against Homebrew and common tools for a clash | ✅ `pdf`, chosen 2026-10-14. Homebrew's core catalogue has no formula named `pdf` or `pdf-cli`. |
| M0.7 | The repo's licence | ✅ MIT, chosen 2026-10-14 |

**Exit criteria:** DESIGNS.md → Open questions on the text source, the reading order and Core ML conversion are answered, and GOALS.md G2 holds on the 10 sample PDFs.

## M1 — Daily reader ⬜

| ID | What it delivers | Note |
|---|---|---|
| M1.1 | Worker processes with time and memory limits, and results cached in SQLite by page content | |
| M1.2 | The text layer, with ligatures, hyphenation and Unicode cleaned up | |
| M1.3 | Quality checks on every page, and failure blocks with crop commands (F8) | |
| M1.4 | Vision OCR for scanned and garbled pages | |
| M1.5 | `pdf add`, `pdf ls`, `pdf rm` and `pdf gc` (F1, F11) | |
| M1.6 | `pdf info` from bookmarks, page labels and the text layer (F2) | The figure list needs M2's layout models. |
| M1.7 | `pdf read` by page, printed page and section, with the output basics (F3, F7) | |
| M1.8 | `pdf search` by keyword and with `--regex` (F4) | Search by meaning comes in M3. |
| M1.9 | `pdf crop` for pages and regions (F5) | Figure and table crops come in M2. |
| M1.10 | Hidden text kept out of the output (F9) | |
| M1.11 | `pdf agent-guide` and its Claude Code skill (F13) | |
| M1.12 | A smoke set of 10 PDFs, and a safety set of hidden-text and broken PDFs | |

**Exit criteria:** GOALS.md G2, G4, G9, G12, G13 and G16, plus the author's own report after one week of daily use.

## M2 — Accurate layout ⬜

| ID | What it delivers | Note |
|---|---|---|
| M2.1 | The open test set: 60 open-access PDFs, labelled | |
| M2.2 | The question set: 200 questions, each with its answer and page | |
| M2.3 | A scorer that weighs a wrong block 3× a missing one, and a Docling baseline run on the same Mac | |
| M2.4 | Layout and table models running on Core ML | |
| M2.5 | Reading order across columns, with running headers, footers and publisher stamps removed | |
| M2.6 | Figures, tables and equations detected, and cropped with `pdf crop` (F5) | |
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
| M3.2 | Tables with merged cells, and tables that continue across pages | |
| M3.3 | A local vision model for hard pages and formulas, with `pdf setup vlm` and `pdf reparse --step vlm` | |
| M3.4 | `pdf memo` (F16) | |
| M3.5 | A Homebrew release that installs with one command | |
| M3.6 | The question set run in Claude Code with pdf-cli and with the built-in Read tool | Measures G1 and G15 |

**Exit criteria:** GOALS.md G1, G10, G14 and G15.

## Later

See [FEATURES.md → Later, if needed](FEATURES.md#later-if-needed).
