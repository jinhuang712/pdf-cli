# OCR test files: sources and licences

`scripts/make-ocr-fixtures.swift` makes these files from the first two pages of `testdata/smoke/arxiv-2608.04589.pdf`, "The First EgoCross Challenge at EgoVis 2026: Cross-Domain Egocentric Video Question Answering" (https://arxiv.org/abs/2608.04589), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Each page is rendered as a grey JPEG at 150 dpi, like a scanner's output.

| File | Text layer | What it tests |
|---|---|---|
| scan-no-text.pdf | none | A scan with no text is read by OCR, page by page. |
| scan-right-layer.pdf | hidden text with the page's real words | A scan whose old OCR layer is right keeps it. |
| scan-wrong-layer.pdf | hidden text with every letter shifted by one, as a broken font table can make it | A file whose text layer fails the sample check is read by OCR, every page. |
