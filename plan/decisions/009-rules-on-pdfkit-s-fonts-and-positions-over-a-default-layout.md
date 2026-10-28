# 009. Rules on PDFKit's fonts and positions over a default layout model

Decided: 2026-10-14    Status: current

Figures, footnotes, headings, running headers and footnote markers come from simple rules on what PDFKit and Core Graphics report: fonts, sizes, positions and drawing commands. A layout model joins only when a goal fails without it, as the principle "Apple's engines first" says. The decision is provisional, like the text-source decision.

| Option | For | Against |
|---|---|---|
| **Rules, no model** | Apple-only, with nothing to download. Found 54 of 54 figures with their captions on 116 spike pages, at about 9 ms per page ([spike/M0.3b-figures-base.md](../../spike/M0.3b-figures-base.md)). | Tuned on the same papers it was tested on. Rules for footnotes and headings are untested. Scans need OCR's structure instead. |
| egret-medium in `pdf setup` | Labels footnotes, headings, captions, formulas, lists, headers and footers in one pass, in 15–27 ms per page. About 50 MB. | A download, and its accuracy on our own pages is unmeasured. |
| heron in `pdf setup` | The larger Docling model, in 23–29 ms per page. | About 100 MB, with the same unmeasured accuracy. On the spike's scan, it and egret disagree. |
