# 046. two OCR readings compared, over OCR's own confidence

Decided: 2026-10-15    Status: current

Every page that OCR reads is read a second time, and the share of the first reading's words that the second also finds is the page's OCR score. Under 0.85, the page, or a block with at least 20 words of four letters or more, is `low-quality`. When the second reading fails, the page is judged on the first alone. On macOS 26 the second reading comes from the older text recognizer. Before macOS 26 that recognizer is the only one, so it reads the image again at 70% of its size. Words of four letters or more are compared, and in Chinese, Japanese and Korean text, pairs of neighbouring characters.

Task M1.3 made 33 scans from three pages, two arXiv papers and the 1951 NACA report, at 40–200 dpi, some blurred or noisy, and compared each signal with the share of OCR's words that were right:

| Signal | Pages with at least 90% right | Pages under 80% right | Verdict |
|---|---|---|---|
| **Two engines' word agreement (macOS 26)** | 0.89–1.00 | 0.83 or less | Separates them |
| **The older recognizer against itself at 70% size** | 0.89–1.00 | 0.83 or less | Separates them |
| The older recognizer's confidence | 0.97–1.00 | up to 0.99 | Overlaps: 0.94 at 47% right |
| The document recognizer's confidence | 0.51–0.62 | 0.18–0.73 | Overlaps: 0.52 at 15% right |
| Share of words in macOS's word list | 0.74–0.94 | up to 0.82 | Overlaps, and favours English |
| The older recognizer, accurate against fast | 0.14–0.97 | 0.00–0.01 | The fast mode fails good pages |

Pages between 80% and 90% right fell on either side. On the real samples, the two synthetic scans scored 0.98–1.00, and two NACA pages 0.91. The NACA cover scored 0.78: its small print had come back as "Corernment Printing Ofice.-Wathingion", and the check flagged it. Its blocks are too short to judge one by one, so the whole page went out as a failure block. The second reading costs about 0.8 s per page: a scan's first page came back in 1.74 s, against 0.90 s without it. Scans are outside goals G2 and G3.

The quality is judged when a page is read, from the measures the parse stored, so a threshold tuned later applies to every cached page without parsing it again. The measures are stored twice: in the page's layer, and on their own beside it, so `pdf ls` judges every page in the library without decoding a layer, 13 ms for 709 pages against 87 ms. A page cached before they were stored on their own gets them the first time a listing judges it.

| Option | For | Against |
|---|---|---|
| **A second reading compared with the first** | Tracks accuracy on every macOS version. Any script compares, Chinese, Japanese and Korean by pairs of characters, though only English pages were measured. | About 0.8 s more per page read by OCR. |
| OCR's own confidence | Free. | Does not track accuracy, as the table shows. |
| The share of dictionary words | Cheap. | Overlaps, and flags every page that is not in English. |
