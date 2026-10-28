# 053. OCR hides text PDFKit leaves out when the page draws it and no reader sees it

Decided: 2026-10-25    Status: current

OCR reads PDFKit's rendering, which draws a form in a layer switched off and leaves annotations out. Text PDFKit leaves out of its text (as a Type 3 font with no text map) that sits in such a form, or under an annotation, was read by OCR as plain text on a scan's first reading and after `pdf reparse --step ocr`, and found by search (M2.10's review, H1; M2.19). `Visibility.unseen` finds such strings from the page's drawing commands, as `unread` finds text PDFKit left out, and `TextLayer.read` gives their places to the hidden spots that `OCR.markHidden` puts the OCR lines over under a hidden run (parser version 20). A string counts where the page drawn without annotations has ink in its tight glyph box (no side margins, from 0.2 em below the baseline to 0.8 above, so a border or a neighbour's ink does not count) and either its form is switched off or the page as a reader sees it has none. Where the check cannot reach (a form nine deep, more than 500 places), the page says its hidden-text check is incomplete, which a page read by OCR now carries over from its text layer.

Options it beat:

| Option | For | Against |
|---|---|---|
| **Drawing commands plus ink with and without annotations, tight box** | Marks what PDFKit's text does not hold; a visible word or a white one in a gap is not hidden by mistake. | A line OCR reads that holds one hidden word goes under the marker whole. |
| Padded box and PDFKit's neighbouring boxes (the first build) | Same code as the flagging of unread text. | Other ink near the string, as a border or a line above, hid the string from the check: it leaked. A white word in a gap of a visible line hid the visible line. |
| Hide every OCR line over any text the drawing commands show | Simple. | A scan's own text layer lies under its image: it would hide the scan. |
| Read the page again by OCR as a reader sees it | The same words, no commands. | PDFKit draws the form in a layer switched off whatever is asked, so no rendering shows the reader's page. |
