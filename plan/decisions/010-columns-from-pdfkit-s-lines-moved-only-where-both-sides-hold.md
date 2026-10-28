# 010. columns from PDFKit's lines, moved only where both sides hold running text

Decided: 2026-10-17    Status: current

PDFKit's own order of a page's lines reads well on most pages: on the M0 spike's 36 two-column pages it switched columns least of four engines. But on some it goes from one column to the other line by line, as below the figure on p.5 of the smoke set's arxiv-2608.24191.pdf, where each paragraph came out as one-line blocks of both columns in turn. So the parse keeps PDFKit's order and moves only what is clearly a band of two columns of running text: the gutter is the place in the middle half of the text that the fewest lines cross, a line across both columns parts the page into bands, and a band moves when each side holds two lines or more that fill 80% of its column. Its left column then goes before its right one, right before left in Hebrew and Arabic, each keeping PDFKit's order of its lines, and the band goes out where PDFKit first reaches one of its full lines, the bands from the top down. Every other line keeps its place, and the reading order tells the grouping where each column starts a block.

On the 10 smoke papers, a left-column paragraph read after a right-column one with no full-width line between fell from 41 times to 15; p.5 of arxiv-2608.24191.pdf went from 41 blocks to 12. The rules came from the pages each earlier try broke:
- At half a column's width, a figure's three panels of text side by side counted as columns, and their paragraphs were cut in two.
- Placing the full-width lines by their height cut a figure's middle panel, whose lines cross the gutter, into slices.
- A page number set in the gutter went with the left column, and a grid of authors above the columns was split at the gutter: both now keep their place.
- arXiv's stamp, set sideways in the margin, made the left column look wider than its lines, and started the band ahead of the title: lines over three times as tall as most take no part in finding the columns, and a band starts at a full line.
- The page's pictures cut no band: M1.14 joins panels within 30 pt, so a figure in the left column and a formula's accent in the right made one picture across both.

| Option | For | Against |
|---|---|---|
| **PDFKit's order, with bands of two columns moved** | Changes only what is clearly wrong; a page PDFKit reads well keeps its order exactly. | Misses wrong orders it cannot tell, as a caption PDFKit reads after the columns below it. Two columns per band, nested at most three deep. |
| Every line placed by position, as an XY-cut | The textbook method; orders every page. | Reads two columns as bands where their paragraph gaps line up. The first try, which placed every line by its band, cut a figure's three panels into lines and split a grid of authors. |
| Apple's document recognizer's order | One engine for scans and born-digital pages. | Mixed two columns on 2 of the spike's 36 pages, and costs 0.67 s a page. |
| A layout model's order | Learns layouts no rule foresees. | A download, and its accuracy on our pages is unmeasured: M2.4, only if a goal fails. |

A block that holds text a reader cannot see is never set aside as furniture: the review hid a planted line after a page number, and the count of hidden text lost it. A page number must agree with the page's own or one nearby, so a chart's tick or a cover's year is none. Running headers, footers, page numbers and publisher stamps are judged when a page is read, against the pages within 4 of it parsed so far, never in the page's parse: a page's parse must not depend on another page's, or a page shared by two files, or parsed before its neighbours, would read two ways. They keep their block numbers, so addresses do not shift when `--headers` shows them. The read waits for no neighbour, since a hostile page next door can take its full time limit, so while a file parses a header can show until its neighbours are parsed, and the summary line says the read is provisional. The search index takes each page as it is parsed, so headers stay searchable: plan/TODO.md.
