# TODO fix — text PDFKit leaves out flags the page

- **Built:** 2026-10-16, the last item in `TODO.md`, which the user asked to do.
- **Written:** 2026-10-16, on the fix's branch.

## What was built

PDFKit gives the text the parse reads, so text PDFKit leaves out of a page went missing without a trace. The hidden-text check already places every string a page draws, from the drawing commands. Now a string drawn to show, with ink, where PDFKit has neither a character's box nor text that spells it, is text PDFKit left out. Each such place gets a failure block, after the page's text, with a crop command for the place, and the page reads below the quality bar, so `pdf ls`, `pdf info` and the summary line flag it. `--raw` shows what the strings spell by their codes, labelled, which for a font with no text map may not be what it shows.

- Only strings of 3 glyphs or more count, set along the page's axes and on the page. PDFKit's boxes for text set at an angle can lie anywhere: a diagonal watermark's boxes sat level, elsewhere on the page.
- PDFKit's boxes vouch for text only where their character has a font size, and they are no taller than 3 times it and no wider than 4 times. PDFKit gave one character a box a line long, 13 times as wide as its size, whose center lay on the next line's empty place.
- Strings on one line join into one place, and a page holds at most 20 places, each spelled to 300 characters.
- A page whose drawn glyphs PDFKit left out by 30% or more is read by OCR instead, as a page with no usable text layer is, and its layer stays for `--raw`. TeX Live's manual of musical notation, `sottigra.pdf`, set in Type 3 fonts, lost most of its first page to PDFKit, its title and author among them; OCR reads them. Where OCR cannot read the page, the layer serves, its places flagged.
- Parser version 9: pages read before are read again, to find such places.

The TODO item named an unbalanced `q` inside a form, found in M1.10's first review, as making PDFKit leave text out. On macOS 26 it did not, nor did nine other odd ways of drawing text tried: a form that scales or clips and never pops its state, a `BT` never ended, `BT` inside `BT`, a horizontal scale of 0, a stray `ET`, an inline image before the text. A Type 3 font with no text map did: PDFKit gives nothing for the line it draws. A marked-content span with `/ActualText` puts its replacement in PDFKit's text in place of what it draws, as authors use it for ligatures and hyphenated words; that is not flagged.

## Measurements

On this Mac, release build: no place found on macOS's license in 41 languages, Xcode's 231-page acknowledgments, the 11 samples, the 3 OCR samples or the hidden-text fixtures; one on each of the two Type 3 test pages. Of 67 TeX Live manuals, one lost text to PDFKit: `sottigra.pdf`, 200 places on its pages before OCR read them. Earlier versions marked wrongly: the first, two TeX Live manuals and 13 places, as its filter of PDFKit's boxes by the page's usual letter height threw out a title's 40-pt letters; the second, the fixture's letters placed right to left, as its filter by the boxes' raw size threw out their boxes of negative width. The filter now weighs each box, standardized, against its own character's font size.

## Tests

All 161 unit tests and all 145 end-to-end checks passed, 3 of the checks new: the fixture's page is flagged, its failure block says why, and its crop covers the place.

Unit tests: `HiddenTextTests.textPDFKitLeavesOutFlagsThePage` reads `testdata/hidden/unread.pdf`, written by `scripts/make-hidden-fixture.swift`: page 1's Type 3 line with no text map is one place, where it is drawn, spelled by its codes; the page reads below the quality bar; the failure block names the reason and crops the place; `--raw` numbers its block after the page's last. Page 2, the same font with a text map, reads as text. `StoreTests` judges such a page alike from its layer and from the stored measures.

## Review

Not yet reviewed.
