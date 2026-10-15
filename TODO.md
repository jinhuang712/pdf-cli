# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- Ship the licence notice of every model that `pdf setup` downloads. MIT covers only our own code.
- Make `pdf ls` cheap on a large library. It judges every cached page each time, which decodes each page's stored text layer: fine for tens of PDFs, slow for thousands. A per-page record of the measures the verdict needs would avoid the decode. Found in the M1.5 review, 2026-10-15.
