# 004. Apple PDFKit over PDFium and a parser of our own

Decided: 2026-10-14    Status: current

PDFKit and Core Graphics parse and render, and PDFKit is the only text source in the binary. PDFium stays out of the binary, and the test scripts use it to cross-check PDFKit. The decision is provisional: it reopens if Apple's engines fail a goal on the open test set.

The M0 spike compared the engines on 10 recent arXiv papers ([spike/M0.2-text.md](../../spike/M0.2-text.md), [spike/M0.3-reading-order.md](../../spike/M0.3-reading-order.md)):

- PDFKit read about 9 ms per page, process start included, and PDFium about 2 ms.
- PDFKit kept two-column text in order best: 50 jumps between the left and right halves of the page on 36 pages, against 66 for PDFium, 112 for poppler and 121 for Apple's document recognizer. A clean page has one jump. The count is indirect, because a full-width figure makes some jumps correct.
- PDFKit ran words together on 1 of the 10 papers. The next decision records the cause and its repair.

| Option | For | Against |
|---|---|---|
| **PDFKit and Core Graphics** | Ship with macOS, and Apple maintains them. Crops look exactly like Preview. The best column order in the spike. | Closed: the project cannot fix their bugs, and their behavior can change between macOS versions. Some fonts make it drop spaces. |
| PDFium | Chrome's engine, open source under BSD, with years of fixes for broken files. Kept every space in the spike. | One more library to bundle and update, outside Apple's engines. |
| hayro | A pure-Rust PDF renderer under Apache-2.0, in active development. | Young, and Rust in a Swift project. |
| MuPDF and PyMuPDF | Fast and complete. | AGPL, which a permissive public repo cannot take on. |
| A parser of our own | Full control. | Years of work to handle broken files as well as PDFium, with no difference a user could see. |

PDFKit wins because of the principle "Apple's engines first": its one failure in the spike has a known cause, and an Apple-only repair that matched PDFium.
