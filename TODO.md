# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- A content stream of 600 KB that inflates to 600 MB of `q Q` runs its page out of time, 30 s, and the worker to 1.3 GB, in the build before M1.12 too; under a 400 MB limit the page fails by memory. The page fails with its reason and the tool goes on, but something holds the decoded stream: find what, likely the drawing of the page for the ink check, and bound it. Found by M1.12's review, `/private/tmp/claude-501/m112rev/pdfs/bomb-600.pdf`. Noted 2026-10-17.
