# 057. an OCR line that reads as prose is no "too small to read" text

Decided: 2026-10-25    Status: current

After `--step ocr` (or on a page read by OCR), pages 3, 8 and 10 of `sottigra.pdf` (TeX Live's MusiXTeX manual) lost prose to the "too small to read" marker: the line "(a plus forte raison une alteration de precaution. Vos competances de music…" on p.8 sat under a spot 95% of the page wide and 14% tall, the union of the boxes of a music font's glyphs (one of them, a staff rule, is 516 points wide in PDFKit's boxes, from x = -51), and `OCR.markHidden` hides every OCR line that a spot covers by half. Before OCR draws them, the spots cover only the squeezed glyphs of the layer; the prose is no part of them.

Text under 2 points or squeezed to slivers is drawn as specks, and OCR reads specks as stray marks ("В.... в....", "3 3ğ", "ˇ ˇ ˇ"), not as words. So a line that OCR reads as prose, at least three words of two letters or more and letters in 60% of its marks, is not covered by a `tiny` spot, whatever the spot's box. Other reasons (covered, annotation, background, invisible) still hide every line they cover, as a word hidden among visible ones goes under the marker with its line.

| Option | For | Against |
|---|---|---|
| **A `tiny` spot hides a line only if the line does not read as prose** | Fixes the giant spot and the small spot inside a line with one rule; no geometry to tune; all 73 pages of `testdata/hidden/hidden.pdf`, read by OCR, keep every planted word out. | A planted line of real words that OCR can read from letters too small to read would show: letters OCR reads are legible to a reader too, so the page does not hide them from a reader. |
| Ignore a spot taller than three lines | Fixes the giant spot. | A tiny spot inside a prose line still hides it; the thresholds are guesses. |
| Intersect the spot with the page's ink | Exact. | Needs the page's drawing commands per spot, as `Visibility` does, for a case rules settle. |
| Leave as it is | No risk. | Loses prose on pages of music, tables of tiny marks. |

Tested by `TinySpotsTests` on `testdata/hidden/tiny-near-prose.pdf` (two prose lines under 1.5-point words; both hidden on the old build), made by `scripts/make-hidden-fixture.swift`.

*Dated note on the PDFKit save decision (M2.25, 2026-10-26):* on macOS 27 a PDFKit save keeps the file's original producer (the sample's saved copy said "pikepdf"), and the text of all 11 pages of the sample paper survives it, so the damage this decision describes no longer shows there. A file saved by older macOS still carries it, and nothing in the file tells the saves apart.
