# 025. sections from bookmarks, else from headings in the text

Decided: 2026-10-15    Status: current

`pdf info` and `pdf read --section` take a file's sections from its bookmarks, the outline its author saved. A bookmark points at a page and a spot on it, and the section starts at the short block that spells the bookmark's title, with or without a number such as "5.2." or "A.1" before it; among several, the one nearest the spot, so a table row that names the section loses to its heading. With no such block, the section starts at the block nearest below the spot in its column: on a page of two columns, the height alone pointed into the wrong column.

Sections follow the pages, since an outline can list a later page first. On one page the outline's order stands, because the text's reading order can put a right column's heading before the left column's, as "4.1 DomainWiseInfer" before "4. Methods" on one sample. A section reaches to the next one at its level or above; when the reading order puts that one above it on the page, it stops at the page's end. Until the page where the next section starts is parsed, the section's last page and size show as unknown. When that page failed, the section takes it whole, as a read by section does, and the failed page adds no text to its size.

A file with no bookmarks takes its sections from its headings: one-line blocks that read "2.1 Method" or name a usual part, such as "References". A line that repeats word for word on three pages or more is a running header, and so is one near a page's top or bottom edge that repeats letter for letter, as "Introduction 5": the chapter's own heading in the body stays. A title mostly of digits or symbols belongs to a chart or a table, a running header, footer or page number that M2.5 finds is none, and numbered headings must rise, so a table row such as "5 Italian 4–5" after "3.5" stays out. When the bookmarks lack a number that `--section` asks for, the headings get a try.

Until M2.5 a band at a page's top 7.5% and bottom 5% stood in for running headers, as OCR misreads the NACA scan's a new way on each page, and it dropped a real heading set higher on a page with a small margin: a 2 cm margin on A4 is 6.7%. The running headers M2.5 finds match misread ones nearly letter for letter, so the band is gone, and the NACA scan still gives its 6 sections.

On the samples, the arXiv paper with bookmarks gave 17 sections placed on their headings, the Word-made paper without them gave its 16 numbered and named headings, and the 1951 NACA scan gave 6, its real headings, with no running header: its two units tables count as sections too, and the figures after its references fall under "References". Headings need the whole file parsed; until then `pdf info` lists those of the pages parsed so far, and says so.

| Option | For | Against |
|---|---|---|
| **Bookmarks, else headings in the text** | The author's own outline when there is one. | Heading rules miss unnumbered headings, and let some noise through on scans. |
| Headings by font size | Finds unnumbered headings. | Needs each block's font size, which the text layer does not keep yet. |
| A layout model | Labels headings in one pass. | A model to download, which waits until a goal needs it. |
