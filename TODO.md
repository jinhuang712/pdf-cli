# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- Ship the licence notice of every model that `pdf setup` downloads. MIT covers only our own code.
- Make `pdf ls` and `pdf info` cheap on large inputs. Both judge every cached page, which decodes each page's stored text layer: fine for tens of PDFs, slow for thousands, and `pdf info` on the 456-page test file took 386 ms against goal G4's 200 ms (42 ms on an 11-page paper). A per-page record of each page's tokens, headings and the measures the verdict needs would avoid the decode. Found in M1.5 and M1.6, 2026-10-15.
- Make the index walk the page tree once. It asks CGPDF for each page by number, which takes longer the longer the file: 3.9 s for 10,000 pages and 30 s for 30,000, all before the first page reads. The facts reader's own walk took the same 27 s down to 0.15 s. Found in the M1.6 review, 2026-10-15.
- Give a slow file open more time. A file whose opening stays silent for 30 s three times, as an iCloud file that downloads on open might, fails as damaged for that stat. Found in the M1.1 review, 2026-10-15.
- Show when an OCR'd page's second reading failed. The page is then judged without its agreement score, as ok, and the output gives no sign that the check is missing. Found in the M1.3 review, 2026-10-15.
