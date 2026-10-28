# 050. a dry run answers from what is kept and never parses

Decided: 2026-10-25    Status: current

`--dry-run` on `pdf pick`, `pdf transcribe` and `pdf rm` (M2.18) never parses and never starts a runner. It answers only from the cache and the agent's folder, both opened read-only. A page not cached for this version of the file and of the parser fails with exit 1 and the `pdf read` to run: the one case where its exit code differs from the real run's. "Changes nothing" means no row, schema or file content of either database, the cache's write-ahead log included; SQLite may still create or touch the cache's `-shm` index, which holds no data, and a cache whose log files are gone, or from an older schema, is refused with a sentence rather than opened for writing. `rm` counts what would go with SELECTs that mirror its deletes. It holds because the normal flow reads a page before it picks or transcribes on it, so the page is cached.

Options it beat:

- **Parse during the dry run.** It writes results, the index and a library entry, starts runners and can take minutes: not a dry run.
- **Parse in memory, write nothing.** It costs a full parse and adds a second code path that can drift from the real one.
- **Answer "unknown" with exit 0.** An agent cannot tell a yes from a can't-say.
