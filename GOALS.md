<!-- what-we-build: drafted 2026-10-15 -->
# Goals

Each goal is a check with a number. Unless a row says otherwise, goals are measured on an M3 MacBook with 24 GB, against two sets the project builds: the open test set (60 open-access PDFs: 20 journal papers, 10 textbook chapters, 10 reports, 10 essays or articles, 10 scans) and the question set (200 questions, each with a known answer and the page that holds it). The open test set includes Word-made files, pages with dense tables, and scans that carry an old OCR text layer.

Every goal is measured in three setups and reported side by side: **Base** (the `pdf` binary with macOS's own PDFKit and Vision, nothing downloaded), **Layout** (Base plus the models from `pdf setup`) and **Full** (Layout plus the local vision model from `pdf setup vlm`). Every target must pass in Base, following the principle "Apple's engines first" in [DESIGNS.md](DESIGNS.md). A target moves to Layout or Full only when Base misses it and a model closes the gap.

| # | Goal | Want | Measure | Method | Measured on | Status |
|---|---|---|---|---|---|---|
| G1 | Tokens per question | Cheap | ≤ 20% of the tokens spent reading the PDF directly | Run the question set in Claude Code twice, once with pdf-cli and once with the built-in Read tool, and compare the token counts | Question set | ⬜ Open |
| G2 | First page on an unseen PDF | Fast | ≤ 2 s until the requested page is readable | A script times `pdf read --page N` with an empty cache | Open test set, scans excluded | ⬜ Open |
| G3 | Full parse speed | Fast | ≤ 0.5 s per page on average | A script times a full parse of every PDF | Open test set, scans excluded | ⬜ Open |
| G4 | Cached reads | Fast | ≤ 200 ms for `pdf info` or `pdf read` | A script runs both commands on every cached PDF | Open test set | ⬜ Open |
| G5 | Answers | Accurate | Right answers with pdf-cli ≥ right answers with direct reading, and wrong answers ≤ wrong answers with direct reading | Grade the G1 runs against the known answers | Question set | ⬜ Open |
| G6 | Text and reading order | Accurate | Score ≥ Docling's score, with a wrong block weighted 3× a missing one | A scorer script, with Docling run on the same Mac | OmniDocBench and the open test set | ⬜ Open |
| G7 | Footnotes | Accurate | ≥ 95% of footnotes kept out of the body text | Compare the output with the labelled footnotes | Open test set | ⬜ Open |
| G8 | Figures and tables | Sees figures | ≥ 95% of figures and tables found, vector charts included, each crop holding the whole figure or table and its caption | Compare the crops with the labelled figures and tables | Open test set | ⬜ Open |
| G9 | Reuse | Reusable | 0 pages parsed again when a file is read again unchanged, or with only new highlights | A script counts parse jobs | Open test set | ⬜ Open |
| G10 | Search | Searchable | The right page in the top 5 results for ≥ 90% of queries, Chinese queries included | Run the question set's queries through `pdf search` | Question set | ⬜ Open |
| G11 | Flags | Honest | ≥ 95% of bad pages flagged, and ≤ 10% of good pages flagged | Compare the flags with the pages labelled bad | Open test set | ⬜ Open |
| G12 | Addresses | Traceable | 100% of output blocks carry a page and a position | A schema check in CI | Open test set | ⬜ Open |
| G13 | Offline parsing | Private | 0 network connections while parsing | Parse under a network monitor | Open test set | ⬜ Open |
| G14 | Install | Easy | ≤ 2 minutes from install to first result, and ≤ 500 MB installed, models included | Install on a fresh macOS user account and time it | Fresh macOS user account | ⬜ Open |
| G15 | Commands | Easy | ≥ 95% of agent commands work on the first try | Read the command log from the G1 runs | Question set | ⬜ Open |
| G16 | Hostile PDFs | Safe | 100% of planted hidden text flagged and kept out of normal output, and 0 crashes or hangs | Run the safety test set | Safety test set: planted hidden text and broken PDFs | ⬜ Open |
| G17 | Nothing missing | Honest | 100% of the text runs, images, annotations, form fields, attachments and scripts in a file reach the output as text or a marker | A script lists every object that PDFKit and Core Graphics report, and finds each one in the output | Open test set and safety test set | ⬜ Open |
