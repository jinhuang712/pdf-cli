# 029. paragraph numbers in text, positions in JSON

Decided: 2026-10-15    Status: current

In text output, each page starts with a heading such as `## p.2`, and each block starts with its number on the page, as in `¶5`. `--json` gives every block its page, its number and its position, and every doubt in either output carries the command that crops it. An agent cites "p.2 ¶5", and `pdf read --from p2.5` goes back to it.

On the ten arXiv samples, the full address on every block, as in `p.2 ¶5 · 0.12,0.41,0.37,0.19`, took about 22% of a read's tokens by the tool's estimate, which likely counts digits low. The number alone takes about 7%: a page came to about 1,030 tokens instead of 1,230. The user chose the number alone.

| Option | For | Against |
|---|---|---|
| **The number in text, the position in JSON** | About 15% fewer tokens on every read. | An agent that wants a block's position reads `--json`. |
| The full address on every block | Every position in plain sight. | About a fifth of every read spent on numbers an agent rarely uses. |
