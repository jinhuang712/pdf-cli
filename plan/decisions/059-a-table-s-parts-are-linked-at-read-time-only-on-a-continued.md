# 059. a table's parts are linked at read time, only on a continued caption and the same place on both pages

Decided: 2026-10-26    Status: current

M3.2. A table that runs over a page break is found as one table region per page. `pdf read` links the regions as one table (`continues on p.28`, `continued from p.27`, one `table` id in `--json`), `pdf info` marks the rows, and `pdf crop --table 1` gives a crop per part. The tool still converts nothing: it says which crops belong together, and the agent reads them.

Two table regions on neighbouring pages are linked only if all of these hold: the same number; the later caption, as a reader sees it, says "continued" (or `Cont.`, in nine languages) or repeats the earlier caption in full; the earlier part ends in the page's bottom quarter with no figure or table below it in its columns, the later starts in the top quarter with none above; the same left edge and width within 4% of the page; and each is the only candidate of the other. A chain is followed in both directions, to 60 pages. When any test fails the tables stay apart and the output says nothing about it: a wrong "continues" sends the agent to read rows of another table, which looks right. The links are judged when a page is read, from the table regions the parse stored, against the pages parsed so far, as notes and citations are, so no parse output changes (parser version stays 21) and no cache table is added. A read parses the page past a table that ends the page, and the page before one that starts with a caption saying it goes on, and walks a chain one page at a time, up to 60 pages, so a long table makes the read parse its pages. The output names an open end (`may go on past p.N, not linked`; `continued from an earlier page, not linked`) rather than leaving a gap unsaid. The kept Markdown of a linked table belongs to the whole table.

Options it beat:

- **Link in the parse, by page.** A page cannot see its neighbour's regions, so it could only guess from its own caption; the parse would also need a version bump and a reparse of every file's tables.
- **Store the links in the cache.** The chain depends on which pages are parsed and on both neighbours; a stored link goes stale. A table in the cache would also need the M2.26 lesson (created on every open, outside the schema guard).
- **Link on a same-numbered table on the next page alone.** An appendix that numbers its tables again, or two short tables captioned "Table 1: Results", would join.
- **Link on a table that touches the page's end and a table that starts the next page, without a caption.** The parse finds a table only from its caption, so there is no region to link.
- **Compare the number of columns.** The parse stores no columns, only a box; text lines mix the cells of a row. Left out, the left edge and width stand in.
- **Link when the caption says "continued" even if the earlier part ends mid-page.** Cases seen (NIST AI 100-1's Tables 2 and 3) are a first part that the table finder cut short, so a link would crop a part that stops before the rows; the rule asks for the geometry the user named.
