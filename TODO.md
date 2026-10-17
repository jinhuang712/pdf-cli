# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- A content stream of 600 KB that inflates to 600 MB of `q Q` runs its page out of time, 30 s, and the worker to 1.3 GB, in the build before M1.12 too; under a 400 MB limit the page fails by memory. The page fails with its reason and the tool goes on, but something holds the decoded stream: find what, likely the drawing of the page for the ink check, and bound it. Found by M1.12's review, `/private/tmp/claude-501/m112rev/pdfs/bomb-600.pdf`. Noted 2026-10-17.
- Links past the first 1,000 of a file are not shown: TeX Live's PGF manual holds 44,700, so most of its pages show none. Keep annotations per page in a table of their own, not in the file's facts, which every read decodes, and read their words for the pages asked for. Noted 2026-10-17, in M1.13.
