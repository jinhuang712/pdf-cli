<!-- what-we-build: drafted 2026-10-15 -->
# pdf-cli — Proposal

> A macOS command-line tool that helps coding agents read PDFs.

Proposed 2026-10-14. For where the work stands today, see [ROADMAP.md](ROADMAP.md).

## In short

You ask Claude whether Figure 4 in a 30-page paper supports the authors' claim. It reads every page as an image, spends about 100,000 tokens, and answers from the caption, not the chart. The next day it reads all 30 pages again.

pdf-cli parses the paper once. The agent reads the outline, the one section that matters and a crop of Figure 4. The next day it reads them from the cache.

## The shift

| | Before | Now |
|---|---|---|
| Who reads PDFs | People, with their eyes | Coding agents, for people, many times a day |
| What a read costs | Time | Tokens and context space |
| The tools | Viewers built for eyes, and Python parsers built for GPU servers | The same tools |
| The Mac | Text recognition only | On-device document recognition in macOS 26 (paragraphs, tables, lists), and a Neural Engine for running models |

## Pain points

1. **Every read sends page images.**
   Anthropic's PDF docs count roughly 1,500–3,000 text tokens per page, plus an image for every page. A 30-page paper costs on the order of 100,000 tokens (estimate, not measured).
2. **The tools are raw.**
   Claude Code reads at most 20 pages per call. It has no outline, no search and no way to jump to a section, so the agent reads pages blindly to find one part.
3. **Charts and diagrams get skipped.**
   A chart's text arrives as loose words such as "0.2 0.4 0.6 Accuracy Epoch". The agent then quotes the caption instead of reading the chart.
4. **The layout breaks the text.**
   In two-column papers, footnotes land in the middle of sentences, and the reading order jumps between columns. Fonts and colors that carry meaning are lost.
5. **Scanned pages have no usable text.**
   A library scan comes back empty, or with an old and garbled text layer.
6. **Nothing is reused.**
   Each new session reads the same 30 pages again.
7. **Nothing can be searched.**
   To find one passage across ten papers, the agent opens each paper and reads it.
8. **Reading is slow.**
   Each question waits again for pages to render and upload. Good parsers are slow on a Mac: Docling's 2025 technical report gives 1.26 seconds per page on an M3 Max.
9. **Good parsers are heavy to install.**
   They pull in Python and PyTorch. MinerU's install is about 2.65 GB, according to Xberg's comparison chart.
10. **Bad text arrives silently.**
    A garbled text layer such as `(cid:72)(cid:101)`, or two columns read as one, looks like normal text. The agent answers from it with full confidence.
11. **Answers can't be checked.**
    The agent's answer names no page, so you search the PDF yourself to verify a claim.
12. **Cloud parsers upload your documents.**
    The `parse` command of semtools sends PDFs to the LlamaParse cloud by default, according to its README. Unpublished manuscripts and confidential reports leave your Mac.
13. **PDFs can carry hidden instructions.**
    In July 2025, Nikkei Asia found 17 arXiv preprints with white or tiny text that told LLM reviewers to give only positive reviews. An agent that reads the raw text reads those instructions too.

## The idea

**A PDF CLI tool that lets you read fast, cheap and accurately.**

Behind those words are 11 promises.

| Promise | What it means |
|---|---|
| Fast | A first answer comes quickly, even on a PDF the tool has not seen before. |
| Cheap | An agent spends far fewer tokens per question. |
| Accurate | The agent gets the right text in the right order, with footnotes intact. |
| Sees figures | Charts, diagrams and tables reach the agent as images it can look at. |
| Reusable | The tool parses the same content only once. |
| Searchable | A search finds the right page across all your PDFs. |
| Honest | The tool flags the pages it could not read well. |
| Traceable | Every result points to its page and its position on the page, so each claim can be checked. |
| Private | Your documents stay on your Mac. |
| Easy | One command installs it, and agents use it right the first time. |
| Safe | Hidden text and broken files can't harm the agent. |

## What we want

| Pain | Promise | What pdf-cli does |
|---|---|---|
| 1. Page images | Cheap | It returns text by default, and an image only for the figure or region the agent asks for. |
| 2. Raw tools | Easy | `pdf info` shows the outline, each section's size in tokens and the figure list. `pdf read` reads by page or by section. |
| 3. Charts skipped | Sees figures | It detects figures, vector charts included, and crops each one as a PNG for the agent to look at. |
| 4. Broken layout | Accurate | It restores the reading order, and keeps footnotes, running headers and publisher stamps out of the body text. |
| 5. Scanned pages | Accurate | It reads scanned pages with Apple's on-device OCR. |
| 6. Nothing reused | Reusable | It caches every parsed page by its content. |
| 7. No search | Searchable | `pdf search` searches every PDF you have added, by keyword or by meaning. |
| 8. Slow | Fast | It parses pages in parallel, the page the agent asked for comes first, and later reads come from the cache. |
| 9. Heavy install | Easy | It ships as one binary, installed with Homebrew. |
| 10. Silent bad text | Honest | It checks each page for garbled text, an uncertain reading order and low OCR confidence, and flags the page with a command that fixes it. |
| 11. Unchecked answers | Traceable | Every block of output carries its page number and its position on the page. |
| 12. Cloud upload | Private | It parses on your Mac, and it makes no network calls while it parses. |
| 13. Hidden instructions | Safe | It flags invisible text and keeps it out of the normal output. It parses each file in a separate process with a time limit. |

## How it works

An agent answers the Figure 4 question with three commands. The commands and output are a sample of the plan, and none is built yet. Full behavior lives in [FEATURES.md](FEATURES.md).

```sh
$ pdf info paper.pdf
Residual Dropout for Robust Vision Models · 30 pages · 2 columns · ~19k tokens
  1 Introduction   p.1–3    1.8k tokens
  4 Experiments    p.10–19  4.6k tokens
  fig 4            p.15     Accuracy vs. dropout rate (chart)

$ pdf read paper.pdf --section Experiments
...

$ pdf crop paper.pdf --figure 4
~/Library/Caches/pdf-cli/3f9a…/fig4.png
caption: Accuracy vs. dropout rate · mentioned on p.15, p.20
```

In this sample, the agent spends about 10,000 tokens instead of about 100,000 (estimate, not measured).

## What we don't want

| Stance | Reason |
|---|---|
| No LLM inside the tool | The calling agent already is an LLM. A second one would cost money and make the output unpredictable. |
| No Windows or Linux | Apple's PDF, OCR and Neural Engine frameworks are the project's main advantage. |
| No PDF editing (merging, forms, signing) | Agents need to read PDFs. Editing is a different product. |
| No PDF parser or renderer of our own | Apple and Google maintain theirs. Ours would take years, with no difference a user could see. |
| No reading app with a window | Agents call commands. simple-pdf already covers a reader with a window. |

The full list, with reasons, lives in [FEATURES.md → Not planned](FEATURES.md#not-planned).
## Who it is for

Coding agents such as Claude Code and Codex, and the people who use them to read journals, textbooks, articles, essays and reports. The first user is the project's author.

## Approach

- **Platform:** macOS only. The newest features need macOS 26. The oldest supported version is open.
- **Language:** Swift, confirmed by the M0 spike.
- **Parsing and rendering:** Apple's PDFKit and Core Graphics. PDFium cross-checks them in tests.
- **OCR and document structure:** Apple's Vision framework.
- **Layout:** simple rules on fonts, positions and drawing commands first. Pretrained open models, converted to run on the Neural Engine with Core ML, join only when a goal needs them.
- **Hard pages:** small vision models through MLX Swift, only when the user turns them on.
- **Cache and search:** SQLite.
- **Interface:** a CLI with verbs and flags (`info`, `read`, `search`, `crop`, `dump`). Every result carries its page number, so it leads to the next command.

## Risks

| Risk | Mitigation |
|---|---|
| Our layout handling (reading order, footnotes) falls short of Docling or MinerU. | Add their pretrained models on Core ML when a goal fails, keep a test set of real PDFs, and flag low-quality pages so failures are visible. |
| Apple's PDFKit and Vision are closed and change between macOS versions. | Cross-check with PDFium in tests, and rerun the test set on each macOS release. |
| A model fails to convert to Core ML. | Fall back to MLX or ONNX Runtime. |
| The full engine takes 5–7 months of work. | Phase 1 (cache, search, read, crop and OCR) is useful on its own after 4–6 weeks. |
| Hidden text in a PDF injects instructions into the agent. | Flag invisible text, and keep it out of the normal output. |

## How we know it works

[GOALS.md](GOALS.md) holds at least one check for each of the 11 promises, with its target and its method. The target numbers are still open.

Public benchmarks such as OmniDocBench and olmOCR-bench measure only accuracy. So the project builds its own test set of real PDFs and its own question set, and the other 10 promises are measured against those two sets.

Three checks lead:

- The tokens an agent spends to answer a question about a paper, compared with reading the PDF directly.
- The time to the first answer on a PDF the tool has not seen before.
- The accuracy on the test set of real PDFs.
