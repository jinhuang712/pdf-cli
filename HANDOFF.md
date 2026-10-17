# Handoff — 2026-10-17

Where pdf-cli stands, what is in flight, and how the work has been done, for whoever picks it up next: a person, or a new Claude Code session. The project's own docs hold the detail; this file points into them and records what lives only in the working session.

## Where things stand

**On `main`** (pushed): milestone M0 and tasks M1.1–M1.11 and M1.15 of milestone M1.

| Command | Task | What it does |
|---|---|---|
| `pdf add`, `ls`, `rm`, `gc` | M1.5 | The library: parse ahead of time, list, forget, clean up |
| `pdf info` | M1.6 | A first look: title, sections with sizes, flags, comments, attachments, scripts |
| `pdf read` | M1.7 | Text by page, section or printed page, within a 5,000-token budget, with `next:` lines |
| `pdf read --include-hidden` | M1.10 | Text a reader cannot see is a marker in place; this shows its words, labelled |
| `pdf search` | M1.8 | Keyword search per paragraph (SQLite FTS5) and `--regex`, in one PDF or the library |
| `pdf crop` | M1.9 | A page or region as a PNG sized to Claude's image limits |
| `pdf pick` | M1.3 | The agent's choice between two readings of an unsure word |
| `pdf agent-guide` | M1.11 | The guide that teaches an agent the tool; `--install claude-code` writes it as a Claude Code skill |

Under them: worker processes with time and memory limits and a shared pool of slots (M1.1, M1.15), the text layer with the space repair (M1.2), quality checks with failure and unsure blocks (M1.3), Apple OCR for scans (M1.4), and the hidden-text check (M1.10). `README.md` says how to read the rest of the docs.

**M1.10, hidden text,** landed on 2026-10-16, and has had six reviews since; `reports/M1.10-hidden.md` has every finding and its resolution. The design is in DESIGNS.md → "Decision: hidden text found by ink, with the drawing commands for what ink cannot tell" and "Decision: what an image over text hides, from the drawing commands, with OCR where they cannot tell"; the known limits are in FEATURES.md → F9 → Gap. Each round found 8 to 20 problems, most of them ways through for a hostile file, and the limits list grows with each: the check catches the common tricks and many crafted ones, not every one. The reviewers' hostile pages live on as `testdata/hidden/hidden.pdf` (69 pages), `broken.pdf` (11) and `unread.pdf` (2), all made by `scripts/make-hidden-fixture.swift`; their own generators were in `/private/tmp/claude-501/m110rev*`, outside the repo, which macOS clears.

**The TODO list is done** (2026-10-16, its last review fixed on 2026-10-17): the index walks the page tree once, `pdf ls` judges pages from a stored verdict column, a page's layer is decoded once per command, a locked file points to `--password-stdin`, which asks on a terminal, `pdf info`'s section table is capped, and a page whose drawn text PDFKit leaves out is flagged, or read by OCR when it lost 30% or more. The licence notices of `pdf setup`'s models moved to M2.11. Reports: `reports/TODO-page-tree-listing-password.md` and `reports/TODO-text-pdfkit-leaves-out.md`. The second review of the last fixes found 10 problems; 9 are fixed, and the chords a music font stacks stay a limit. Since then a place PDFKit left text out of shows only as its crop: what its strings spell goes out nowhere, `--raw` included, as each review found a new hidden string that `--raw` spelled. Parser version 10, cache schema 8.

**Docs:** GOALS, PHILOSOPHY and PROPOSAL are approved. ROADMAP and README were approved on 2026-10-15. DESIGNS and FEATURES say drafted: the review fixes changed them after that approval, and only the user approves.

## What comes next

1. The user approves DESIGNS and FEATURES, or asks for changes.
2. **M1.11** landed on 2026-10-16: `reports/M1.11-agent-guide.md`. The guide lives in `Sources/PDFCore/AgentGuide.swift`; a new command or flag needs a line there, or a place on the test's short list of flags left out, or `Tests/pdfTests/AgentGuideTests.swift` fails.
3. **M1.12** the smoke set and the safety set of broken and hidden-text PDFs. `testdata/hidden/hidden.pdf` and `broken.pdf` are a start.
4. **M1.13** comments, highlights, form fields and link targets at their positions; **M1.14** a marker with a crop command for every image and drawing.
5. M1's exit criteria: GOALS.md G2, G4, G9, G12, G13, G16 and G17, plus a week of the author's own daily use. Every goal is still unmeasured.

`TODO.md` holds the follow-ups without a milestone: none open.

## How the work has been done

**Each task:**

1. Work in a git worktree under `.claude/worktrees/`, one per task (Claude Code's `EnterWorktree`; the main checkout's `.claude/settings.local.json`, which stays out of git, sets `worktree.baseRef` to `head`, so a worktree starts from local `main`).
2. Build, then test: `scripts/test.sh -j 2` for unit tests, `scripts/test-cache.sh` end to end. Measure with the release build: `swift build -c release -j 2`.
3. Commit, then have a separate agent, one that did not write the code, review the commit: find defects, reproduce them, rank them.
4. Fix what it finds and write `reports/M1.x-<name>.md`: what was built, the measurements, every finding with its resolution, the tests. List it in `reports/README.md`.
5. Fast-forward `main`, remove the worktree, push `main`.

**Rules that came from the user:**

- **Gentle on the laptop.** Run heavy commands with `nice -n 10`, build with `-j 2`, one heavy job at a time.
- **Push `main` after every landing.** Before each push, check that every commit uses the GitHub no-reply address and that no work email appears in the diff.
- **Write every report down** in `reports/`.
- **Docs follow the what-we-build convention.** Each core doc carries a mark on its first line. Any edit sets it back to `drafted`, and only the user approves. A design decision goes in DESIGNS.md as its own section, `## Decision: <title> — <date>`, with the options it beat.
- **Keep going until something breaks or needs a decision.**
- **Replies to the user:** plain words, the answer first, every decision, risk and unknown stated, and short.
- **Commits:** English, ending with the session trailer line.

**Traps:**

- Claude Code refuses compound shell commands with variables inside a worktree, so put such commands in a script file and run it with `bash`.
- The 456-page file used for timing early in M1 is gone. Xcode's `/Library/Developer/CommandLineTools/Library/Developer/Acknowledgments.pdf`, 231 pages, served for M1.10, and macOS's license in 41 languages, `/Library/Documentation/License.lpdf/Contents/Resources/*.lproj/License.pdf`, for false marks.
- A local session has no claude.ai link for the commit trailer; M1.10's last commits carry the local session ID instead.
- macOS clears `/private/tmp`: anything a reviewer makes there must go into `testdata` to last.
- Run the unit tests through `scripts/test.sh`: with the Command Line Tools alone, a plain `swift test` cannot find the Swift Testing framework.
- A `pdf read` or `pdf add` of a large file leaves a background runner parsing its other pages after the command returns. When timing, stop it (`pkill -f <the file's folder>`) before the next run, or it skews the next timing.
- A fixture page for a fix must fail on the build before the fix: three of the sixth review's first pages passed on the old build too, and proved nothing. Compare with the old binary before trusting a page.
- A real-file sweep for false marks: macOS's license in 41 languages, Xcode's acknowledgments, the samples, and TeX Live's manuals under `/usr/local/texlive/2026/texmf-dist/doc`, which hold Type 3 fonts and odd encodings.
