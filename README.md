<!-- what-we-build: drafted 2026-10-29 -->
# pdf-cli

> A PDF CLI tool that lets you read fast, cheap and accurately.

pdf-cli lets coding agents such as Claude Code read PDFs on your Mac. It parses each PDF once, hands the agent only the parts it asks for, and flags every page it could not read well instead of guessing.

## What it does

- It parses each PDF once and caches it, so later reads come straight from the cache.
- It gives the agent a map first: the outline, each section's size and the figure list. Then it serves pages, sections, footnotes and references on request.
- It searches one PDF or your whole library, by keyword.
- It crops a figure, a table or any region as an image, for the agent's own image understanding.
- It flags every page it could not read well, with a command to read that page as an image instead.
- It drops nothing silently. Hidden text, doubtful text, comments and attachments each leave a marker in place, with the command that shows them.
- It runs entirely on your Mac, with Apple's PDF, OCR and Neural Engine frameworks. Nothing is uploaded.

The full behavior is in [FEATURES.md](FEATURES.md).

## Install

Not available yet. The spike is done, and the first usable version is milestone M1 in [plan/ROADMAP.md](plan/ROADMAP.md). The planned install is one Homebrew command, and the command it installs is `pdf`.

## Use

The first four work today, built from source, and so does cropping a page or a region of it with `pdf crop paper.pdf --page 7 --bbox 0.1,0.4,0.8,0.3`. So does reading footnotes and endnotes, with `pdf note paper.pdf 7`, and the references a paper cites, with `pdf ref paper.pdf 12`. `pdf agent-guide --install claude-code` teaches Claude Code the tool, as a skill.

| When the agent wants to | It runs |
|---|---|
| Get a first look at a paper | `pdf info paper.pdf` |
| Read one section | `pdf read paper.pdf --section Experiments` |
| Find a passage across every PDF | `pdf search "dropout ablation"` |
| Look at a chart | `pdf crop paper.pdf --figure 4` |
| Read a footnote, or a cited reference | `pdf note paper.pdf 7` or `pdf ref paper.pdf 12` |
| Read a page again, as a scan with OCR | `pdf reparse scan.pdf --page 3 --step ocr` |

## Known limits

- Only `pdf add`, `pdf info`, `pdf read`, `pdf search`, `pdf crop`, `pdf pick`, `pdf transcribe`, `pdf reparse`, `pdf dump`, `pdf note`, `pdf ref`, `pdf ls`, `pdf rm`, `pdf doctor`, `pdf clean`, `pdf setup` and `pdf agent-guide` are built so far, from source, and every target in [plan/GOALS.md](plan/GOALS.md) is still unmeasured.
- It supports macOS 11 and newer, and no other platform.
- The document structure of scanned pages needs macOS 26.
- Scanned pages in Japanese or Korean need macOS 13.
- It returns text, crops and failure reports. The agent does the reasoning, so pdf-cli answers no questions by itself.

## Documents

| Document | Answers |
|---|---|
| [PROPOSAL.md](PROPOSAL.md) | Why did we start this? |
| [PHILOSOPHY.md](PHILOSOPHY.md) | How does the project see the problem? |
| [DESIGNS.md](DESIGNS.md) | How is it built, and why that way? |
| [plan/GOALS.md](plan/GOALS.md) | What do we measure? |
| [FEATURES.md](FEATURES.md) | What does it do, and what will it never do? |
| [plan/ROADMAP.md](plan/ROADMAP.md) | When, and how far along? |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each release? |
| [plan/TODO.md](plan/TODO.md) | Which small follow-ups have no milestone yet? |
| [reports/](reports/README.md) | What did each task's review and measurements find? |

## License

MIT. See [LICENSE](LICENSE).
