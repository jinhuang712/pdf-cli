# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- On this machine, since 2026-10-25, PDFKit and Apple's OCR read differently: two unit tests and five `scripts/test-cache.sh` checks fail on `main` too. Find what changed and update the expectations in the final wrap-up.
- The `scripts/test-cache.sh` check "--show raw shows its text, labelled" (expects `[low-quality] TECH LIBRARY`) fails on both the old and the new build on this machine (M2.17 review): part of the same differences.
- M2.9's first `scripts/test-cache.sh` run reported 25 failed checks, not looked at (the line above counts five on `main`); the safety check also fails `hidden/hidden.pdf` p.38. At the final wrap-up, run `test-cache.sh` once, keep the log, and compare it with `main` before M2.9. Noted 2026-10-25.
- M2.10 review, L5: PDFKit's text of page 17 of `testdata/smoke/arxiv-2609.23257.pdf` flips between "Output(JSON)" and "Output (JSON)" in 1 of 3 to 6 runs, before M2.10 too: it breaks "same file, same answer". Find the source of the difference (the space repair, or PDFKit itself). Noted 2026-10-25.
- M2.10 review, L9: commit `d95bc2f` lacks the `Claude-Session` trailer; history is not rewritten. Noted 2026-10-25.
- M2.12 input, from M2.10's review: OCR reading order and the quality threshold on `testdata/smoke/scan-naca-report-1034.pdf` (page 1 reads low-quality as a whole page after `--step ocr`); tune with M2.12. Noted 2026-10-25.
- After `--step ocr`, pages 3, 8 and 10 of `sottigra.pdf` (private test set) lose text to the old "too small to read" hiding: the layer's squeezed-text spots mark OCR lines over them. It predates M2.19 (found by its review). Check what the spots cover before OCR draws them. Noted 2026-10-25.
- `pdf dump --refs` writes `references.json` without the DOIs `pdf ref` takes from the links over an entry (M2.21b review, L7): `ReferenceIndex.allEntries` has no per-page links; give it the `Store.annotations` closure `lookup` takes. Noted 2026-10-25.
- `pdf search` judges running headers on every query and reads every page that has a hit (M2.22 review, item 4): 0.22 s to 0.91 s for "the" in the 625-page memoir manual, release build; the review measured 5,000 pages at 6.9 s to 14.1 s and a 6,402-page library at 7.3 s to 15.5 s. A summary of each page's edge blocks (the few `Furniture` candidates) stored beside the index would make it a lookup, but it changes the stored index (index checks 12) and goes stale with a page's reparse. Do it only if a measured goal needs it. Noted 2026-10-25.
