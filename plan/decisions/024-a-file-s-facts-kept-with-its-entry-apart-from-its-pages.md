# 024. a file's facts kept with its entry, apart from its pages

Decided: 2026-10-15    Status: current

A file's metadata, bookmarks, page labels, comments, highlights, form fields, attachments and scripts live in its catalog and its annotations, not in what its pages draw. A worker of their own reads them while the index runs its sample check, and the runner keeps them with the file's entry in the cache: a highlight appended to a file changes its facts and leaves its pages' results alone, as the principle "Annotations leave the cache alone" asks. A new version of the index checks reads every file's facts again on its next read. The file's annotations are kept apart from the facts, in a table of their own (plan/decisions/044-annotations-per-page-in-a-table-of-their-own.md → Decision: annotations per page, in a table of their own).

Facts are extra, so they never cost the file or a page. A facts worker has 10 s, since facts take under 0.2 s even on 30,000 pages and a new file's first page waits for them; one that runs out of time or crashes gets a second try, as the sample check does. A second failure stores the reason until the file changes, the file indexes all the same, and `pdf info` shows the facts as unknown with that reason, never as none. The reading visits at most 200,000 objects and follows no loop. It counts each tree node, attached file and form field once in the file, and each action once for the document and once on each page that holds it. It walks the page tree once, counting a node the tree lists twice twice, as CGPDF numbers the pages. It lists the first 100 attachments and scripts and counts the rest, measures a script by its stored length without decompressing it, and runs nothing it finds.

Reading facts on the first read's path, rather than after it, was kept on purpose: `pdf read --section` and `--printed-page` need the bookmarks and page labels at once, and the 10 s limit bounds what a hostile file can add. Page labels come from the catalog's number tree in one pass: asking PDFKit page by page took 54 s on a 30,000-page file. A form field counts once however many widgets show it, and a push button not at all.

The review of M1.6 found the first version unbounded: a 1 KB name tree that lists itself made a readable file fail as damaged after 90 s, and a self-chained script action made an 80 MB report line. Both now read in under 0.2 s ([reports/M1.6-info.md](../../reports/M1.6-info.md)).

| Option | For | Against |
|---|---|---|
| **With the file's entry** | Follows the file's bytes, as annotations do. | Read again whenever the file changes, even by a highlight. |
| With the document, by page content | Shared by every copy. | Two copies with other bookmarks or comments would show each other's. |
