# M0 spike — findings

Measured 2026-10-14 on an M3 MacBook (24 GB, macOS 26.4), on the 11 PDFs in `testdata/smoke/` (10 CC BY 4.0 arXiv papers, 9 of them two-column, and one public-domain NACA scan). The detailed reports sit next to this file. The scripts that made them (`scripts/spike/*.py`) and the hidden `pdf spike` command they called (`text`, `docs`, `figures`) were removed in M3.12; the last commit that has them is the parent of M3.12's, and `spike/coreml/` stays as the recipe to convert a layout model.

## Answers

| Question (ROADMAP.md → M0) | Answer | Report |
|---|---|---|
| PDFKit or PDFium as the main text source? | Both are fast (PDFKit about 9 ms per page with process start, PDFium about 2 ms). PDFKit keeps the columns in order best, but on 1 of 10 papers it runs words together on every page, and its character boxes cannot recover the spaces. The cause is the paper's fonts, which declare character 32 twice as wide as a normal space. Taking PDFKit's characters and Apple OCR's word breaks finds 97.6% of the spaces, against 71.2% for PDFKit alone and 97.5% for PDFium. Apple's recognizer alone finds 98.9% but misreads small marks, such as superscript 1 as `'`. PDFium keeps the spaces and marks line-end hyphens. | `M0.2-text.md`, `M0.2b-spaces.md`, `M0.3-reading-order.md` |
| Is Apple's document recognizer's reading order usable on born-digital pages? | No, as the main source: it mixed the two columns badly on 2 of 36 pages and takes about 0.7 s per page. It stays useful for scanned pages and as the fallback that repairs missing spaces. | `M0.3-reading-order.md` |
| Which layout models convert to Core ML, and may we use them? | Both Docling models convert (heron and egret-medium, Apache-2.0). fp32 matches PyTorch exactly. Mixed precision runs at about 15–29 ms per page and misses 1 region in about 100. Swift compiles and loads them without Xcode. | `M0.4-coreml.md` |
| Can Base (PDFKit and Core Graphics) find figures without a model? | Yes on this sample: 54 of 54 figures boxed with their captions on 116 hand-checked pages, no false figures, about 9 ms per page. The rules were tuned on the same papers. Scans are not covered. | `M0.3b-figures-base.md` |
| What does the layout model add? | Labelled regions in one pass: footnotes, section headers, captions, formulas, list items, page headers and footers. On the scan, the two models disagree. | `M0.4-coreml.md` |

## Goal G2 in Base

The full text of each file plus figure finding on page 1, each in a fresh process, took at most 0.36 s per file. A separate check on 2026-10-15, by a helper agent that did not write the code, ran each file three times and measured at most 0.30 s. That is well under the 2 s of goal G2. Pages that need OCR were not part of this timing.

The decisions that follow from these answers are dated sections in `DESIGNS.md`.

## Other findings

- `swift build --arch arm64 --arch x86_64` needs Xcode. `scripts/build-universal.sh` builds each architecture separately and joins them with `lipo`.
- PDFium marks a hyphen at a line break with U+FFFE. poppler joins such words and drops real hyphens, as in "perstep".
- Footnote markers come out glued to the word in every engine, as in "Challenge1". Telling them apart needs font size or baseline. Exponents flatten the same way: PDFKit prints 10⁻⁵ as "10−5".
- PDFKit turns a results table into a flat stream of numbers without rows or columns (arxiv-2609.23257, page 6).
- None of these results measures text against known correct text, except the space repair, which uses PDFKit's text of the font-corrected copy. The sample is 10 recent LaTeX arXiv papers and one scan, and the scan's text was not scored.
