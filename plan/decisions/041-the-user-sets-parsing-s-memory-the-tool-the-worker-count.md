# 041. the user sets parsing's memory, the tool the worker count

Decided: 2026-10-17    Status: current

The agent is the tool's main user, so the user asked whether the agent should choose how many workers run. It should not choose the number: the pool caps the whole Mac across every session and file, an agent sees the machine once a command and has no way to agree with other agents, and an agent leans to "faster" while the user feels the lag. What the user knows, and the tool cannot, is how much of the Mac parsing may take; what the agent knows is how soon it needs the pages.

So `pdf setup` (M2.11) asks the user once how much memory parsing may take, as light, balanced or fastest, each with its numbers, or a number. A command run by an agent never asks, as no one may be at its terminal: until the user answers, a safe default holds, and the agent guide has the agent ask the user and run `pdf setup` for them. The worker count follows from the budget and the cores; each worker's limit comes out of the budget, OCR pages count for more, and fewer workers run when macOS reports memory pressure, heat or Low Power Mode. An agent says how soon it needs pages only by what it asks for: the pages a command waits on run first, and the rest of the file follows in the background. It never says how many workers.

| Option | For | Against |
|---|---|---|
| **The user's memory budget in `pdf setup`; the tool sets the count; the agent gives urgency** | The machine's owner decides what the machine gives; one cap holds across every session. | Each worker's memory, on text and on OCR pages, is not measured yet, so the budgets' numbers wait for the final wrap-up. |
| The agent picks the worker count | It knows how much it is about to read. | Several agents at once add up past any cap; none sees the user's lag. |
| Ask the budget the first time `pdf` runs | No extra command. | `pdf` runs in an agent's shell with no one at the terminal: the question would hang the command. |

Searching runs no worker: SQLite answers in the command's own process. OCR runs inside a page's worker, as a step, on the neural and graphics chips more than the cores; whether it needs a limit of its own waits for the measurement of one, two and three at once.
