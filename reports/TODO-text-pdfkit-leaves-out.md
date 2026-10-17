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

After the review fixes, all 162 unit tests and all 145 end-to-end checks passed, 3 of the checks new: the fixture's page is flagged, its failure block says why, and its crop covers the place. `unread.pdf` has 6 pages: a hidden squeezed line and one under an image stay out, and a word left out inside a line and a TeX-style Type 3 font are found.

Unit tests: `HiddenTextTests.aBudgetCutAtAPlaceLeftOutGoesOn` numbers the place after the page's blocks. `HiddenTextTests.textPDFKitLeavesOutFlagsThePage` reads `testdata/hidden/unread.pdf`, written by `scripts/make-hidden-fixture.swift`: page 1's Type 3 line with no text map is one place, where it is drawn, spelled by its codes; the page reads below the quality bar; the failure block names the reason and crops the place; `--raw` numbers its block after the page's last. Page 2, the same font with a text map, reads as text. `StoreTests` judges such a page alike from its layer and from the stored measures.

## Review

A reviewer new to the code checked this fix together with the M1.10 sixth review's fixes (`4cd1c71`, `903b158`), with pages of its own in `/private/tmp/claude-501/batch3rev/`, sweeps of 79 more TeX Live manuals, the 399 other PDFs on this Mac and iWork's licenses, and the binaries before both. It found 10 problems, each confirmed by running it.

| # | Finding | Verdict | Resolution |
|---|---|---|---|
| 1 | `--raw` spelled hidden text PDFKit left out: a Type 3 line squeezed to 1%, set at 1 pt, under an image or clipped away was a place, as its ink was the image's or its smudge's, and the plain read pointed to `--raw`. | Confirmed, high, new | Fixed: only strings a reader sees count, drawn to show, not crushed, 2 pt tall or more, not clipped away, with no image or shape drawn over most of them. `unread.pdf` p.3 and p.4. |
| 2 | Words in the invisible mode were no longer checked letter by letter, from the sixth review's fix, so such a line over a dotted leader or a dashed rule read whole. | Confirmed, medium-high, regression | Fixed: only on a scan's page; elsewhere such words get their letter checks back, as before the sixth review. The older partial leak over a dense leader is recorded in FEATURES. |
| 3 | Where PDFKit's two texts of a page differ in length, as on right-to-left pages, PDFKit gives no sizes, so every box was thrown out: iWork's license had 3 Hebrew pages flagged, and two TeX Live manuals in Arabic went to OCR, which read them worse. | Confirmed, medium-high, new | Fixed: such boxes are weighed against the page's usual box height, and OCR serves only where it reads a fifth more letters than the layer, and 20 at least. The pages read as before. |
| 4 | Text PDFKit dropped beside text it kept went unflagged: a box's center within half a line of the string vouched for it. | Confirmed, medium, new | Fixed: a character vouches only on the string itself, in the string's own space. `unread.pdf` p.5. |
| 5 | A read cut by its budget at such a place went back to the page's start, and so again for ever; older for the off-page marker. | Confirmed, medium | Fixed: the places, the off-page marker and the note of an incomplete check are numbered after the page's blocks, and a read goes on past them. |
| 6 | A string of under 3 letters or digits that PDFKit boxed a few characters off, as "(8)", was flagged. | Confirmed, medium-low, new | Fixed: only strings of 3 letters or digits count. |
| 7 | Strings of blank glyphs over a signature's line were flagged, spelling nothing. | Confirmed, low-medium, new | Fixed, as 6. |
| 8 | The memo of visibility expressions kept an expression untold past the depth limit and reused it when met nearer the top. | Confirmed, low-medium, regression | Fixed: an untold result is reused only as deep or deeper. |
| 9 | The memo was keyed by an array's address, and an inline membership's arrays are freed and their addresses reused. | Confirmed, low-medium, regression | Fixed: the memo holds for one membership at a time. |
| 10 | A string of 1e20 points crashed the page, in the cell index of the new check. | Confirmed, low-medium, new | Fixed: the index is clamped. |
| — | Dashed arrows and symbols of display maths that PDFKit leaves out flag their pages, a chess diagram 63 places. | Confirmed | Kept: PDFKit does leave them out; recorded in FEATURES. |

Found while fixing:

- With only strings 2 pt tall counting, TeX Live's music manual lost its places, as its Type 3 fonts draw 12-pt letters at a size of 0.12, in glyphs 100 units tall under a matrix of 1. A Type 3 font's strings are now as tall as its box under its matrix, which the hidden-text check reads too; `unread.pdf` p.6 holds such a font.
- The test of a character on the string itself flagged 17 places on macOS's Hebrew license and pages of two Arabic manuals: PDFKit's boxes fitted to their lines leave right-to-left strings. PDFKit's own boxes, asked for only then, lie on them.
- PDFKit's own boxes sit a character off, so a space beside a word it left out lent the next character a box over the word, and for a Type 3 font with a font descriptor PDFKit lays the next words' boxes over the word it leaves out. Boxes now count only the size of a glyph; the second case stays a limit, recorded in FEATURES.
- A frame drawn as one glyph over and over in an Arabic manual was a place: such strings no longer count.
- The OCR-cap test, bounded at 3 s on a page whose OCR stops at 3 s, took 3.1 s in 2 of 4 full runs beside the other suites, and 2.2 s alone; its bound is now 4 s.

## Second review

A second reviewer new to the code checked the fixes above (`6e0b3f7`) against the build before them (`9c74f1e`), the item `TODO.md` held, with pages of its own in `/private/tmp/claude-501/finalrev/`, the macOS license in 41 languages, Xcode's acknowledgments, 373 other PDFs on this Mac and 86 TeX Live manuals. It found 10 problems, 9 reproduced. Fixed on 2026-10-17.

| # | Finding | Verdict | Resolution |
|---|---|---|---|
| 1 | `--raw` spelled hidden text again: a white line between two visible lines, whose ascenders and descenders lent it ink, and a line at 2% opacity or clipped by a path of two small squares. | Confirmed, high, regression | Fixed by design: what a place's strings spell goes out nowhere, `--raw` included. Its failure block gives the crop alone, which shows only what a reader sees. Each review found a new way past the rules of what a reader sees there; now a hidden string the rules miss costs a false flag and a crop, never its words. |
| 2 | `sottigra.pdf` p.9 lost its prose: the page no longer went to OCR, and its top quarter was in no block, place or crop. | Confirmed, high-medium, regression | Fixed. The cause was not the one the reviewer guessed, PDFKit's own boxes: MusiXTeX's Type 3 fonts carry the placeholder box [0 0 1000 1000], so at a size of 0.12 their 10-pt letters stood 120 pt tall, over the lines above, whose characters then stood for them. A Type 3 font's strings now stand no taller than an em by its widths, twice the median advance. p.9 goes to OCR and reads whole. `unread.pdf` p.7. |
| 3 | A string hidden in part, by a clip or by images drawn after it, was spelled whole. | Confirmed, medium-high | Fixed by 1: it can flag its page; its words stay out. Its visible part is text PDFKit left out, so the flag is right. |
| 4 | A line squeezed by its text matrix, not by `Tz`, was spelled. | Confirmed, medium-high | Fixed by 1. |
| 5 | Integrals and large delimiters PDFKit keeps were places: their boxes stand 2.2 to 3 times their size, over the 2 times allowed. | Confirmed, medium, regression | Fixed: boxes up to 3.5 times their character's size count. `LeteSansMath.pdf` p.8 and `firamath-otf-doc.pdf` p.7 flag nothing. |
| 6 | A dropped "$1,000,000.00" was no place: the rule for frames drawn as one glyph over and over counted its zeros. | Confirmed, medium, regression | Fixed: the rule counts letters, not digits. `unread.pdf` p.9. |
| 7 | 40,000 spans naming one membership whose expression is 30 levels deep, with 999 shared operands a level, timed the page out at 30 s: the memo of expressions held for one membership at a time. | Confirmed, low-medium, regression | Fixed: a membership named in the resources, which lasts as long as the file, is told once, and the expressions told for it stay; only an inline membership's are forgotten after it. Each marked span and each expression told count against the page's limit of operations, past which the check says it is incomplete. The file reads in under a second; a unit test builds 20,000 such spans. |
| 8 | The parser version stayed 9, so pages cached before the fixes kept their places. | Confirmed, low-medium | Fixed: parser version 10. |
| 9 | Visible music chords on `sottigra.pdf` p.9 were marked too small to read. | Confirmed, low | Gone from the output by 2, as before `6e0b3f7`: OCR reads p.9 again, in place of PDFKit's layer. The mark is older than the fix and stays in the layer: PDFKit boxes a chord's notes on one spot, as it boxes letters stacked to hide them, and the strings that draw them stand three times taller than the boxes, so none counts as the notes' own. Loosening the test would let stacked letters through; kept, in FEATURES.md → F9. |
| 10 | A Type 3 font with an empty box, [0 0 0 0], drawn at 0.12, was no place. | Confirmed, low | Fixed by 2: its strings stand an em tall by its widths. `unread.pdf` p.8. |

Kept as a limit, in FEATURES.md → F8: a string hidden in a way the place check misses can flag its page. On the reviewer's 10 files of tricks, 23 places remain, over strings hidden in whole or in part and over text PDFKit does leave out; no output holds a word of a hidden string.

Checked after the fixes, release build, against `6e0b3f7`: 143 PDFs, macOS's license in 41 languages, the test fixtures and the reviewer's 86 TeX Live manuals, read whole with each build. 138 read the same: hidden markers, places and flagged pages. The rest:

- `unread.pdf`: its 3 new pages are flagged, as they should be; the old build missed them.
- `sottigra.pdf`: p.9 goes to OCR and is no longer flagged; `LeteSansMath.pdf` p.8 lost its 4 false places; `pennstander-otf-samples.pdf` has 5 places on the same 4 pages, one fewer.
- `lshortru.pdf` p.34: the false mark "лой." is back, as before `6e0b3f7`. PDFKit's boxes for that word lie a line off the string that draws it and nearly on one spot, so no string counts as the word's own, and the boxes read as stacked letters. The strings 120 pt tall of `6e0b3f7` reached it by chance. Kept: loosening the test for stacked letters would let hidden words through.

The reviewer's 10 cases, rerun: no planted word in any output, `--raw` included; sottigra p.9 read by OCR with its prose; both amounts and the font with an empty box flagged; the maths pages unflagged; the 40,000 spans read in under a second, against 30 s.
