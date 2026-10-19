# Handoff — 2026-10-19

For whoever picks up pdf-cli next, a person or a new Claude Code session. Read this file first: it says where the project stands, what waits on the user, the direction the user has set, what to build next and how. The other docs hold the detail; `README.md` lists them.

## Where things stand

- **Built and on `main`** (pushed): milestone M0; every task of M1, M1.1–M1.15; and M2.5, M2.6, M2.7 and M2.13 of M2.
- **Half-done, on a branch:** M2.8, citations and references, on `claude/m2-8-citations`, pushed to origin and not on `main`. It is built and committed, and the unit tests and `scripts/test-cache.sh` pass; the sweep, the review, the report and the landing are left. Its edits to DESIGNS.md, FEATURES.md and ROADMAP.md are on the branch, marked `drafted`.
- **Not met yet:** the exit criteria of M1 and M2. They need the goals measured, and every goal in GOALS.md is still unmeasured: the measuring waits for the final wrap-up (the user, 2026-10-17).
- **Docs:** all seven core docs on `main` are approved: the user approved them on 2026-10-18 with the direction below, M2.13's edits the same day, and M2.7's on 2026-10-19.
- **Waiting on the user:** nothing. Next is the rest of M2.8, below.

## The user's direction

Read this before designing anything. Each line points to where it is written down.

- **The tool converts nothing it cannot read for certain.** A table, an equation, a figure or a page OCR reads badly goes to the agent as a crop, and the agent's own model reads it. Rules or OCR cannot promise a table or a LaTeX right, and a wrong one looks right. The tool's job is to cut the tokens, the cost and the time an agent spends on a PDF. DESIGNS.md → "Decision: the agent reads figures, tables and equations from their crops, and its LaTeX is kept".
- **What the agent reads is kept, so it is read once.** An equation's LaTeX, or a table's Markdown, that the agent writes back with `pdf transcribe` is kept beside its picks, and later reads show it in place, labelled as its reading, with the crop to check it by (M2.13).
- **No local vision model.** PDFKit and Apple's OCR read; the agent looks. M3.3 is dropped, and GOALS.md measures two setups, Base and Layout; Layout adds what `pdf setup` downloads, which is nothing until a task brings a model, as M2.4's layout model, built only if rules fail a goal, or, for M3.1's search by meaning, an embedding model if Apple's built-in embeddings fall short (DESIGNS.md → Open questions). The user holds that PDFKit and OCR suffice; no goal has measured it yet. DESIGNS.md → "Decision: no local vision model; PDFKit and Apple's OCR read, the agent looks".
- **Nothing a reader cannot see reaches normal output, and nothing is dropped without a trace.** Hidden text, a picture's alt text among it, is a marker, its words only with `--include-hidden` (goal G16). Whatever is set aside, as a running header or a table's flat text, is counted in the summary line with the flag that shows it.
- **Tests stay light until the final wrap-up:** unit tests, end-to-end tests and one review per task. The detailed test sets, measurements and tuning wait for the end (ROADMAP.md → Final wrap-up).
- **Sample PDFs stay local.** The 132 downloaded test PDFs, 669 MB, live in the main checkout's `private/testset/`, which `.gitignore` keeps out, and are never committed. The open test set of the final wrap-up (M2.1) takes 60 of them. `manifest.tsv` there gives each one's source, licence and SHA-256, and `fetch_testset.py` downloads them again. New downloads wait for the user's OK on the sources.

## What is built

| Command | Task | What it does |
|---|---|---|
| `pdf add`, `ls`, `rm`, `gc` | M1.5 | The library: parse ahead of time, list, forget, clean up |
| `pdf info` | M1.6, M2.6, M2.7 | A first look: title, sections with sizes, flags, comments, attachments, scripts, running headers, figures and tables, author notes and note counts |
| `pdf read` | M1.7 | Text by page, section or printed page, within a 5,000-token budget, with `next:` lines |
| `pdf read --include-hidden` | M1.10 | Text a reader cannot see is a marker in place; this shows its words, labelled |
| `pdf read --raw` | M1.3, M2.6 | Shows the text set aside: doubtful text, an old OCR layer, a table's or a figure's flat text |
| `pdf read --headers` | M2.5 | Shows the running headers, footers and page numbers set aside |
| `pdf read --notes end\|inline\|off`, `--footnote ID` | M2.7 | Footnotes and endnotes as `[^7]` in the text, their words after the output, by their paragraph or left out and counted; one note with the places that cite it. Margin notes after their paragraph, a headnote labelled in place |
| `pdf search` | M1.8 | Keyword search per paragraph (SQLite FTS5) and `--regex`, in one PDF or the library |
| `pdf crop` | M1.9, M2.6 | A page, a region, or a figure, a table or an equation by its number, as a PNG sized to Claude's image limits |
| `pdf pick` | M1.3 | The agent's choice between two readings of an unsure word, kept beside the library |
| `pdf transcribe` | M2.13 | The LaTeX of an equation, or the Markdown of a table, that the agent read from its crop, kept so later reads show it |
| `pdf agent-guide` | M1.11 | The guide that teaches an agent the tool; `--install claude-code` writes it as a Claude Code skill |

Under them: worker processes with time and memory limits and one pool of slots (M1.1, M1.15); the text layer with the space repair (M1.2); quality checks with failure and unsure blocks (M1.3); Apple OCR for scans (M1.4); the hidden-text check (M1.10); annotations (M1.13); images and drawings marked in place (M1.14); reading order across columns and running headers (M2.5); figures, tables and equations (M2.6); footnotes, endnotes, headnotes and margin notes (M2.7). Parser version 17, page key 2, index checks 10, cache schema 8: raise the parser version when the parse's output changes, the page key's when what it hashes changes, and the index checks when the index's checks change.

## What comes next

1. **Finish M2.8** on its branch, from step 3 of "How to work" below. The branch's `reports/M2.8-citations.md`, a draft, says what is built, what was checked and what is left.
   - Work in a worktree of the branch: `git worktree add .claude/worktrees/m2-8 claude/m2-8-citations`, or the one it was built in, `.claude/worktrees/pdf-cli-work-36ac3a`, if it is still there.
   - Sweep `private/testset/` with the release build, against `main`'s build in a scratch worktree. The notes must not move, since the parse changed: a hanging indent now starts a block. Count the lists, entries, citations and links found, and time the books.
   - Then the review on Opus, the fixes, the report finished and listed in `reports/README.md`, this file's rows for M2.8 (where things stand, what is built: `--ref`, `--refs`, parser version 18, the landed tasks), and the landing. This note is on `main` and the branch sits on it, so `merge --ff-only` works.
2. **The rest of M2,** in ROADMAP's order, which is the order of building; a task's ID is its name, not its place, so M2.13, added last, was built before M2.7: M2.9 `pdf dump`, M2.10 `pdf reparse`, which clears the picks of the pages it parses again but should keep their transcripts, read from the image, which a parse leaves as it is, M2.11 `pdf setup` and `pdf doctor`. M2.4, a layout model, comes only if a goal fails with rules alone.
3. **M3:** M3.1 search by meaning, M3.2 tables across pages, M3.5 the Homebrew release.
4. **The final wrap-up:** the open test set, the question set and the scorer (M2.1–M2.3), the quality thresholds (M2.12), the question set run in Claude Code (M3.6), the workers' memory, and every goal measured.

`TODO.md` holds five follow-ups with no milestone: a content stream that inflates to 600 MB, links past the first 1,000 of a file, the cost of joining shapes into drawings, running headers that `pdf search` still finds, and `pdf crop --figure N` parsing a whole long file before it says the number is not there.

## How to work

**Each task:**

1. Start a new session for it, in a git worktree under `.claude/worktrees/` (the main checkout's `.claude/settings.local.json`, out of git, sets `worktree.baseRef` to `head`, so a worktree starts from local `main`).
2. Build, then test: `nice -n 10 swift build -j 2`, `nice -n 10 scripts/test.sh -j 2` for unit tests, `scripts/test-cache.sh` end to end, which runs `scripts/smoke-check.sh` and `scripts/safety-check.sh`. Measure with the release build: `swift build -c release -j 2`.
3. Commit, then have a separate agent that did not write the code review the commit, on Opus: find defects, reproduce them, rank them. Fix what is high or cheap and record the rest.
4. Write `reports/<task>-<name>.md`: what was built, the measurements, every finding with its resolution, the tests. List it in `reports/README.md`.
5. Land it: from the worktree, check that main has not moved (`git fetch origin`, then `main` and `origin/main` equal), fast-forward the main checkout with `git -C <main checkout> merge --ff-only <task branch>`, and push with `git -C <main checkout> push origin main`.

**Rules from the user:**

- **Gentle on the laptop.** Heavy commands with `nice -n 10`, builds with `-j 2`, one heavy job at a time.
- **Commits** in English, written to a file, ending with the session trailer line, `Claude-Session: <the session's ID>`, with the GitHub no-reply address: `git -c user.email=36698563+jinhuang712@users.noreply.github.com commit -F <file>`. The global git email must not be used. Before each push, check that every commit uses the no-reply address and that no work email appears in the diff.
- **Docs follow the what-we-build convention.** Each core doc carries a mark on its first line. Any edit sets it back to `drafted`, and only the user approves. A design decision goes in DESIGNS.md as its own section, `## Decision: <title> — <date>`, with the options it beat.
- **Keep going until something breaks or needs a decision.**
- **Replies to the user** in Chinese, plain words, the answer first, every decision, risk and unknown stated, and short. Ask with the question tool when a decision is the user's.

**Where things live:**

- Each task's report, with its review's findings: `reports/`, listed in `reports/README.md`. Read the report of the last task that touched the code you change.
- The known limits of each feature: FEATURES.md, under each feature's Gap.
- The agent guide: `Sources/PDFCore/AgentGuide.swift`. A new command or flag needs a line there, or a place on the test's short list of flags left out, or `Tests/pdfTests/AgentGuideTests.swift` fails. The guide stays under 2,000 tokens, which the test checks.
- Test fixtures: `testdata/smoke`, 11 real files, 10 arXiv papers and a scan, their flags held in `expected-flags.tsv`; `testdata/safety`, 26 made files: one hidden-text trick each, files that carry comments, links and the like, and broken and hostile files, their planted strings in `planted.tsv`; `testdata/hidden`, the hidden-text reviews' hostile pages; and `testdata/notes`, the M2.7 review's made pages of notes, lists, units and margin floods. `scripts/make-hidden-fixture.swift` makes the files of the last two, the same bytes each run.

**Traps:**

- A new task wants a new session that starts from this file, with a short history. `calm fork` copies the whole conversation, so it is no new session; Calm has no command that opens a blank one. Where no tool starts one, hand off and let the user open it.
- Claude Code refuses compound shell commands with variables inside a worktree: put them in a script file and run it with `bash`.
- `git stash` is shared with every other session: never use it. To compare with the build before a change, add a scratch worktree of the old commit outside the repo, build it there, and remove it after.
- A cache built at the same parser version hides a change to the parse: debug with a fresh `PDF_CLI_HOME` each run.
- A fixture for a fix must fail on the build before the fix; compare with the old build before trusting it.
- Run the unit tests through `scripts/test.sh`: with the Command Line Tools alone, a plain `swift test` cannot find the Swift Testing framework.
- A change that moves unsure words in or out of a region changes the smoke set's flags: update `testdata/smoke/expected-flags.tsv` and say why in the report.
- A `pdf read` or `pdf add` of a large file leaves a runner parsing its other pages after the command returns. When timing, stop it (`pkill -f <the file's folder>`) first.
- macOS clears `/private/tmp`: anything a reviewer makes there must go into `testdata` to last.
- Read annotations with CGPDF, never with PDFKit's annotation objects: PDFKit followed a link action chained to itself until it crashed.
- Files for a sweep for false marks: macOS's license in 41 languages, `/Library/Documentation/License.lpdf/Contents/Resources/*.lproj/License.pdf`; Xcode's `/Library/Developer/CommandLineTools/Library/Developer/Acknowledgments.pdf`, 231 pages; and TeX Live's manuals under `/usr/local/texlive/2026/texmf-dist/doc`, with Type 3 fonts and odd encodings.

## Landed tasks

Each report holds the measurements, the review's findings and the tests.

| Task | Landed | What to know | Report |
|---|---|---|---|
| M1.1–M1.9, M1.15 | 2026-10-15 | The cache, workers, text layer, quality checks, OCR, library, info, read, search, crop | `reports/README.md` lists each |
| M1.10 Hidden text | 2026-10-16 | Six reviews, 8 to 20 problems each, most of them ways through for a hostile file: the check catches the common tricks and many crafted ones, not every one. Limits in FEATURES.md → F9 → Gap. | `M1.10-hidden.md` |
| TODO fixes | 2026-10-16, 10-17 | A place PDFKit leaves text out of shows only as its crop: its strings go out nowhere, `--raw` included. | `TODO-*.md` |
| M1.11 Agent guide | 2026-10-16 | | `M1.11-agent-guide.md` |
| M1.12 Test sets | 2026-10-17 | A page whose content stream does not decode is flagged, never read as an empty page. | `M1.12-test-sets.md` |
| M1.13 Annotations | 2026-10-17 | They come from the file's facts, so a file that gains highlights shows them with no page parsed again. | `M1.13-annotations.md` |
| M1.14 Pictures | 2026-10-17 | Images and drawings are markers with their crop commands. A stamp with no text of its own never shows its `/Name`, which a reader never sees and which could spell a planted line. | `M1.14-pictures.md` |
| M2.5 Columns and running headers | 2026-10-17 | Only a band of two columns of running text moves; running headers are judged at read time against the pages within 4. A block with hidden text is never set aside. | `M2.5-columns-headers.md` |
| M2.13 The agent's LaTeX and Markdown kept | 2026-10-18 | `pdf transcribe` keeps what the agent read from a crop, beside the picks, by page key and the number the page gives; each line goes out four spaces in, so none forges the output's structure. Its review found 9 problems, all fixed, and one in M2.6's equation numbers, as "(A.1)", fixed too: parser version 16. | `M2.13-transcribe.md` |
| M2.6 Figures, tables and equations | 2026-10-18 | Found by rules from numbered captions, pictures and drawn shapes, rules, and an equation's number set apart. 64 figures, 77 tables and 84 equations on the smoke papers. A region never takes running text; a block with hidden text is never set aside. Its review found 12 problems: 9 fixed, 2 in part, 1 kept. | `M2.6-figures-tables-equations.md` |
| M2.7 Notes | 2026-10-18 | Found by rules from a size per line, markers and positions; which pages are lists, the references and the IDs are judged at read time against the pages parsed so far. Endnotes find their references all at once, the longest common subsequence of their markers before their lists, so a chapter whose markers are lost costs only its own links; a list the text never cites is none. A note counts against the budget where the read takes it. Its review found 20 problems: 13 fixed, 5 in part, 2 kept. | `M2.7-notes.md` |
