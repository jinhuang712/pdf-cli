# 030. a 5,000-token default budget over no default

Decided: 2026-10-15    Status: current

`read` and `search` stop at 5,000 tokens unless the agent passes `--budget`. The default keeps the stance "No whole document by default" in [PHILOSOPHY.md](../../PHILOSOPHY.md) true for an agent that passes no flags. Search has no default result count, so the budget alone decides how many hits fit: about 130, measured on a sample paper when task M1.8 built search, against 60 estimated before.

A sample-paper page holds about 950 tokens of text, so 5,000 tokens is about 5 pages, or 20,000 characters. Claude Code shows a command's output in full up to about 30,000 characters and moves the rest to a file, according to third-party reports. Our cut lands between blocks and ends with the command that continues. Claude Code's cut lands anywhere.

Task M1.7 built it. Tokens are estimated as one per four characters of Latin text and one per character of other scripts. A text block goes out together with the doubts that follow it, and the cut falls between such units, with a `next:` line that names the block to go on from, as in `--from p4.27`. Every read moves on: the first unit after a page's heading goes out even when it alone is larger than the budget. A text block is cut inside, after a word, and the next read goes on from that character, as in `--from p3.2:200`; a failure block or text shown with `--raw` goes out whole. Counts and flags in the summary line come only from what went out. Following each `next:` line rebuilt the full read exactly on five sample files at budgets of 55, 120 and 300 tokens. With full block addresses, a sample page came to about 1,230 tokens, and with paragraph numbers alone to about 1,030, so the default read shows about 5 pages.

| Option | For | Against |
|---|---|---|
| **5,000 tokens** | A typical paper section in one call, inside Claude Code's 30,000 characters. | A long section takes two calls. |
| 2,000 tokens | Cheaper per call. | More calls for the same section. |
| No default | The agent always gets everything it asked for. | A flagless read of a 300-page book sends about 285,000 tokens, and Claude Code cuts it mid-sentence. |
