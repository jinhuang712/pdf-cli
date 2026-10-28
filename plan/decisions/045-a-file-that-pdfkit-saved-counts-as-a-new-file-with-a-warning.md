# 045. a file that PDFKit saved counts as a new file, with a warning

Decided: 2026-10-15    Status: current

A PDFKit save, the way macOS Preview saves a highlight, rewrites every page. Task M1.1 found that it re-embeds the fonts in the MacRoman encoding and drops their Unicode maps, so characters outside MacRoman read back wrong: on an arXiv sample, "∗" came back as "→" and the math letter "𝑒" as "!". Users have reported the same damage from Preview for years ([Zotero forum](https://forums.zotero.org/discussion/comment/274497)). The test ran on PDFKit's own save, not on Preview itself.

Such a file gets new page keys and is parsed again, as a new file. Its summary line warns that a PDFKit save can damage the text, and that an earlier copy may read better. The tool recognizes the save by the file's producer, "Quartz PDFContext". A highlight that an app appends without rewriting the file, as Acrobat saves one, still leaves every page key unchanged.

Task M1.3 checked what a PDFKit save writes: it sets the producer to "macOS Version … Quartz PDFContext", keeps the creator, such as "arXiv GenPDF" or "Microsoft Word", and sets both dates to the time of the save. A file that macOS made in the first place, as the print dialog's "Save as PDF" makes one, carries the same producer, and nothing in the file tells the two apart. So the warning says "made or last saved by macOS PDFKit", and it also shows on files that no save damaged.

| Option | For | Against |
|---|---|---|
| **A new file, with a warning** | Nothing wrong is ever served, and the agent learns why the text may be poor. | The file is parsed again, and its damaged text is what the agent reads. |
| The earlier copy's pages, reused while the character positions line up | The agent keeps the good text. | A real edit that keeps the positions would be served stale, and wrong is way worse than missing. |
| The earlier copy's reading offered beside the new one, to pick with `pdf pick` | Nothing lost and nothing silently wrong. | Needs a history of each file's earlier copies. |
