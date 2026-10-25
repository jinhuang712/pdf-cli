<!-- what-we-build: drafted 2026-10-26 -->
# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- M2.9's first `scripts/test-cache.sh` run reported 25 failed checks, not looked at (M2.25 fixed two checks and the safety check's `hidden/hidden.pdf` p.38; others may still fail on this macOS). At the final wrap-up, run `test-cache.sh` once, keep the log, and compare it with `main` before M2.9. Noted 2026-10-25.
- M2.12 input, from M2.10's review: OCR reading order and the quality threshold on `testdata/smoke/scan-naca-report-1034.pdf` (page 1 reads low-quality as a whole page after `--step ocr`); tune with M2.12. Noted 2026-10-25.
- Stale picks stay stored (M2.24): `pdf doctor` may report, read-only, how many picks exist, apply, and have no cached page; any deletion needs an explicit flag and an age limit. `doctor --clean` must not delete picks on its own: macOS can purge the cache, and `pdf rm` promises that a file added again shows its picks. Noted 2026-10-25.
- M2.25: the document recognizer pinned to the CPU (`setComputeDevice(.cpu, for: .main)` and `.postProcessing`) gave one answer in the review's 16 of 16 processes; measure again when the flip can be reproduced, and use it for scans if it holds. Noted 2026-10-26.
- M2.25: hostile pages that still leak (they predate M2.25): a black planted line over a black box after white labels (`joins` p.7); a visible word drawn over the start of a white, clipped or invisible line leaves "PLANT" as text; a visible word 30 points back over the end of an invisible line leaves "e user.". Noted 2026-10-26.
- M2.25: `arxiv-2608.24191` p.13 para 11 "Translatethefollowing Urdusocialmedia" is no longer flagged run-together (each half under 25 letters). Noted 2026-10-26.
- Final wrap-up: add one end-to-end check that a cache made by the previous `main` build opens, reads, searches and reparses with the new build (M2.26 review: a new table skipped on a schema-9 cache broke everything, and every test opened a fresh store). Noted 2026-10-26.
