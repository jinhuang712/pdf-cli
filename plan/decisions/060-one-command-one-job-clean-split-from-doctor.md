# 060. one command, one job; clean split from doctor

Decided: 2026-10-26    Status: current

The agent-usability review judged the CLI mostly good and found `pdf doctor --clean` odd: a command that shows now deletes, behind a flag. M3.7 splits it. `pdf clean` removes what no read can use, with `--dry-run` and `--json` and the output `doctor --clean` had; `pdf doctor` only shows. `pdf doctor --clean` stays as a hidden stub that ends 64 and names `pdf clean`, as `pdf gc` and the old `read` flags do. The same task makes flags that cannot go together end 64 with a line naming both, and states each command's rule in its own `--help`.

| Option | For | Against |
|---|---|---|
| **Split `clean` from `doctor`** | A command that reads never deletes; an agent told "run doctor" cannot remove data; `--dry-run` belongs to the one command it is about; the guide's `--dry-run` line names `clean` like `rm`. | One more name for an agent to hold (it shares a row with `doctor` in the guide). |
| Keep `doctor --clean` | No new name. | Diagnosis and deletion behind one word; `--dry-run` is an error without `--clean`. |
| Merge `dump` into `read` | One command less. | `read` is paged text for the agent's context and `dump` writes files; the flags do not overlap. Not asked for. |
| Merge `pick` and `transcribe` | Both keep what the agent decided. | One chooses between two readings, the other stores text from standard input. Not asked for. |

Only `clean` was split, because it was the one the user named.
