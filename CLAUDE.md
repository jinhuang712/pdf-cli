# pdf-cli: how to work here

Read this first. Where the project stands is in ROADMAP.md, the small follow-ups in TODO.md, each task's findings in `reports/`, the commands in FEATURES.md and the design in DESIGNS.md; this file holds only the direction the user has set and the way to work.

## The user's direction

Read this before designing anything. Each line points to where it is written down.

- **The tool converts nothing it cannot read for certain.** A table, an equation, a figure or a page OCR reads badly goes to the agent as a crop, and the agent's own model reads it. Rules or OCR cannot promise a table or a LaTeX right, and a wrong one looks right. The tool's job is to cut the tokens, the cost and the time an agent spends on a PDF. DESIGNS.md → "Decision: the agent reads figures, tables and equations from their crops, and its LaTeX is kept".
- **What the agent reads is kept, so it is read once.** An equation's LaTeX, or a table's Markdown, that the agent writes back with `pdf transcribe` is kept beside its picks, and later reads show it in place, labelled as its reading, with the crop to check it by (M2.13).
- **No local vision model.** PDFKit and Apple's OCR read; the agent looks. M3.3 is dropped, and GOALS.md measures two setups, Base and Layout; Layout adds what `pdf setup` downloads, which is nothing until a task brings a model, as M2.4's layout model, built only if rules fail a goal, or, for M3.1's search by meaning, an embedding model if Apple's built-in embeddings fall short (DESIGNS.md → Open questions). The user holds that PDFKit and OCR suffice; no goal has measured it yet. DESIGNS.md → "Decision: no local vision model; PDFKit and Apple's OCR read, the agent looks".
- **Nothing a reader cannot see reaches normal output, and nothing is dropped without a trace.** Hidden text, a picture's alt text among it, is a marker, its words only with `--include-hidden` (goal G16). Whatever is set aside, as a running header or a table's flat text, is counted in the summary line with the flag that shows it.
- **Tests stay light until the final wrap-up:** unit tests, end-to-end tests and one review per task. The detailed test sets, measurements and tuning wait for the end (ROADMAP.md → Final wrap-up).
- **Sample PDFs stay local.** The 132 downloaded test PDFs, 669 MB, live in the main checkout's `private/testset/`, which `.gitignore` keeps out, and are never committed. The open test set of the final wrap-up (M2.1) takes 60 of them. `manifest.tsv` there gives each one's source, licence and SHA-256, and `fetch_testset.py` downloads them again. New downloads wait for the user's OK on the sources.

## Versions

Parser version 18, page key 2, index checks 10, cache schema 8: raise the parser version when the parse's output changes, the page key's when what it hashes changes, and the index checks when the index's checks change.

## How to work

**Each task:**

1. Start a new session for it (never a fork: a fork keeps the long history), in a git worktree under `.claude/worktrees/` (the main checkout's `.claude/settings.local.json`, out of git, sets `worktree.baseRef` to `head`, so a worktree starts from local `main`).
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

- A new task wants a new session with a short history. `calm fork` copies the whole conversation, so it is no new session; Calm has no command that opens a blank one: let the user open it. There is no handoff file: where the project stands is ROADMAP.md, what has no milestone is TODO.md, what each task found is `reports/`.
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
