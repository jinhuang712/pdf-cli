# 039. `read` reads, `note` and `ref` look up, `--show` shows what was set aside, `doctor` cleans

Decided: 2026-10-25    Status: current

`pdf read` has 15 options in five jobs: choose the range, choose the format, choose what to show, look up one thing, and set the cost. The review of 2026-10-25 moves two of them out and joins three:

- `pdf note <pdf> 7` and `pdf ref <pdf> 12` replace `pdf read --footnote 7` and `--ref 12`. They look one thing up, are not paged and not held to the budget, and take `--json`. `read` keeps `--notes` and `--refs`, which choose where the notes and references the text cites show.
- `--show raw,hidden,headers` replaces `--raw`, `--include-hidden` and `--headers`: one option for "show what normal output set aside", in the order the `next:` lines print it. The summary line and the failure blocks name `--show raw` where they named `--raw`. Built in M2.17: `--show` takes a comma list or repeats, another value ends 64 and lists the three, and the three old flags stay as hidden stubs that end 64 with a pointer (`--raw` is now `--show raw`) and run nothing; they are no aliases.
- `pdf doctor` (F12) takes over `pdf gc`. Cleaning the cache is a maintenance job beside showing its size, and it gets `--dry-run`.

| Option | For | Against |
|---|---|---|
| **Look-ups as commands, one `--show`, `gc` into `doctor`** | A leaner `read`; each command does one thing; fewer names for an agent to hold. | The old names go, and they stand in the guide, the tests, the smoke scripts and the user's installed skill, which needs `pdf agent-guide --install claude-code` again. |
| Keep every flag, add the commands as aliases | Nothing breaks. | Two ways to say each thing, and a guide that must teach both. |
| Split `read` into `read`, `show`, `lookup` | Cleanest on paper. | A longer path to the common read; the review judged the gain too small. |

The gain of `--show` is the smallest of the review's items, 5 of 20 on its scoring, and one flag to remember in place of three can be harder to remember; the user chose to do it all but one item (2026-10-25), so it is the last task and may be dropped. The old flags go without an alias: the tool is at version 0.0.0 and has no outside users. Cost: the rename reaches 21 files. Holds as: the guide test names every flag of every command, so a flag left behind fails it.
