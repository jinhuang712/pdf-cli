# TODO fixes — an unchecked OCR page, a slow file open

- **Built:** 2026-10-16, two items from `TODO.md`, picked by the user.
- **Written:** 2026-10-16, on the fixes' branch.

## What was built

- **An OCR'd page whose second reading failed is low-quality.** OCR reads a scan's page twice and scores how far the readings agree (DESIGNS.md → Decision: two OCR readings compared, over OCR's own confidence). When the second reading failed, the page had no score and read as ok, with no sign that nothing checked its text. `PageText.checkFailed` now records the failure, for a page with at least 20 words of four letters or more, the fewest a check scores, and the page gets a failure block: "OCR read the page, but its second reading, which checks the first, failed", with the crop and `--raw` commands. A test plants the failure with `PDF_CLI_TEST_FAULT=ocr-check-fail:N`. Parser version 8.
- **A slow file open is not damage.** The runner stopped a worker silent for 30 s, opening included, and three such stops cached the file as damaged until it changed, as an iCloud file still downloading, or one on a slow volume, could earn. Now an index or page worker gets 90 s, `PDF_CLI_OPEN_TIME_LIMIT`, until its first event; the sample check and the facts, which say nothing until they finish, keep their own limits. A file that takes longer gets the verdict "slow to open: it took more than 90 s to open, and is tried again after 10 minutes". Commands in those 10 minutes, `PDF_CLI_SLOW_OPEN_RETRY`, get it at once; after them, the cache treats it as unknown and a command opens the file again. Verdicts the old rule cached as damaged for a slow open are tried again too. Tests plant a hanging open with `open-hang:0` and a 4 s one with `open-slow:0`.
- `TODO.md` drops the two items, updates the one on text PDFKit leaves out now that M1.10's scanner places every string, and notes that M1.10's fourth-review fixes have had no review of their own. The reports index shows M1.10 landed.

## Review

A separate agent reviewed `37be00d`, the first version, and reproduced most of what it found with scaled-down limits. The OCR fix held. The slow-open fix did not, and was redone.

| # | Finding | Verdict | Resolution |
|---|---|---|---|
| 1 | The open limit applied to any worker until its first event, so the sample check and the facts, which report only at the end, ran 120 s where they had 30 and 10: a hanging facts worker held a new file's first page about 240 s, and its failure said the file took long to open. | Confirmed, high | Fixed: only index and page workers get the open limit. |
| 2 | A file that never opens cost 2 × 120 s on every command, never cached, past the 120 s an agent's command commonly gets, so the agent never saw why. | Confirmed, high | Fixed: one 90 s try, then the verdict, which commands in the next 10 minutes get at once; a check measures the second command's answer in under 2 s. |
| 3 | Commands raced to forget a fresh "slow" verdict, so even the command that started the runner could wait another round. | Confirmed, medium | Fixed: no command forgets it; the cache treats the verdict as unknown only once it is 10 minutes old. |
| 4 | The open limit could not go under the page limit, the message gave the wrong number, and the check did not test the fix: nothing showed a slow open succeeding. | Confirmed, medium | Fixed: the limit applies as set and the message gives it; a new check opens a file in 4 s against a 2 s page limit and reads it. |
| 5 | Files the old rule cached as damaged for a slow open stayed damaged after an upgrade. | Confirmed, low-medium | Fixed: the cache tries them again. |
| 6 | Slow opens elsewhere: a page worker's slow open fails its pages by content key; a restarted index's slow reopen counted toward "damaged"; `pdf crop` keeps 30 s, open included; a background page worker cannot be brought to full speed before its first event. | Likely, low | The restarted index now gets the slow verdict. The rest is kept: a page worker opens a file the index has just opened, which is quick, and a crop or a background page waits at most its limit. |
| 7 | A page too small for the second reading, as under 1 pt, was flagged, where a check that ran could not have scored it either. | Confirmed in Vision, very low | Fixed: only a page with 20 words or more to score is flagged. |
| — | DESIGNS said the limit covered opening only, and that a slow file fails only the command that tried it. | Confirmed | Fixed with the code. |

The first end-to-end run of `37be00d` failed one check, "three new files at once never run more than the pool's two workers", with 4 workers seen. The check counts worker processes across the Mac, another session ran its tests at the time, and the reviewer's run passed it; it passed again after the fixes.

## Tests

All 139 unit tests and all 124 end-to-end checks passed, 6 of the checks new: a scan page whose second reading failed is low-quality; a file that opens in 4 s against a 2 s page limit reads; a file that hangs while it opens is slow to open, not damaged; the next command gets that verdict in under 2 s, without opening the file; and once the verdict is old enough, a command reads the file. The redone slow-open fix was not reviewed again.

One unit test is new: an OCR'd page whose second reading failed is low-quality as a whole, with no score, and its failure block names the reason and the crop.
