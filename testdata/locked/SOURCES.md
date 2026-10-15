# Locked test file: source and licence

`scripts/make-locked-fixture.swift` makes `locked.pdf` from the first page of `testdata/smoke/arxiv-2608.04589.pdf`, "The First EgoCross Challenge at EgoVis 2026: Cross-Domain Egocentric Video Question Answering" (https://arxiv.org/abs/2608.04589), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). PDFKit saves it locked with the password "open sesame".

| File | What it tests |
|---|---|
| locked.pdf | A locked file fails with a reason that names `pdf add --password`, and `pdf add` with the password reads it. |
