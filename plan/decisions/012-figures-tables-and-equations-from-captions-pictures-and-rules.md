# 012. figures, tables and equations from captions, pictures and rules

Decided: 2026-10-17    Status: current

A figure is found from its caption, "Figure 4" or "Table 2", and the pictures M1.14 marks nearest it in its column; a table from its caption and the horizontal rules that chain from it; a numbered equation from its number set apart at the end of its line. Each becomes one block in `pdf read`, in place of the text inside it, which goes behind `--raw`, and `pdf crop --figure 4` crops it with its caption. It follows the M0 spike's finder, which found 54 of 54 figures on 116 pages of papers; the parse stores each page's regions, so `pdf info` lists them and `pdf crop` finds them by number without a page parsed again.

On the smoke set's ten papers it found 64 figures, 77 tables and 84 equations, all 22 of one paper's tables of prompts among them; on the 15 PMC papers 001 to 015, 63 figures, 22 tables and 7 equations, at least one on each, though none on a PLOS paper until "Fig 1." without a period counted, which then gave its 11. Six essays gave one figure; the Chinese law, the FOMC minutes and a textbook chapter gave none, as they number no figure, and a Russian review's "Таблица 1" was found once Russian captions counted, with Japanese, German, French and Spanish ones; two NIST reports and a Census report gave 13 figures and 13 tables. A sweep of the long blocks set aside on these 38 files found one table that ran over a paragraph to a rule under the footnotes, now stopped by the running text between, and no paragraph of running text set aside since.

- A chart whose bars carry their values, and a heatmap's cells, are no picture to M1.14: a figure with no picture near its caption takes the shapes drawn there, joined within 6 pt, with no running text inside.
- The review found figures that took a paragraph's short last line next to their picture (NIST's CSF 2.0, p.13), and a picture above a paragraph for a caption whose figure was below it. No line of running text is a figure's, and a picture beyond two lines of it is not the caption's.
- It found tables that chained through a footnote's short rule and a footer's rule (the EPA's inventory), or from a column to a rule across the page. Rules chain only about as wide as the first, none in the page's margins, pieces joined first, as the EPA draws a rule a column; that table, ruled only around its header, goes on down its rows.
- An equation's lines are only those of maths, close to its number's row, in its column, and no further below it than above: on the first pass a display took in the left column's line on its row and the "where …" after it.
- A table's rows that hold sentences in the body's size, as prompts, can end it early: those rows read as text, the safe side. Running text is a line of five words or more, most of its own, so rows as "Global batch size 512" or a dataset's name with its numbers are none, and the body's size is read from the running text outside the table and every caption, so a page of tables and figures alone has none to take their rows for.

| Option | For | Against |
|---|---|---|
| **Captions, pictures and rules** | No model, run in the parse that reads the page's text and drawings already, and every region is named by its caption's number, which the agent cites and crops by. | A figure or a table without a numbered caption, a table drawn without rules, and an equation numbered at its left are not found. |
| Every picture a figure, as M1.14 marks them | Finds figures with no caption. | No number to cite or crop by, and a table's text, which rules alone draw, would stay as flat numbers. |
| A layout model on Core ML | Labels figures, tables and formulas with no caption needed. | A download, and its accuracy on our pages is unmeasured: M2.4 waits for a goal that rules fail. |
| Apple's document recognizer | Returns tables with cells. | Only on macOS 26, it costs about 670 ms a page, and a wrong cell looks right. |
