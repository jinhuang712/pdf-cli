# 023. a password reaches the workers in their environment

Decided: 2026-10-15    Status: current

`pdf add --password` hands the password to the runner it starts, and the runner's workers inherit it, in an environment variable. Any user on the Mac can read another user's command lines with `ps`, and only the same user can read a process's environment: on the M3, `ps` showed root's command lines and none of root's environments. `pdf add --password <pw>` itself still shows the password in its own command line while it runs, so `--password-stdin` reads it from standard input instead. The password is not stored: a later read of the file comes from the cache, and a file that changes needs `pdf add --password` again. A file the cache knows as locked is indexed again when a password comes. A read without the password that needs a page not yet cached fails the file as locked, and caches no failure for the page.

| Option | For | Against |
|---|---|---|
| **The environment** | Hidden from other users. Nothing stored. | Visible to the user's own processes while the parse runs. |
| A command-line argument | Simple. | Every user on the Mac can see it in `ps`. |
| The macOS keychain | Stored safely, so a changed file opens without asking again. | A keychain prompt in the middle of an agent's work, and a secret kept after the agent is done. |
