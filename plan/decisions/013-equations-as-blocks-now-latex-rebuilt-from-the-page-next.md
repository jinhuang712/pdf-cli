# 013. equations as blocks now, LaTeX rebuilt from the page next

Decided: 2026-10-17    Status: current

Replaced on 2026-10-18 by "Decision: the agent reads figures, tables and equations from their crops, and its LaTeX is kept": the tool rebuilds no LaTeX, and M2.13 now keeps the LaTeX the agent reads, not LaTeX rebuilt by rules as below.

The user asked for equations in three steps: find where each is, recognize it, and turn it into LaTeX, from which the formula can be drawn again, so the agent reads LaTeX, which models read well, and the tool checks its own LaTeX by drawing it back and comparing it with the page. M2.6 takes the first two steps: a numbered equation is a block with its number and its crop, its text behind `--raw`, since PDFKit gives a display's lines out of place, as "_{r}. (3)" on a line of its own. The third, LaTeX rebuilt by rules from the glyphs' fonts and positions, is M2.13.

| Option | For | Against |
|---|---|---|
| **A block with its crop now, LaTeX next** | M2.6 stays its size, and the LaTeX step starts from the equations M2.6 finds. | Until M2.13 an agent crops each equation it needs. |
| The text in place, with a marker | Costs no crop where the text reads well, as "∆W = W_{down}W_{up}". | Most displays read as scraps, a fraction's parts as blocks of their own. |
| LaTeX from a model, in M3 | Reads scans too. | A download, and M3. |
