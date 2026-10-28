# 028. a shared pool of worker slots, with pages nobody waits for in the background

Decided: 2026-10-15    Status: current

Every parse by one user on the Mac shares one pool of worker slots, kept in that user's cache folder: half the performance cores, and at least 2. That is 2 on the M3 with 4 performance cores. Before, each runner started one worker per performance core for its own file, so an agent reading three new files ran up to twelve workers, and the author's Mac lagged while task M1.3's measurements ran.

- A slot is an exclusive `flock` on a file in the cache folder. The kernel frees the lock when its holder exits, so a crashed runner never keeps a slot.
- Slot 0 is kept for work a command waits on: the pages it asked for, and a new file's index and sample check. The command hands its pages to the runner it starts, so the runner's first batch already knows them. A pool of one slot shares slot 0, and pages nobody asked for yield it: they take it only while no command is waiting for a slot, and the runner stops a background worker in it when one starts to wait (M2.11; a light budget makes a pool of one).
- Pages nobody asked for take the other slots, and their workers put themselves in macOS's background state, which runs them at the lowest priority. A CPU loop ran 2.4 times slower in that state, as on the efficiency cores, where [Eclectic Light's measurements](https://eclecticlight.co/2025/05/09/what-is-quality-of-service-and-how-does-it-matter/) find background work kept.
- When a command asks for a page that a background worker holds, the runner signals the worker, and the worker leaves the background state. macOS lets only a process move itself into that state or out of it.
- A page that runs out of time in the background gets one more try at full speed before it fails, because the 30 s limit counts wall time, and a throttled worker can pass it through no fault of the page.

Measured with the release build on the M3:

| File | Page 1, unseen | Page 2 right after | The rest, in the background | Every page, waited on |
|---|---|---|---|---|
| A paper, 11 pages | 0.78 s | 0.08 s | 1.4 s | |
| The paper that needs the space repair, 18 pages | 1.40 s | 0.52 s | 49 s | 8.2 s, against 6.9 s with four workers before |
| The NACA scan, 30 pages | 1.08 s | 0.94 s | 6.9 s | |
| The 456-page file | 0.79 s | 0.06 s | 43 s | 7.6 s |

The pages an agent waits on keep their speed, because OCR leans on the graphics and neural chips more than on the cores. The cost falls on pages nobody waits for: a file that needs OCR finishes in the background about seven times slower.

| Option | For | Against |
|---|---|---|
| **A shared pool of `flock` slots, with background workers that a request promotes** | Caps the whole Mac, however many files an agent reads at once. The page the agent waits on runs at full speed. Nothing to install. | A runner checks for a free slot every 20 ms, and a file that needs OCR finishes in the background about seven times slower. |
| One worker per performance core in each runner | The fastest full parse. | Three files at once run twelve workers, and the Mac lags. |
| A counting semaphore | One call takes a slot. | A process that crashes while holding a slot never gives it back. |
| A queue in a background service | Exact fairness between files. | A service to install and run, which the decision on worker processes above rejects. |

Holds as: `scripts/test-cache.sh` reads three new files at once and never sees more than two workers, a page asked for while a background worker holds it brings that worker out of the background state, and a page that hangs only in the background reads at its full-speed try.
