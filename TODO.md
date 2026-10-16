# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- Flag a page whose drawing commands show text that PDFKit leaves out of the page's text, as after an unbalanced `q` inside a form: today that text goes missing without a trace. The hidden-text scanner places every string a page shows, measured by its font's widths, since the M1.10 fourth review: a string drawn where PDFKit has no text would find the gap, even in a CID font, whose strings spell as mojibake. Found in the M1.10 review, 2026-10-15.
