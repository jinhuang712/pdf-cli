# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- Links past the first 1,000 of a file are not shown: TeX Live's PGF manual holds 44,700, so most of its pages show none. Keep annotations per page in a table of their own, not in the file's facts, which every read decodes, and read their words for the pages asked for. Noted 2026-10-17, in M1.13.
- `pdf search` still finds running headers, footers and page numbers, one hit a page: the index takes each page as it is parsed, before the pages around it say what repeats. Mark them in the index once a document is parsed, or drop them from the hits. Noted 2026-10-17, in M2.5.
- On this machine, since 2026-10-25, PDFKit and Apple's OCR read differently: two unit tests and five `scripts/test-cache.sh` checks fail on `main` too. Find what changed and update the expectations in the final wrap-up.
- The `scripts/test-cache.sh` check "--show raw shows its text, labelled" (expects `[low-quality] TECH LIBRARY`) fails on both the old and the new build on this machine (M2.17 review): part of the same differences.
- M2.9's first `scripts/test-cache.sh` run reported 25 failed checks, not looked at (the line above counts five on `main`); the safety check also fails `hidden/hidden.pdf` p.38. At the final wrap-up, run `test-cache.sh` once, keep the log, and compare it with `main` before M2.9. Noted 2026-10-25.
- M2.10 review, L4: `pdf reparse` clears the picks on a page even when the new reading is the same as the old, as F8 words it. The user's call: keep a pick while the readings it was made for are still offered. Noted 2026-10-25.
- M2.10 review, L5: PDFKit's text of page 17 of `testdata/smoke/arxiv-2609.23257.pdf` flips between "Output(JSON)" and "Output (JSON)" in 1 of 3 to 6 runs, before M2.10 too: it breaks "same file, same answer". Find the source of the difference (the space repair, or PDFKit itself). Noted 2026-10-25.
- M2.10 review, L9: commit `d95bc2f` lacks the `Claude-Session` trailer; history is not rewritten. Noted 2026-10-25.
- M2.12 input, from M2.10's review: OCR reading order and the quality threshold on `testdata/smoke/scan-naca-report-1034.pdf` (page 1 reads low-quality as a whole page after `--step ocr`); tune with M2.12. Noted 2026-10-25.
- After `--step ocr`, pages 3, 8 and 10 of `sottigra.pdf` (private test set) lose text to the old "too small to read" hiding: the layer's squeezed-text spots mark OCR lines over them. It predates M2.19 (found by its review). Check what the spots cover before OCR draws them. Noted 2026-10-25.
