# 005. Apple OCR word breaks over PDFium for fonts that hide spaces

Decided: 2026-10-14    Status: current

Some fonts declare character 32 wider than a normal space, and PDFKit then drops the spaces between words. The font check marks such a file "at risk" before reading. For an at-risk file, the tool keeps PDFKit's characters and takes only the word breaks from Apple OCR. The decision is provisional, like the one above.

The M0 spike scored each method on the one affected paper, against PDFKit's text of a copy whose fonts were corrected ([spike/M0.2b-spaces.md](../../spike/M0.2b-spaces.md)):

| Option | Spaces found | Characters matching | Spaces added | Note |
|---|---|---|---|---|
| **PDFKit characters + Apple OCR word breaks** | 97.6% | 99.9% | 71 | Apple-only. About 0.63 s per page, paid by at-risk files only. |
| PDFium | 97.5% | 98.3% | 276 | A non-Apple library to bundle. |
| Apple OCR alone | 98.9% | 88.4% | 71 | Misreads small marks, such as a superscript 1 as `'`. |
| PDFKit alone | 71.2% | 99.9% | 0 | Words run together on every page. |

Task M1.2 built the repair and scored it the same way: 97.8% of spaces found, 99.9% of characters matching and 68 spaces added, with macOS 26's document recognizer. The text recognizer that older macOS versions use found 96.2% and added 93. A repaired page costs 0.64–0.8 s of OCR in one worker, and the whole 18-page paper took 6.9 s with four workers. The first page of the paper, unseen, came back in 1.33 s, inside goal G2's 2 s. Task M1.4 changed the rendering, leaving annotations out of the image and rounding its size down, and the score moved to 98.6% of spaces found and 81 added. With the sample check, the first page took 1.69 s.

Most added spaces sit inside formulas and number lists. The run-together count flags the spaces still missing (see Silent errors), and where two readings still differ in words, the agent picks one with `pdf pick`. The sample is one paper, the only one of ten with this problem.
