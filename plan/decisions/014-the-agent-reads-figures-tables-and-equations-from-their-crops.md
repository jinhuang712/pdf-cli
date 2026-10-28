# 014. the agent reads figures, tables and equations from their crops, and its LaTeX is kept

Decided: 2026-10-18    Status: current

The user, on 2026-10-18: what the tool cannot read for certain, the agent's own model reads from the image. Rules or OCR that turn a table or an equation into text cannot promise it right, and a wrong LaTeX looks right. The tool's job is to cut the tokens, the cost and the time an agent spends on a PDF, which plan/GOALS.md measures, and a crop costs little: about 500 image tokens for an equation, 1,600 for a table. What the agent reads once should not be read again: with M2.13 it writes an equation's LaTeX, or a table's Markdown, back with `pdf transcribe`, which keeps it beside its picks, and later reads show it in place, labelled as the agent's reading, with the crop still there to check it by. This replaces the decision of 2026-10-17 to rebuild LaTeX by rules.

| Option | For | Against |
|---|---|---|
| **The agent reads the crop, and writes its LaTeX back** | As right as the agent's reading of the image, and paid once a file: later reads, by any agent, take it from the cache. | Each equation costs a crop the first time, and a page of 28 is better cropped whole. A wrong reading stays until another transcribe replaces it or `--clear` removes it. |
| LaTeX rebuilt by rules from the glyphs, checked by drawing it back | No image tokens at all. | Not right for certain: a fraction or a matrix rebuilt wrong reads as right, and drawing it back needs a TeX engine. |
| A local vision model | Reads formulas without the agent. | A download, and its readings are not right for certain either: dropped with M3.3. |
