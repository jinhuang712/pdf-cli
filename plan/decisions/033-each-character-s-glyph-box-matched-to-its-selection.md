# 033. each character's glyph box matched to its selection

Decided: 2026-10-15    Status: current

PDFKit's `characterBounds(at:)` counts glyphs, not characters. After a ligature such as "fl", one glyph for two characters, it returns the box of the character after the one asked for, and the shift carries on down the page. On an arXiv title, "Dataset Distillation by Influence Matching", the last letter got the box of the next line's first letter, so the title's box spanned two lines. Task M1.7 found it while building the superscript marks.

A selection lands in the right place across the line, but spans the line's full height. Each line is now checked first: when the glyph boxes for its first and last characters, at the shift carried from the lines before, sit inside the line's selection, the line keeps its glyph boxes at that shift. A ligature moves the line's last box off the line, and only then does each character take the glyph box that sits where its own selection does, searching wider after a jump. Lines got their true height, and blocks group into whole paragraphs: the ten arXiv samples went from 43.6 blocks per page to 27.3.

The marks for raised and lowered characters read each character's font size and baseline from PDFKit's attributed string of the page. Together with the boxes, the new work costs a plain text page about 22 ms: on the 456-page file, a page went from 16 ms to 38 ms, and a full read that a command waits on from 6.5 s to 19.8 s with two workers. One selection per character, tried first, cost 51 ms a page.

| Option | For | Against |
|---|---|---|
| **Glyph boxes, checked line by line against selections** | True heights and true places. | One more PDFKit call per line, and per character on lines with a ligature. |
| `characterBounds` alone | One call. | Wrong boxes after every ligature. |
| Selections alone | Right places. | Every character takes the line's height. |
| Glyph positions read from the content stream | Exact. | A text engine of our own, which the PDFKit decision keeps out. |
