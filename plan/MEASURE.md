<!-- what-we-build: drafted 2026-10-29 -->
# Measure

How we find out whether pdf-cli does its job. plan/GOALS.md says what we want (G1, G5, G15); this file says what we look at and how we run the experiments that give us the numbers. M3.6 is the first run.

## The order: measure > benchmark > compare > threshold

The user's order (2026-10-29). Each step is worth more than the one after it, and none is skipped for the next.

| Step | What it is | What we keep |
|---|---|---|
| **Measure** | Record what really happened in one run, in fine parts: where each token went, which command failed and why | A ledger row per run and per tool call |
| **Benchmark** | Make the measurement repeatable: a frozen question set, a fixed runner, a pinned model and commit | A script anyone re-runs on any commit and gets comparable rows |
| **Compare** | Put two arms side by side, question by question | Paired ratios, their spread, a list of wins and losses |
| **Threshold** | Read the goal's number off the distribution | One line: passes or fails, with the numbers it stands on |

So a run is never "G1 failed". It is "tokens split like this; the cost sits here; against reading directly the ratio is this, ranging so far; the goal's 20% is missed on these question types".

## What we want to know

pdf-cli exists to **cut the tokens, the cost and the time an agent spends on a PDF** without making answers worse (CLAUDE.md → The user's direction). Four questions follow, in this order of weight.

1. **Where do the tokens go?** The sum matters less than the parts.
2. **Is the answer still right?** A cheaper wrong answer is a loss.
3. **Does the agent use the tool well?** Commands that fail or loop cost tokens and trust.
4. **Does the design bet pay?** The design sends tables, equations and figures as crops. Pictures cost tokens too. This is the least tested part and the most likely surprise.

## The metrics

Every metric is recorded per run (one question, one arm, one try) and rolled up afterwards.

### 1. Cost (G1 reads from here)

| Metric | How | Why |
|---|---|---|
| Tokens by kind: fresh input, cache write, cache read, output | The run's usage totals | Raw "total tokens" misleads: cache reads are cheap, cache writes and output are not |
| **Cost in dollars** | The run's reported cost | The one number that folds the kinds together; G1's "tokens" is read both ways |
| Tool-result tokens, split into **text** and **image** | Per tool call, from the stream log | Shows whether crops eat the saving |
| Agent guide tokens | Counted once per session | A fixed cost paid before the first question; under 2,000 |
| Turns and tool calls | Stream log | Each turn re-reads the context |
| Wall time, and the tool's share of it | Run clock; `pdf` command times | Time is one of the three things we cut. Cold cache and warm cache are separate rows |
| Pages the agent saw vs pages the answer needs | Pages in tool results vs the question's answer pages | Waste: pages read for nothing. A direct read of a whole file wastes most |

**Two caches, not to be mixed.** The *prompt cache* (cache write and cache read in the usage totals) belongs to the model service and Claude Code; it is automatic, and we only move it by sending less and asking fewer turns. pdf-cli's *own cache* (the parse results in SQLite) costs no tokens and changes only time. Every run starts with a new `PDF_CLI_HOME`, so time rows are cold unless a warm row says otherwise.

First small run (2026-10-29, one 15-page paper, 8 questions, Haiku 5.5, one run each): the estimated cost shares of arm A were about 52% cache write, 25% cache read and 23% output; of arm B 85%, 6% and 9%. A short file hides the saving, because the fixed part (system prompt, tools, guide) is paid once per session.

### 2. Answer (G5 reads from here)

| Metric | How |
|---|---|
| Right / wrong / no answer | Graded against the question's known answer, blind to the arm |
| Evidence page named, and right | The answer must cite a page; compared with the labelled page |
| Cause of every wrong or missing answer | One of: *tool dropped it* (header, hidden text, set-aside table), *reading order*, *crop not requested*, *crop misread*, *flag ignored*, *baseline limit* (page cap, size), *agent error*, *question flawed* |

The cause list is the useful part. A wrong answer with no cause teaches nothing.

### 3. Commands (G15 reads from here)

| Metric | How |
|---|---|
| First-try success rate | `pdf` calls whose exit code is 0, or 3 when the output was used correctly, over all `pdf` calls |
| Failure class | Wrong or clashing flags (exit 64), file or page not found, exit 3 not understood, a flag that was needed but unknown (`--show`, `crop`), same call repeated, guide not read |
| Calls that changed nothing | A repeated command with the same output |
| Recoveries | Failures followed by a right call, and how many turns it took |

### 4. Crops (the design bet)

| Metric | How |
|---|---|
| Crops requested per run, and per question type | Count `pdf crop` calls and `⟦crop⟧` marks followed |
| Image tokens per crop | From the stream log; also by crop size |
| Crops that were needed vs crops that were not | Needed = the answer lies in a table, equation or figure |
| Answers that needed a crop and got it, and answers that needed a crop and did not | Joins the answer metric with this one |
| Marks the agent ignored | Unsure blocks and `⚠` flags in output the agent never opened |

If images cost more than the text they replace, the bet fails on that question type, and that is a design finding, not a bug.

### 5. Tool side (from the tool's own output)

Bytes and estimated tokens per command; how many blocks were set aside and shown in the summary line; how often exit 3 appears; parse time per page on a cold cache. These come from running the tool alone, with no agent, so they cost nothing and run first.

## Experiment design

### Arms

| Arm | Setup | Purpose |
|---|---|---|
| **A: pdf-cli** | The agent has `Bash` for the `pdf` command, its guide, and `Read` to look at crops; the built-in PDF reading is not offered (without `Read` the agent cannot see a crop) | What we ship |
| **B: direct** | The built-in Read tool on the PDF (page ranges as it requires); `pdf` not offered | The thing we want to beat |
| **A-text** (ablation) | Arm A with `pdf crop` withheld | Measures what crops cost and buy. Run once the first two have run |

Same model, same effort, same system prompt, same working folder layout for every arm. The model's ID goes in every row.

### Questions

Each question has: the file, the text, the **known answer**, the **page(s) that hold it**, a **type**, and a **kind of evidence** (running text, table cell, equation, figure, footnote, caption, scan).

Types, with the share we aim for:

| Type | Share | Notes |
|---|---|---|
| Fact in running text | 20% | The easy case; pdf-cli should win on cost |
| Table cell or row | 20% | Includes tables that continue across pages |
| Equation or symbol | 10% | Needs a crop and the agent's reading |
| Figure or chart value | 10% | Needs a crop |
| Footnote or caption | 10% | Tests the set-aside logic |
| Scan | 10% | OCR path |
| Across pages or sections | 10% | Needs search or several reads |
| **Whole-document** ("what is this paper's method, in one line") | 10% | Direct reading may win here. Kept on purpose, so the test is not rigged |

Rules: the answer must be checkable without judgment (a number, a name, a short phrase); no question can be answered from the model's memory (check by asking the model with no file; drop any it gets right); some questions have no answer in the file, to test that the agent says so.

Files come from `private/testset/` (local, never committed). Spread them by length: short (under 20 pages, direct reading fits), medium, long (direct reading cannot fit without paging). Report every metric by length bucket, because the saving grows with length and a mean hides that.

### Control

- **Fresh state.** Each run gets a new session and a new `PDF_CLI_HOME`. For the warm-cache arm, the cache is built first by a separate run and its time is reported apart.
- **Cold and warm.** Cold is the first read of a file; warm is the second. An agent often meets both; report both, never blend.
- **Order.** Questions are shuffled; arms alternate so drift in the service hits both.
- **Repeats.** At least 3 runs per question per arm in the full set, 1 in the small set. One run only shows a trend, and the report says so.
- **Blind grading.** The grader sees the answer and the cited page, not the arm. Wrong answers get their cause after grading, by someone who sees the log.
- **No tuning to the set.** If a run exposes a bug, we fix it, then re-run on a **second, unseen** question set; the numbers we report come from the unseen one.

### What a run writes

One folder per run under `private/eval/<date>-<commit>/` (not committed; the results go into `reports/`):

```
runs.tsv        one row per run: id, question, arm, model, commit, cold|warm, tokens by kind,
                cost, turns, tool calls, wall time, answer, graded, cause, evidence page
calls.tsv       one row per tool call: run id, tool, command, exit code, result tokens (text|image),
                time, failure class
raw/<run>.jsonl the full stream log, kept so any row can be checked again
```

Everything in the tables above is a column or a sum over these three files. A script, not a person, builds the report tables.

## Benchmark: making it repeatable

- The question set is **frozen and versioned** (`testdata/eval/questions.tsv`, with a SHA-256 for each file it uses). Changing a question makes a new version; old numbers keep their version.
- The runner (`testdata/scripts/eval-run.sh`) takes the arm, the commit, the model and a question range, and nothing else. It builds the commit outside the repo, as `old-cache-check.sh` does.
- Each result row carries the commit, the parser version, the guide's hash and the model ID. Two rows are comparable only if those match, apart from the one thing that differs on purpose.
- Rerunning after a change is one command. This is how a design change (a smaller default output, a different crop size) is judged: by the same questions, before and after.

## Compare

- **Paired by question.** For each question, ratio = arm A's cost ÷ arm B's cost. Never compare two means of different questions.
- **Report the distribution**: median, the quartiles, the worst 10%, not only the mean. A few huge direct reads can make a mean look good while most questions are no better.
- **By type, by length, cold vs warm.** The headline is a table of these, not one number.
- **Wins and losses listed**: every question where A costs more than B or answers worse, with its cause. These are the work list.
- **Uncertainty.** With few runs, give a bootstrap range and say "trend" when it is wide.
- **Attribution.** For A against B, split the saving into parts: the guide, the text, the images, the extra turns. The saving is explained, not just stated.

## Threshold

Last, and short. From the distributions above, read off:

| Goal | Read-off | Passes when |
|---|---|---|
| G1 - Tokens per question | Median paired cost ratio, and the same on the cold run | ≤ 20%, and not above 20% in any length bucket the goal covers |
| G5 - Answers | Right and wrong counts, A against B | A right ≥ B right, A wrong ≤ B wrong |
| G15 - Commands | First-try success rate | ≥ 95% |

A goal that fails is not edited to pass. The report states the number, the cause and the options, and the decision is the user's.

## Threats to validity

- **Our questions favour us.** We write them, knowing the tool. Mitigation: the whole-document type, the questions with no answer, and the unseen second set.
- **The baseline is not fixed.** Direct reading has a page cap and costs more on scans; a failed direct read is *baseline limit*, listed on its own, not counted as a win.
- **Cache accounting.** The same prompt costs less on its second use. We report all token kinds so a saving that is only cache is visible.
- **Model drift.** The service changes between days. Arms alternate in time and the model ID is recorded.
- **Few runs.** The small set shows a trend only.
- **The grader.** One grader for all arms, blind to the arm; a sample re-graded by another reader.

## Order of work

1. **Tool side first** (metric group 5): run `pdf read` and `pdf info` over the local test set alone and record bytes, estimated tokens, marks and times. No agent, no cost.
2. **Question set, small**: about 30 questions over 10 files, all types, every one with an answer and a page. The user reviews the set before any paid run.
3. **Runner and ledger**: the three files above, and the report script. Dry run on 3 questions.
4. **Arms A and B** on the small set, then the report and the work list of losses.
5. **A-text** to price the crops.
6. Fix what the work list shows; re-run on an unseen set. The full 200-question set and the 60-file open test set (M2.1, M2.2) come with the final wrap-up and reuse the same runner.

## Open decisions (the user's)

- Which model the runs use, and the budget for them.
- Whether the arms also run a second model, to see if the saving depends on the model.
- Whether "tokens" in G1 means total tokens or cost-weighted tokens. This file reports both and defaults the threshold to the cost-weighted one, because cache reads are not worth as much as output.
