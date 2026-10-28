# 018. citations judged at read time by rules; cross-references as links to a page

Decided: 2026-10-19    Status: current

M2.8 finds lists of references, their entries and the citations that lead to them with rules, as M2.7 finds notes, and judges them when a page is read, against the pages parsed so far: a list starts at a heading "References", "Bibliography" or the like, often pages after the text that cites it, so no page alone can tell its entries from text. Its entries are numbered, keyed, or by author and year, and a citation leads to the nearest list after it that holds every entry it names. Printed citations stay as printed; a raised number that cites the list shows as `[12]`, in a document that cites so more often than in brackets, so that a square in a paper citing `[12]` stays a square. `pdf ref <pdf> 12` shows one entry with its DOI and the places that cite it, and `--refs end` lists the entries the output cites, after it, charged where they are cited, as notes are. "Fig. 4", "Eq. (5)" and "Section 3.2" become links to the page that holds what they name, `[Fig. 4](#p.7)`, in the form the file's own links to a page take. The parse gains one rule, parser version 18: a line that comes back to its block's left edge after lines set in, a hanging indent, starts a block, so the entries of a list by author and year come apart.

| Option | For | Against |
|---|---|---|
| **Rules at read time; links to a page** | Nothing to download or run; the list may be any pages away from its citations; the agent knows the link form already. | A list without a heading, numbers set in a column of their own that do not count out, or a name with a particle, link nothing; the lists come from the pages parsed so far. |
| A reference parser, as GROBID or CERMINE | Trained on many styles; parses an entry's authors, title and venue. | Java and a server or a model to download, for fields the agent can read in the entry's words. |
| Lists found in the parse, page by page | Found once. | A page alone cannot tell a list's second page from text, nor which list a citation names. |
| A cross-reference as "Fig. 4 (p.7)" | Reads as prose. | Looks like the document's own words, and a second form for the same thing a link to a page already says. |

Cost: a first read of a file before its last pages parse has no list yet, so raised citations stay raised and `--refs end` lists nothing, and the summary line says the read is provisional. An entry's text is its words as PDFKit gives them, the backrefs of LaTeX's `backref` included. Holds as: no text a reader of the page cannot see goes into an entry, a citation or a link, and nothing is dropped: an entry no citation leads to is still listed by `--ref`.
