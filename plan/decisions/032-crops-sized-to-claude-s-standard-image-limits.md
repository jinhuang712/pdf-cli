# 032. crops sized to Claude's standard image limits

Decided: 2026-10-15    Status: current

`pdf crop` draws a page or a region at the largest size that fits Claude's standard limits: 1,568 px on the long edge and 1,568 image tokens, where a token is a block of 28×28 px. A crop then costs at most about 1,568 tokens on any model, and no model shrinks it. A whole sample page came to 945×1223 px and about 1,500 tokens; a region comes out enlarged, up to 6 times, 432 dpi, past which a scan gains no detail. The limits come from Claude's vision documentation ([platform.claude.com](https://platform.claude.com/docs/en/build-with-claude/vision)), checked on 2026-10-15: newer models accept up to 2,576 px and 3.75 megapixels, and the rest shrink anything past 1,568 px.

- **Where:** a worker draws the image, since drawing opens PDF content (Principles → Safety), within the page's time and memory limits, in a slot of the shared pool.
- **Which way up:** a region is given in fractions of the page as stored, before its rotation, the same frame as the positions in `pdf read --json` and the crop commands in failure blocks. The image comes out upright. A test draws a black box and crops it at 0°, 90°, 180° and 270°.
- **Rounding:** a region is rounded outward to hundredths of the page, its near edges down and its far edges up, and that region is both drawn and named. Rounding to the nearest hundredth, as the first version did, cut 4 pt off a block's edge and turned a region thinner than half a hundredth into the whole page, as the review found.
- **What it shows:** the page as a reader sees it, comments and highlights included. So the image belongs to one version of one file, its path and state, not to the document shared by every copy.
- **Kept:** in the cache folder for 7 days; the same command within them answers in about 35 ms, and `pdf clean` removes older images. A finished image replaces the old one at once, with `rename(2)`, and a folder is removed only when it has been empty for an hour, since a crop waiting for its worker holds an empty folder: removing it at once failed 9 of 10 crops run together in the review.
- **Locked files:** `--password-stdin` hands the password to the worker in its environment, as `pdf add` does.

Crops took 90–120 ms on cached files with the release build, and 0.84 s for the first crop of an unseen 456-page file, most of it the index.

| Option | For | Against |
|---|---|---|
| **Claude's standard limits** | The same cost on every model, about 1,500 tokens for a page; nothing shrinks it. | Small print on a whole page is near the edge of legible; the agent crops a region for it. |
| The newest models' limits | Sharper pages, 2,576 px. | About 3 times the tokens a page, on the newest models, and shrunk to the standard size on the rest. |
| A fixed resolution, such as 150 dpi | Simple. | A page's cost varies with its size, and a large page is shrunk by the model anyway. |
