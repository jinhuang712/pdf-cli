# 007. Apple Vision over Tesseract and RapidOCR

Decided: 2026-10-14    Status: current

Vision reads scanned pages and garbled pages.

- It runs on the device and on the Neural Engine.
- It installs nothing, because it ships with macOS.
- On macOS 26, its document recognizer returns paragraphs, tables and lists, along with the text.

Tesseract and RapidOCR would each add an install and a model to ship. On older macOS versions, Vision falls back to plain text recognition, without the document structure.

The document recognizer reads scans and repairs spaces, and PDFKit sets the reading order of born-digital pages. On 36 born-digital two-column pages in the M0 spike, the recognizer mixed the two columns badly on 2 pages and took a median 0.67 s per page ([spike/M0.3-reading-order.md](../../spike/M0.3-reading-order.md)).

Task M1.4 sends a page to OCR when its text layer is unusable:
- the page draws an image and has fewer than 10 letters and digits, or letters and digits make up under 30% of its characters, as in an old OCR layer of stray marks;
- at least a tenth of its characters, and at least 10, are replacement characters, private-use characters or controls;
- or its file failed the sample check (see Silent errors).

On the samples, no page of the ten born-digital papers went to OCR, and 3 of the scan's 30 pages did, one of them an old layer of 44 stray marks where OCR read 287 words. An OCR'd page took 0.4–1.0 s. Its boxes map back to the unrotated page: on a page turned 90°, 180° or 270°, OCR's blocks sat within 2.3% of the page from the text layer's.
