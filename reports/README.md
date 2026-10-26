# Reports

Each task gets one report: what was built, what was measured, what the independent review found with how each finding was resolved, and which tests ran. A report is written on the task's branch before the task lands, and then stays as written, as the record of that day. The current design lives in [DESIGNS.md](../DESIGNS.md), and follow-ups without a milestone in [TODO.md](../TODO.md).

- **Machine:** an M3 MacBook with 24 GB, macOS 26.4, unless a report says otherwise.
- **Reviews:** each one comes from a separate Claude agent that did not write the code. It reads the commit, builds it, and reproduces what it can. Its verdicts are *confirmed* (reproduced or proven by reading) or *likely* (traced, not reproduced).
- **Written after the fact:** the reports for M1.1 to M1.7 were written on 2026-10-15, after those tasks landed, from the reviewers' reports and the session's notes. Where a report says *not re-checked*, the resolution comes from the notes alone.

The spike's reports (M0) are in [spike/](../spike/README.md).

| Task | Landed | Review | Report |
|---|---|---|---|
| M1.1 Worker processes and the cache | 2026-10-15 | 1 high, 2 medium, 4 low; 6 fixed, 1 partly | [M1.1](M1.1-workers-and-cache.md) |
| M1.2 Text layer, font check, space repair | 2026-10-15 | 1 high, 7 smaller; all fixed | [M1.2](M1.2-text-layer.md) |
| M1.4 Apple OCR | 2026-10-15 | 3 confirmed, 5 smaller; all fixed | [M1.4](M1.4-ocr.md) |
| M1.15 Worker pool | 2026-10-15 | 1 confirmed, 3 likely, 2 doc gaps; all fixed | [M1.15](M1.15-worker-pool.md) |
| M1.3 Quality checks | 2026-10-15 | no wrong text; 10 smaller; all but 1 fixed | [M1.3](M1.3-quality-checks.md) |
| M1.5 Library commands | 2026-10-15 | 2 data bugs, 8 smaller; all but 1 fixed | [M1.5](M1.5-library.md) |
| M1.7 `pdf read` | 2026-10-15 | 1 wrong text, 1 endless loop, 7 smaller; all fixed | [M1.7](M1.7-read.md) |
| M1.6 `pdf info` | 2026-10-15 | 1 crash, 3 that fail readable files, 8 smaller; all fixed, 1 in part. Second review: 5 more, 4 fixed, 1 bounded | [M1.6](M1.6-info.md) |
| M1.8 `pdf search` | 2026-10-15 | 1 hang, 9 smaller; all fixed | [M1.8](M1.8-search.md) |
| M1.9 `pdf crop` | 2026-10-15 | 2 high, 3 smaller; all fixed | [M1.9](M1.9-crop.md) |
| M1.10 Hidden text | 2026-10-16 | 3 false alarms, 6 ways through, 6 smaller; 12 fixed, 1 in part, 2 kept. Second review: 7, all fixed. Third: 20, 18 fixed, 2 kept. Fourth: 17, 16 fixed, 1 kept. Fifth: 11, 10 fixed, 1 in part. Sixth: 8, 4 fixed, 4 kept | [M1.10](M1.10-hidden.md) |
| TODO fixes: an unchecked OCR page, a slow open | 2026-10-16 | 2 high, 2 medium, 3 smaller; 6 fixed, 1 in part | [TODO fixes](TODO-ocr-check-and-slow-open.md) |
| M1.11 `pdf agent-guide` and its skill | 2026-10-16 | 1 high, 3 medium, 8 smaller; 10 fixed, 2 in part | [M1.11](M1.11-agent-guide.md) |
| TODO fixes: one walk of the page tree, cheap listings, the password prompt | 2026-10-16 | 1 high, 1 medium, 8 smaller; 8 fixed, 2 kept | [TODO fixes](TODO-page-tree-listing-password.md) |
| TODO fix: text PDFKit leaves out flags the page | 2026-10-16 | 1 high, 3 medium, 6 smaller; all fixed. Second review, 2026-10-17: 10, 9 fixed, 1 kept. Third: 8, 6 fixed, 2 kept | [TODO fix](TODO-text-pdfkit-leaves-out.md) |
| M1.12 Smoke set and safety set | 2026-10-17 | 2 high, 1 medium, 5 smaller; 7 fixed, 1 in part | [M1.12](M1.12-test-sets.md) |
| M1.13 Comments, highlights, form fields and links | 2026-10-17 | 3 high, 2 medium-high, 2 smaller; 6 fixed, 1 kept | [M1.13](M1.13-annotations.md) |
| M1.14 Images and drawings marked in place | 2026-10-17 | 2 high, 6 medium, 3 low; 8 fixed, 1 in part, 2 kept | [M1.14](M1.14-pictures.md) |
| M2.5 Reading order across columns, running headers set aside | 2026-10-17 | 2 high, 4 medium, 4 low; 7 fixed, 3 kept | [M2.5](M2.5-columns-headers.md) |
| M2.6 Figures, tables and equations as blocks with their crops | 2026-10-18 | 4 high, 3 medium, 5 low; 9 fixed, 2 in part, 1 kept | [M2.6](M2.6-figures-tables-equations.md) |
| M2.13 The agent's LaTeX and Markdown kept for later reads | 2026-10-18 | 1 high, 4 medium, 4 low, and 1 in M2.6; all fixed | [M2.13](M2.13-transcribe.md) |
| M2.7 Footnotes, endnotes, headnotes, margin notes and author notes | 2026-10-18 | 4 high, 9 medium, 7 low; 13 fixed, 5 in part, 2 kept | [M2.7](M2.7-notes.md) |
| M2.8 Citations, references and cross-references | 2026-10-25 | 3 high, 4 medium, 5 low; 5 fixed, 7 kept | [M2.8](M2.8-citations.md) |
| M2.9 `pdf dump` | 2026-10-25 | 4 high, 6 medium, 8 low; 14 fixed, 4 kept | [M2.9](M2.9-dump.md) |
| M2.14 `--help` that teaches | 2026-10-25 | 0 high; 9 fixed, 1 kept, 2 to M2.15 | [M2.14](M2.14-help.md) |
| M2.15 One output contract | 2026-10-25 | 1 high, 6 medium, 7 low; 8 fixed, 6 kept | [M2.15](M2.15-contract.md) |
| M2.16 `pdf note` and `pdf ref` | 2026-10-25 | 0 high, 1 medium, 6 low; 7 fixed | [M2.16](M2.16-note-ref.md) |
| M2.17 `--show raw,hidden,headers` | 2026-10-25 | 0 high, 0 medium; 6 fixed, 3 kept | [M2.17](M2.17-show.md) |
| M2.18 `--dry-run` | 2026-10-25 | 0 high; 10 fixed, 1 kept | [M2.18](M2.18-dry-run.md) |
| M2.10 `pdf reparse` | 2026-10-25 | 1 high, 4 medium, 5 low; 10 fixed, 5 kept | [M2.10](M2.10-reparse.md) |
| M2.11 `pdf setup`, `pdf doctor`, `gc` into `doctor --clean` | 2026-10-25 | 1 high, 5 medium, 9 low; 15 fixed | [M2.11](M2.11-setup-doctor.md) |
| M2.19 Hidden text through OCR | 2026-10-25 | 2 high, 3 medium, 2 low; 7 fixed, limits recorded | [M2.19](M2.19-ocr-hidden.md) |
| M2.20 Small command-layer fixes | 2026-10-25 | 1 high, 2 medium, 6 low; 9 fixed | [M2.20](M2.20-cli-fixes.md) |
| M2.21 Limits on big files | 2026-10-25 | 1 high, 4 medium, 9 low; 13 fixed, 1 kept | [M2.21](M2.21-limits.md) |
| M2.21b Links past 1,000 in a table of their own | 2026-10-25 | 0 high, 3 medium, 7 low; 9 fixed, 1 recorded | [M2.21b](M2.21b-links.md) |
| M2.22 `pdf search` leaves out running headers | 2026-10-25 | 1 high, 4 medium, 3 low; 7 fixed, cost recorded | [M2.22](M2.22-search-headers.md) |
| M2.23 A reparse keeps picks that still apply | 2026-10-25 | 0 high, 1 medium (open design question), 9 low; 8 fixed, 1 not testable | [M2.23](M2.23-keep-picks.md) |
| M2.24 A reparse never deletes picks | 2026-10-25 | 0 high, 3 medium, 6 low; all fixed, doctor report left in TODO | [M2.24](M2.24-picks-stay.md) |
| M2.26 Search reads stored edge summaries; refs DOIs | 2026-10-26 | 1 high, 2 medium, 4 low; all fixed | [M2.26](M2.26-search-summary.md) |
| M3.2 Tables that continue across pages | 2026-10-26 | 1 high, 4 medium, lows bundled; all fixed but mirrored margins and the two-studies guard, recorded | [M3.2](M3.2-tables-across-pages.md) |
| M3.7 CLI polish after the agent-usability review | 2026-10-26 | 0 high, 2 medium, 2 low groups; all fixed, dump/read and pick/transcribe overlap left open | [M3.7](M3.7-cli-polish.md) |
