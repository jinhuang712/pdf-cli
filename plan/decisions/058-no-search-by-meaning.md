# 058. no search by meaning

Decided: 2026-10-26    Status: current

M3.1, `pdf search --meaning`, is dropped. Keyword search stays; the agent retries with other words or translates its own query.

**Measured** on 43 queries over 3,151 paragraphs, right paragraph in the top 5:

| Queries | Keyword search | `--meaning` | Apple embeddings alone |
|---|---|---|---|
| English paraphrase, 27 | 13 | 12 | 1 to 7 |
| Chinese on English, 8 | 0 | 0 | 0 |
| Chinese on Chinese, 8 | not given | 4, mostly from the keyword path | 0 to 5 |

Apple's embeddings were NLEmbedding (sentence and word) and NLContextualEmbedding. They cost about 9 ms per paragraph and about 9 KB per page.

**Options**

- **(a) Apple's built-in embeddings.** Measured above: they add nothing over keywords on English and nothing on Chinese against English.
- **(b) A downloaded multilingual-e5-small** (MIT, 384 dimensions, a community 4-bit Core ML build of about 59 MB; MIRACL Chinese nDCG@10 45.9, BUCC zh-en 89%). It needs a Swift SentencePiece tokenizer, a Core ML wrapper, a vector store, a `pdf setup` download and a cache bump: about 1 to 1.5 tasks. No published number shows it reaching G10's 90%. The community conversions are unaudited. MLX Swift may need Xcode (unverified).
- **(c) Keep the weak version as a labelled lead.** It would help about as often as keywords and add a flag that can mislead.

**Why dropped.** The agent can retry with other keywords or translate the query itself. The gain of (b) is uncertain, and its cost and a misleading flag are not worth it. The tool's job is to cut the tokens and time an agent spends on a PDF.

**What is kept.** Branch `m3-1-meaning` (commit 15c659e, worktree `.claude/worktrees/m3-1-meaning`) holds the weak version, unmerged, for reference. Reopening M3.1 needs a user decision. Goal G10 (search) is removed from plan/GOALS.md.
