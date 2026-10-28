# 043. annotations from the file's facts, their words checked against what a reader sees

Decided: 2026-10-17    Status: current

Comments, notes, marks on words, filled-in form fields and links reach `pdf read` after the block each sits on (FEATURES.md → F3). They come from the file's facts, which a worker reads for each version of the file with CGPDF, apart from the pages' parse; the words under a mark or a link come from PDFKit's selection there, in the same worker, and the output keeps only the words the blocks under it show a reader.

| Option | For | Against |
|---|---|---|
| **The file's facts, read with CGPDF; words from PDFKit's selection, checked against the page's visible text** | A file that gains highlights, appended as Acrobat saves them, shows them with no page parsed again (plan/GOALS.md → G9). A mark over text a reader cannot see shows none of it. The walk is bounded and follows no loop. | A mark's words are kept word by word: a hidden word that the same block also shows passes. A link goes inline only where its block holds its words as one run. |
| From each page's parse | The words and the hidden-text check in one place. | An appended highlight changes no page key, so it would never show; or the key must change, and every page be parsed again. |
| PDFKit's annotation objects for everything | Less code: PDFKit resolves fields, destinations and actions. | PDFKit followed a link's action chained to itself until it crashed, which cost the file all its facts, its counts and outline included. |

The facts' version, `Store.indexChecks`, went to 8, so every file's facts are read again, without a page parsed again. A worker that reads facts stops reading words after 3 s, and lists at most 1,000 annotations.
