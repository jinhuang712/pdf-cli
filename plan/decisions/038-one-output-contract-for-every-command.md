# 038. one output contract for every command

Decided: 2026-10-25    Status: current

Every command, the ones that only write included, takes `--json`, ends with the exit codes of F8 (0, 1, 2, 3, 64) and reports a failure in one shape: `<path>: failed: <reason>`, or the same as an object with `file` and `failed` under `--json`. The commands that change the cache (`pick`, `transcribe`, `rm`) take `--dry-run`, which says what they would do and does nothing. The review of 2026-10-25 found the contract kept by `read` alone: `dump` ended a failed file with 3 on one path and 1 on another, `ls`, `rm`, `pick` and `transcribe` had no `--json`, and an agent that parses the output of one command had to learn another's.

| Option | For | Against |
|---|---|---|
| **The contract on every command, with a test that holds each command to it** | An agent learns the output once, and a command that breaks the contract fails a test. Shrinks the guide, which now says it for some commands and not others. | A change to every command, and exit codes that were 1 or 3 by habit change. |
| `--json` on the commands that read, none on the ones that write | Less work. | The writes are the commands whose result an agent most needs to be sure of. |
| Leave each command to its own | No work. | The cost falls on every agent, every time. |

Cost: the tool has no outside users yet (version 0.0.0), so no exit code needs to stay as it was. Holds as: a test runs each command with `--json` and parses the output, and another checks the exit code of a missing file, a file that is not a PDF and a wrong flag against the table.
