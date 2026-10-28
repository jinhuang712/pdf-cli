# 019. alt text as hidden text, shown only with `--include-hidden`

Decided: 2026-10-17    Status: current

(Since M2.17 the flag reads `--show hidden`; the text below is as decided.)

A tagged file's alt text for a picture is text a reader of the page never sees, as a stamp's name, which M1.14's review found could carry a planted line into the output. So it is a hidden-text marker after the figure or picture, counted with the page's hidden places, and its words, labelled, only with `--include-hidden`. The user chose this over showing it by default with a label: it keeps goal G16, every planted hidden text kept out of normal output, and leaves the agent to decide whether to read it. The safety set's `hidden-figure-alt.pdf` plants a line there; G16 holds at 72 of 72.

| Option | For | Against |
|---|---|---|
| **A marker; its words with `--include-hidden`** | G16 holds, and the agent asks for the words when a picture matters. | A file's honest description of a chart costs the agent a second read. |
| Its words by default, labelled as hidden | No second read. | Planted words reach the agent's context on every read; G16 would need to change. |
| Not read | Nothing to plant. | Loses what accessible files say about their pictures. |
