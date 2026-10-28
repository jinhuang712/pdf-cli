<!-- what-we-build: drafted 2026-10-29 -->
<div align="center">

<img src="assets/hero.png" alt="pdf-cli: read PDFs fast, cheap and accurately, for coding agents on your Mac" width="100%">

<br>

[![License: MIT](https://img.shields.io/badge/license-MIT-2563eb?style=flat-square)](LICENSE)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-111827?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![Runs on your Mac](https://img.shields.io/badge/runs-on%20your%20Mac-0f766e?style=flat-square)
![Built for AI agents](https://img.shields.io/badge/built%20for-AI%20agents-a855f7?style=flat-square)
[![Release](https://img.shields.io/github/v/release/jinhuang712/pdf-cli?style=flat-square&color=f59e0b)](https://github.com/jinhuang712/pdf-cli/releases)

**English** · [简体中文](README.zh-CN.md)

</div>

## ✨ What it is

`pdf` lets a coding agent such as Claude Code read PDFs on your Mac. It parses each file once, keeps the result in a local cache, and hands the agent only the part it asks for: a map first, then a section, a page, a footnote, a search hit or a crop of one table.

- 🗺️ **A map before the text.** `pdf info` gives the outline, each section's size in tokens, the figures and tables, and the pages it could not read well.
- ✂️ **Only what was asked for.** Read a section or a page range; output stops at a budget and names the command that goes on.
- 🔎 **Search one PDF, or all of them.** Paragraphs that hold every word, best first, each with its page and position.
- 🖼️ **Tables, equations and figures go to the agent as crops.** The tool converts nothing it cannot read for certain, because a rebuilt cell can be wrong and still look right. The agent's own model reads the image, and what it writes back is kept, so it is read once.
- 🚩 **It says when it is unsure.** Every page or passage it could not read well is flagged, with the command that shows the page as an image.
- 🙈 **Nothing is dropped without a trace.** Hidden text, running headers, doubtful text, comments and attachments leave a marker in place, and the summary line counts them with the flag that shows them.
- 🔒 **Local.** Apple's PDFKit and OCR do the reading. No network, no model download, nothing leaves your Mac.

> [!NOTE]
> **Early release (0.1.0).** It works on the files it was tested on, and every goal in [plan/GOALS.md](plan/GOALS.md) is still being measured.

## 👀 A taste

Output trimmed. The paper is *Attention Is All You Need*.

```console
$ pdf info paper.pdf
Attention Is All You Need · 2024 · arXiv:1706.03762v7
15 pages · 1 column · text layer on 15 pages · ~10.2k tokens
…
Section                                 pages      tokens
  Model Architecture                    p.2–6      2.6k
    Attention                           p.3–5      1.2k
  Why Self-Attention                    p.6–7      806
  Training                              p.7–8      741

$ pdf read paper.pdf --section "Model Architecture" --budget 250
paper.pdf · 15 pages · read p.2–3 · flagged: none · running headers and footers: 1 set aside (show: --show headers)

## p.2

¶11 3 Model Architecture

¶12 Most competitive neural sequence transduction models have an encoder-decoder structure …

$ pdf crop paper.pdf --page 8 --table 2
…/p8-0.17,0.09,0.66,0.22.png  (~1.4k image tokens, 1568×676 px)
p.8 · caption: The Transformer achieves better BLEU scores than previous state-of-the-art models …
```

## 📊 Does it save anything?

A small first run, so read it as a trend: Claude Haiku 5.5 answered the same questions twice, once with `pdf` and once with Claude Code's built-in PDF reading. Every answer was right either way. Cost with `pdf`, as a share of the cost of reading directly:

| Questions | Share |
|---|---|
| Look-ups (a value, a title, a footnote) in a 492-page standard | **about 16%** |
| Cells and counts in that standard's big tables | about 55% |
| Mixed questions on a 15-page paper | about 51% |

The saving grows with the length of the file, and big tables are where it shrinks, because a table is read from its image. One run per question, one model, two files. Details and the findings in [reports/M3.6-first-question-runs.md](reports/M3.6-first-question-runs.md).

## ⌨️ Commands

| To do this | Run |
|---|---|
| Add a file to the library, and parse it | `pdf add paper.pdf` |
| A first look: outline, sizes, figures, flags | `pdf info paper.pdf` |
| Read pages or a section | `pdf read paper.pdf --page 4-6` · `--section Method` |
| Search one file, or every file read before | `pdf search paper.pdf dropout ablation` · `pdf search dropout ablation` |
| Look at a figure, a table, an equation or a region | `pdf crop paper.pdf --figure 4` · `--table 2` · `--bbox 0.1,0.4,0.8,0.3` |
| Read a footnote, or a cited reference | `pdf note paper.pdf 7` · `pdf ref paper.pdf 12` |
| Keep what the agent read from an image | `pdf transcribe paper.pdf --page 8 --table 2` |
| Choose between two readings of a doubtful word | `pdf pick paper.pdf p2.7 b` |
| Read a page again, as a scan with OCR | `pdf reparse scan.pdf --page 3 --step ocr` |
| Write the text, figures, notes and references to files | `pdf dump paper.pdf` |
| List or remove what the library holds | `pdf ls` · `pdf rm paper.pdf` |
| Check the setup, free space, set parsing's memory | `pdf doctor` · `pdf clean` · `pdf setup` |
| Teach an agent the tool | `pdf agent-guide --install claude-code` |

Every command has `--help` and takes `--json`. Exit codes: 0 done, 2 some pages flagged, 3 the file failed, 1 could not run, 64 used wrongly. What each command does, and what it will not do: [FEATURES.md](FEATURES.md).

## 📦 Install

You need macOS 12 or later.

**One line:** it downloads the prebuilt binary (Apple silicon and Intel in one file), checks its SHA-256 and puts `pdf` in `~/.local/bin`. Run it again to update.

```bash
curl -fsSL https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install.sh | bash
```

If you would rather do it by hand, the archive and its checksum are on the [releases page](https://github.com/jinhuang712/pdf-cli/releases). The binary is signed ad hoc and is not notarized: if you download it with a browser and macOS refuses to open it, run `xattr -d com.apple.quarantine pdf`. The Intel half has not been run on an Intel Mac.

**Or build it from source** (needs a Swift toolchain, from Xcode or the command line tools):

```bash
git clone https://github.com/jinhuang712/pdf-cli.git
cd pdf-cli
swift build -c release
ln -s "$PWD/.build/release/pdf" ~/.local/bin/pdf    # or put it anywhere on your PATH
```

### 🤖 For your agent: the plugin

The plugin is a short guide (under 2,000 tokens) that tells the agent which command to run and what the flags in the output mean. Each line installs the plugin, and `pdf` too if it is not there yet; run it again to update.

```bash
# Claude Code
curl -fsSL https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install-claude.sh | bash
# Codex
curl -fsSL https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install-codex.sh | bash
```

In a new session the skill shows as `pdf-cli:pdf-cli`. Or, with `pdf` already installed, `pdf agent-guide --install claude-code` writes the same guide into Claude Code's skills folder.

## 💡 Good to know

- **macOS only.** It rests on Apple's PDF, OCR and Neural Engine frameworks, which is also why nothing is uploaded.
- **Scans.** OCR reads English, Chinese, French, German, Italian, Portuguese and Spanish from macOS 12; the document structure of a scanned page needs macOS 26, and Japanese or Korean scans need macOS 13.
- **It does not reason.** It returns text, crops and failure reports; the agent answers the questions.
- **Big tables are crops.** A question that needs many rows of a long table takes the agent several images. See [FEATURES.md](FEATURES.md), under Crop.
- Tested on macOS 27 on Apple silicon.

## 📚 Documents

| | |
|---|---|
| [PROPOSAL.md](PROPOSAL.md) | Why did we start this? |
| [PHILOSOPHY.md](PHILOSOPHY.md) | How does the project see the problem? |
| [DESIGNS.md](DESIGNS.md) | How is it built, and why that way? The decisions are in [plan/decisions/](plan/decisions/) |
| [FEATURES.md](FEATURES.md) | What does each command do, and what will it never do? |
| [plan/GOALS.md](plan/GOALS.md) | What do we measure? ([plan/MEASURE.md](plan/MEASURE.md): how the runs are designed) |
| [plan/ROADMAP.md](plan/ROADMAP.md) | When, and how far along? ([plan/TODO.md](plan/TODO.md): the small follow-ups) |
| [reports/](reports/README.md) | What did each task's review and measurements find? |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each release? |
| [CLAUDE.md](CLAUDE.md) | How to work on it, and the direction the project owner has set |

## 📄 License

[MIT](LICENSE)
