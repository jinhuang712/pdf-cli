# 031. a keyword index of every paragraph, kept with the page's result

Decided: 2026-10-15    Status: current

`pdf search` finds words with SQLite's FTS5, one row per text block, so a hit names its paragraph and `pdf read --from` goes straight there. The row joins the index in the same transaction that caches the page, and deleting a page's result deletes its rows, by a trigger, so the index never disagrees with the cache. Pages cached before the index existed join it the first time a search looks at their document: 290 ms for the 456-page file, about 0.6 ms a page.

- **Words:** the tokenizer is `porter unicode61 remove_diacritics 2`: "dropouts" finds "dropout", and "cafe" finds "café". Every word of a query must be in the same paragraph; when none holds them all, paragraphs that hold some of them follow, marked as such. Each word is quoted, so no query is read as FTS5 syntax.
- **Scripts without spaces:** the tokenizer reads a run of Chinese or Japanese characters as one word, so the index splits each such character apart, Korean syllables too, with a thin space that snippets take out again, and a query's run becomes a phrase. "深度学习" then finds "基于深度学习的方法". A thin space the text holds itself stays in the snippet.
- **Rank:** SQLite's BM25, best first. It favors short paragraphs, so a heading that names the words can come before the paragraph that discusses them.
- **Patterns:** `--regex` runs over each file's text with a line break between paragraphs and pages, so a match can cross a line, a column or a page. NSRegularExpression has no time limit, and a pattern with nested repeats, as `(\w+\s?)+QQQ`, ran over a minute on an 11-page paper in the review, so the command stops itself after 10 s with an error that says why. A pattern stops counting at 10,000 matches in a file, and the summary says so.
- **Waiting:** a search of one PDF that is not fully parsed waits up to 10 s for its pages, then searches those that are parsed and says how many. A search of the library starts no parse: a library of hundreds of PDFs would otherwise parse them all. Copies of one file in the library are one document, searched once.
- **Backfill:** pages cached before the index join it a few hundred at a time, so no transaction holds the write lock long enough to stall a runner, and only while their result is still cached.

Searches took 34–79 ms on cached files. Naming each hit's section costs more on a file without bookmarks, whose headings need every page decoded: 307 ms on the 456-page file (plan/TODO.md).

| Option | For | Against |
|---|---|---|
| **One row per paragraph** | A hit names its paragraph, and the agent reads from there. | More rows: 12,846 for 456 pages. |
| One row per page | Fewer rows. | A hit names only its page, and words from unrelated paragraphs of a page match together. |
| A scan of the cached text with each query | No index to keep. | Every search decodes every page: about 300 ms for 456 pages, and more across a library. |
