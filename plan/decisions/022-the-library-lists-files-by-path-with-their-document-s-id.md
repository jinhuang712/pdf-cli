# 022. the library lists files by path, with their document's ID

Decided: 2026-10-15    Status: current

The library list holds one entry per file path, with the file's document and its title. Every command that reads a file adds it, or points it at its new document when the file changed. A file already listed as it is costs one read of the list and no write, so a cached read stays fast. The ID that commands show is the first 8 hex digits of the document's ID, which hashes the page keys, so two copies of one file share an ID. `pdf rm` accepts any 4 digits or more from its start.

`pdf rm` forgets the file and drops every document and page result that no other file still uses. Picks stay: they are the agent's work, kept apart from the cache, and a file added again shows them again. `pdf clean` (which took over `pdf gc`) also forgets files that are gone or changed since they were indexed, results of older parser versions, and the locks of runners that are gone. It then rebuilds the database to give the space back, and empties SQLite's write-ahead log after the rebuild, since the rebuild writes through it: without that, a trial freed nothing.

A cleanup never takes what a read still needs:
- A runner saves a document, its file and the pages its index could not read in one transaction, and the cleanup deletes a file's entry only while it still holds the state it read, so a parse in progress keeps its rows.
- The rebuild holds SQLite's write lock, which would make a runner's writes fail, so it runs only while no runner is alive.
- A file is gone only when it is missing from a volume that is mounted. A file on an unplugged drive or an offline share keeps its rows and its library entry, and `pdf ls` shows it as out of reach.
- A cache upgrade marks each file to be indexed again on its next read, instead of forgetting it: forgetting every file let a cleanup right after an upgrade drop every cached page, OCR results included, as the M1.5 review found.

| Option | For | Against |
|---|---|---|
| **One entry per path** | A moved or deleted file shows as such, and `pdf rm` takes the path the agent knows. | Two copies of a file are two entries with one ID. |
| One entry per document | One line per PDF, however many copies. | The list cannot say which path to read, and loses track of a moved file. |
