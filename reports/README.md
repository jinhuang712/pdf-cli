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
| M1.10 Hidden text | 2026-10-16 | 3 false alarms, 6 ways through, 6 smaller; 12 fixed, 1 in part, 2 kept. Second review: 7, all fixed. Third: 20, 18 fixed, 2 kept. Fourth: 17, 16 fixed, 1 kept | [M1.10](M1.10-hidden.md) |
| TODO fixes: an unchecked OCR page, a slow open | 2026-10-16 | 2 high, 2 medium, 3 smaller; 6 fixed, 1 in part | [TODO fixes](TODO-ocr-check-and-slow-open.md) |
| M1.11 `pdf agent-guide` and its skill | 2026-10-16 | 1 high, 3 medium, 8 smaller; 10 fixed, 2 in part | [M1.11](M1.11-agent-guide.md) |
| TODO fixes: one walk of the page tree, cheap listings, the password prompt | 2026-10-16 | Not yet reviewed | [TODO fixes](TODO-page-tree-listing-password.md) |
