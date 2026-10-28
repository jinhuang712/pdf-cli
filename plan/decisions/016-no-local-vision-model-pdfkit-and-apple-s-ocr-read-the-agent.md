# 016. no local vision model; PDFKit and Apple's OCR read, the agent looks

Decided: 2026-10-18    Status: current

The user dropped M3.3, the local vision model for hard pages and formulas, on 2026-10-18: PDFKit and Apple's OCR carry the text, and what they cannot read for certain, a page in doubt, a table or an equation, goes to the agent as a crop. plan/GOALS.md measures two setups, Base and Layout, no longer Full. M1's test sets read well so far, but no goal is measured yet: a goal that fails on scans OCR reads badly shows at the final wrap-up.

| Option | For | Against |
|---|---|---|
| **No vision model** | Nothing more to download or keep, and one engine fewer whose readings can be wrong; the agent reads what needs eyes. | A scanned page that OCR misreads is flagged and cropped, and `pdf search` cannot find its words. |
| A local vision model through MLX Swift (M3.3) | Reads hard scans and formulas without the agent, and their words reach the index. | Gigabytes to download, macOS 14 on Apple Silicon and a helper binary, and readings that are not right for certain. |
