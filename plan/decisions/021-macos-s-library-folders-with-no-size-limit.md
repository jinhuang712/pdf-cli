# 021. macOS's Library folders, with no size limit

Decided: 2026-10-15    Status: current

What the tool can rebuild from the PDFs goes to `~/Library/Caches/pdf-cli/`: the SQLite cache with its keyword index, and the crop images. The agent's own work goes to `~/Library/Application Support/pdf-cli/`: the library list, picks and transcripts. These are the folders macOS sets aside for each kind of data, so a cleanup tool that clears caches costs time and leaves the agent's work intact.

The cache keeps every parse result until `pdf rm` or `pdf clean` removes it, as the principle "Pay once, read many times" says. Crop images are the exception: each one goes 7 days after it is written, because making it again needs no parse.

The 10 sample papers hold 3.8 KB of text per page, measured with PDFKit. With positions and the keyword index, a page likely takes 10–20 KB, so a 30-page paper takes about 0.3–0.6 MB, against 1.6 MB for the average sample PDF itself. The estimate stays unmeasured until the cache exists.

| Option | For | Against |
|---|---|---|
| **Library folders, no size limit** | macOS's own convention. A cleared cache costs only time. Nothing is parsed twice. | The cache grows with every PDF an agent opens, because any command adds a PDF on first use. |
| A size cap that removes the least recently read PDFs | Disk use stays bounded. | A removed PDF is parsed again. For a 300-page scan, that is about 3 minutes of OCR on one worker, at 0.6 s per page. |
| One dot-folder, such as `~/.pdf-cli/` or `~/.cache/pdf-cli/` | One place that command-line users know. | Mixes rebuildable data with the agent's own work, and follows Linux's convention instead of macOS's. |
