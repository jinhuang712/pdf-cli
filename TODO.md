# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- M2.9's first `scripts/test-cache.sh` run reported 25 failed checks, not looked at (M2.25 fixed two checks and the safety check's `hidden/hidden.pdf` p.38; others may still fail on this macOS). At the final wrap-up, run `test-cache.sh` once, keep the log, and compare it with `main` before M2.9. Noted 2026-10-25.
- M2.12 input, from M2.10's review: OCR reading order and the quality threshold on `testdata/smoke/scan-naca-report-1034.pdf` (page 1 reads low-quality as a whole page after `--step ocr`); tune with M2.12. Noted 2026-10-25.
- `pdf dump --refs` writes `references.json` without the DOIs `pdf ref` takes from the links over an entry (M2.21b review, L7): `ReferenceIndex.allEntries` has no per-page links; give it the `Store.annotations` closure `lookup` takes. Noted 2026-10-25.
- `pdf search` judges running headers on every query and reads every page that has a hit (M2.22 review, item 4): 0.22 s to 0.91 s for "the" in the 625-page memoir manual, release build; the review measured 5,000 pages at 6.9 s to 14.1 s and a 6,402-page library at 7.3 s to 15.5 s. A summary of each page's edge blocks (the few `Furniture` candidates) stored beside the index would make it a lookup, but it changes the stored index (index checks 12) and goes stale with a page's reparse. Do it only if a measured goal needs it. Noted 2026-10-25.
- Stale picks stay stored (M2.24): `pdf doctor` may report, read-only, how many picks exist, apply, and have no cached page; any deletion needs an explicit flag and an age limit. `doctor --clean` must not delete picks on its own: macOS can purge the cache, and `pdf rm` promises that a file added again shows its picks. Noted 2026-10-25.
