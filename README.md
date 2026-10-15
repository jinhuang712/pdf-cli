<!-- what-we-build: drafted 2026-10-15 -->
# pdf-cli

> A PDF CLI tool that lets you read fast, cheap and accurately.

pdf-cli lets coding agents such as Claude Code read PDFs on your Mac. It parses each PDF once, hands the agent only the parts it asks for, and flags every page it could not read well instead of guessing.

## What it does

- It parses each PDF once and caches it, so later reads come straight from the cache.
- It gives the agent a map first: the outline, each section's size and the figure list. Then it serves pages, sections, footnotes and references on request.
- It searches one PDF or your whole library, by keyword or by meaning.
- It crops a figure, a table or any region as an image, for the agent's own image understanding.
- It flags every page it could not read well, with a command to read that page as an image instead.
- It drops nothing silently. Hidden text, doubtful text, comments and attachments each leave a marker in place, with the command that shows them.
- It runs entirely on your Mac, with Apple's PDF, OCR and Neural Engine frameworks. Nothing is uploaded.

The full behavior is in [FEATURES.md](FEATURES.md).

## Install

Not available yet. The spike is done, and the first usable version is milestone M1 in [ROADMAP.md](ROADMAP.md). The planned install is one Homebrew command, and the command it installs is `pdf`.

## Use

The first three work today, built from source. Cropping a figure and reading footnotes and references are planned.

| When the agent wants to | It runs |
|---|---|
| Get a first look at a paper | `pdf info paper.pdf` |
| Read one section | `pdf read paper.pdf --section Experiments` |
| Find a passage across every PDF | `pdf search "dropout ablation"` |
| Look at a chart | `pdf crop paper.pdf --figure 4` |
| Read a footnote, or a cited reference | `pdf read paper.pdf --footnote 7` or `pdf read paper.pdf --ref 12` |

## Known limits

- Only `pdf add`, `pdf info`, `pdf read`, `pdf search`, `pdf pick`, `pdf ls`, `pdf rm` and `pdf gc` are built so far, from source, and every target in [GOALS.md](GOALS.md) is still unmeasured.
- It supports macOS 11 and newer, and no other platform.
- The document structure of scanned pages needs macOS 26.
- Scanned pages in Japanese or Korean need macOS 13.
- The optional local vision model for hard pages needs Apple Silicon and macOS 14.
- It returns text, crops and failure reports. The agent does the reasoning, so pdf-cli answers no questions by itself.

## Documents

| Document | Answers |
|---|---|
| [PROPOSAL.md](PROPOSAL.md) | Why did we start this? |
| [PHILOSOPHY.md](PHILOSOPHY.md) | How does the project see the problem? |
| [DESIGNS.md](DESIGNS.md) | How is it built, and why that way? |
| [GOALS.md](GOALS.md) | What do we measure? |
| [FEATURES.md](FEATURES.md) | What does it do, and what will it never do? |
| [ROADMAP.md](ROADMAP.md) | When, and how far along? |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each release? |
| [TODO.md](TODO.md) | Which small follow-ups have no milestone yet? |
| [reports/](reports/README.md) | What did each task's review and measurements find? |

## License

MIT. See [LICENSE](LICENSE).
