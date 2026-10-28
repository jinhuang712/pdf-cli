# 040. a loud failure for a file PDFKit cannot open

Decided: 2026-10-15    Status: current

When PDFKit cannot open a file, the whole file fails with a reason the agent can act on: not a PDF, locked by a password, or damaged. The tool reads nothing else from it. This follows the PDFKit decision, which keeps PDFium out of the binary, and "Wrong is way worse than missing" in [PHILOSOPHY.md](../../PHILOSOPHY.md). How often a file fails this way is unmeasured. The safety test set holds broken PDFs, and the decision reopens if daily use or the open test set shows such files are common.

| Option | For | Against |
|---|---|---|
| **A loud failure** | Apple-only, with nothing to bundle. The agent learns at once, and can tell the user. | A damaged file that PDFium could read stays unread. |
| PDFium as a fallback | Opens many damaged files. | A non-Apple library in the binary, which the PDFKit decision keeps out. |
| A repair tool the user has installed, such as qpdf | Repairs many damaged files. | Depends on what each Mac has, so one file gives different answers on different Macs. |
