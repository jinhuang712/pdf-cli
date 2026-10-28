# 020. SQLite over qmd and Tantivy

Decided: 2026-10-14    Status: current

One SQLite file holds the cache and both kinds of search.

| Option | For | Against |
|---|---|---|
| **SQLite** | One file holds pages, positions, the keyword index (FTS5) and the vectors. It serves several agents at once, and GRDB.swift makes it native to Swift. | Search by meaning needs a vector extension. |
| qmd | Keyword search, search by meaning and reranking, with an MCP server already built. | Needs Node, reads only Markdown files, and keeps its index apart from our page positions. |
| Tantivy | A fast full-text engine. | A Rust dependency in a Swift project, and a second store beside the cache. |
