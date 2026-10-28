# 011. Tables as images over rebuilt cells

Decided: 2026-10-14    Status: current

A table reaches the agent as a crop, and the agent reads the cells with its own image understanding. The reason lives in [FEATURES.md → Not planned](../../FEATURES.md#not-planned): a rebuilt cell can be wrong and still look right.

| Option | For | Against |
|---|---|---|
| **A crop, read by the agent** | The agent sees the table as printed, merged cells and odd layouts included. Nothing is rebuilt. | Image tokens for every table the agent reads. A dense table needs a sharp crop, and the agent can still misread a digit. |
| PDFKit text | Free, with the exact digits. | Rows and columns are lost, as the M0 spike showed. |
| Apple's document recognizer | Ships with macOS 26, and returns cells. | Untested on tables, and a wrong cell looks right. |
| A table-structure model, such as the one Docling uses | Built for this job. | A download, and a wrong cell still looks right. |

The table's text stays in the keyword index, so a search still finds the page that holds a table, and `--raw` shows it, labelled as flat text that lost its rows and columns.
