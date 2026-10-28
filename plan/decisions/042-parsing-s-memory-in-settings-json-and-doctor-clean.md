# 042. parsing's memory in `settings.json`, and `doctor --clean`

Decided: 2026-10-25    Status: current

M2.11 built `pdf setup` and `pdf doctor`. Three choices were not written down before.

- **Where the setting lives:** `settings.json` in the agent's folder, `~/Library/Application Support/pdf-cli/`, beside the library. `Env` reads it once for every process, the CLI, the runner and the workers, and `pdf doctor` shows it with its source. Until then the tool had no stored setting, only the `PDF_CLI_*` variables for tests, which still win and are named as the source when they do.
- **What the budget makes:** the worker count is the budget over 2 GB, at least 1 and at most the greater of 2 and the performance cores, and a worker is stopped at 2 GB, or at the budget when that is smaller, so the limits never add up past it. Light, balanced and fastest are worker counts, shown as memory for this Mac: one worker; half the performance cores, at least 2; one for each performance core, at least 2. With nothing set the old default holds, half the performance cores and at least 2, which is `balanced`, so the pool of a Mac that never runs `pdf setup` is what it was; what changes for it is the pressure rule and the OCR halving below, which hold for every Mac. The pool already capped the Mac and kept slot 0 for pages a command waits on; M2.11 added the budget, fewer workers under memory pressure, heat or Low Power Mode, and half as many workers for a file read by OCR or by space repair (never fewer than two where the pool has two). Review of 2026-10-25 found that a pool of one slot, which a light budget or pressure makes, let background parses retake slot 0, so a page a command waits on queued behind them for 30.8 s (16.2 s under pressure): the background workers now yield that slot, and the same read takes 0.8 s.
- **Cleaning is `pdf doctor --clean`:** one flag on the command that shows the sizes, with `--dry-run` beside it, and `pdf gc` ends 64 with the pointer, as the stubs of `--raw` do.

| Option | For | Against |
|---|---|---|
| **`settings.json` in Application Support; `doctor --clean`** | The user's own folder survives a cache clear, `Env` already reads the two folders, and a plain file can be read, tested and removed by hand. `--clean` needs no new command name. | A second kind of file there beside the databases. A user who edits it by hand can break it: `doctor` names an invalid file and the defaults hold. |
| macOS defaults (a plist through `UserDefaults`) | The native place for a setting. | A command-line tool has no bundle to name a domain, `cfprefsd` caches reads across processes, and a test needs the user's real defaults kept clean. |
| The Caches folder | `Env` already reads it. | A cache clear, which the user is told is safe, would drop the setting. |
| `pdf doctor clean` as a subcommand | Reads as a sentence. | A command with a subcommand for one job, where `--dry-run` and `--json` are flags of the command anyway. |
| `pdf doctor --fix` | Familiar from other tools. | Suggests that it repairs problems; it only removes what no read can use, and some problems (an older schema) it leaves to the next normal command. |

Holds as: unit tests store and read back each preset and a number through `Env`, a dry clean changes no byte of either folder, and a clean removes what `pdf gc` removed. The numbers wait for the final wrap-up's measurement of a worker's memory.
