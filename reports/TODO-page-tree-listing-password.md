# TODO fixes — one walk of the page tree, cheap listings, the password prompt, info's table

- **Built:** 2026-10-16, the items left in `TODO.md` that need no new milestone. The user asked for them all.
- **Written:** 2026-10-16, on the fixes' branch.

## What was built

- **The index walks the page tree once.** It asked CGPDF for each page by its number, and CGPDF finds a page from the top of the tree, so on a flat tree, one node holding every page, the cost grew with the square of the pages. `PageTree` lists the pages from one walk. It serves only a tree it numbers as CGPDF does: `/Pages` nodes with true counts, kids that name their node as `/Parent`, `/Page` leaves, no node twice, CGPDF's page count, and CGPDF's own first, middle and last pages where the walk puts them. Any other tree goes page by page, as before. Page keys stay the same, so picks and document IDs keep: the key's boxes and rotation come from the page's dictionary by CGPDF's rules, measured on this Mac. A box is the nearest one of four numbers up the tree, corners in either order, never cut to the media box; the media box is US Letter without one; `/Rotate` is kept as written, -90 and 450 included. A page with a malformed box or rotation, which CGPDF passes over for its parent's, asks CGPDF. The font check reads each content stream in turn, through `CGPDFContentStreamCreateWithStream` with no parent. The C header allows that, but Swift's import does not, so the function is called by its C symbol.
- **`pdf ls`, `pdf info` and `pdf search` decode a page's layer once, or not at all.** `PageResult.pageText` decoded the layer's JSON each time it was read, and `pdf info` read each page's about five times. It now decodes once per command. What the verdict reads of a layer (`PageMeasures`: the layer score, lost spaces, the failed check, the OCR agreements and the unsure words) is also stored in a column of its own (schema 8). `pdf ls` now judges every page without loading a layer. A page cached before gets the column the first time a listing judges it, as pages joined the keyword index. `Quality.judge` reads `PageMeasures` alone, so a listing and a read judge a page alike.
- **A locked file points to `--password-stdin`, which asks for the password.** The failure line named `pdf add <path> --password <password>`, which put the password in the list of running commands. It now names `--password-stdin`. On a terminal, that asks "Password for <file>:" and hides the typing, through `readpassphrase`; piped in, it reads the first line, as before. `pdf crop` asks the same way.
- **`pdf info`'s section table keeps to 40 rows.** Past 40 rows at the top two levels, it shows the top level alone and that level's first 40 sections, and says how many more `--json` lists. A file with 200 bookmarks gave about 3,200 tokens.
- **The licence notices moved to M2.11** in ROADMAP. `pdf setup` does not exist yet, so nothing downloads a model.
- **The M1.10 fifth review** ran on the fourth review's fixes, as TODO asked. Its 11 findings are in `reports/M1.10-hidden.md` → Fifth review, and TODO lists them until they are fixed.

## Measurements

On this Mac, release builds, a cold cache for the first page, the median of 7 runs for cached commands. The test files are generated: flat and balanced page trees of 10,000 and 30,000 one-line pages, and 467 pages joined from the arXiv samples, without bookmarks.

| What | `main` | After |
|---|---|---|
| First page, flat tree of 30,000 pages | 22.3 s | 2.2 s |
| First page, flat tree of 10,000 pages | 3.0 s | 0.8 s |
| First page, balanced tree of 30,000 pages | 2.3 s | 2.2 s |
| CGPDF asked for each of 30,000 pages by number: flat / balanced | 16.8 s / 0.10 s | not asked |
| `pdf info`, 467 pages without bookmarks | 267 ms | 73 ms |
| `pdf search` a word, same file / pattern | 176 / 261 ms | 76 / 115 ms |
| `pdf ls`, 3 files, 709 pages | 87 ms | 13 ms |
| The first `pdf ls` after the upgrade, which stores the 709 pages' measures | — | 0.6 s, once |
| `pdf read --page 5`, cached | 12 ms | 11 ms |

The 2.2 s left for 30,000 pages is the index's work on each page, its key and font check, about 0.07 ms a page. `pdf info` and a search still decode every page of a file without bookmarks for its headings, about 0.1 ms a page, so G4's 200 ms holds to about 1,400 pages.

## Tests

All 158 unit tests and all 141 end-to-end checks passed. New unit tests:

- `PageTreeTests`, 5 tests. Every page of the 16 test PDFs that open without a password gets, from the walk, the page CGPDF numbers, its key and its font check. Flat and balanced trees of 2,000 pages are walked. Twenty odd boxes and rotations key as CGPDF does, and eight malformed ones are left to CGPDF. Seven trees the walk cannot be sure of are declined: a node listed twice, a wrong count, a page without a type, a page naming another parent, a kid that is no dictionary, a missing kid, a root with a parent. Contents in two streams count both.
- `StoreTests.pagesJudgeAlikeFromTheirLayerAndFromTheStoredMeasures`: seven kinds of page and a failed one judge alike from the layer, from the cache and from the listing, and so do rows cached before the measures were stored.
- `FactsTests.aLongSectionTableIsCut`: a book of 30 chapters shows its chapters, a flat list of 200 its first 40, and a paper all its sections.

New end-to-end checks, 3: on a terminal, through `expect`, `--password-stdin` asks for the password, the typed password opens the locked file, and the output does not show it. The check that a locked file names the password flag now asks for `--password-stdin`.

## Review

Not yet reviewed.
