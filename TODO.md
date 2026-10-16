# TODO

Small fixes and follow-ups with no milestone yet. An item moves to ROADMAP.md once it has a milestone.

- Flag a page whose drawing commands show text that PDFKit leaves out of the page's text, as after an unbalanced `q` inside a form: today that text goes missing without a trace. The hidden-text scanner places every string a page shows, measured by its font's widths, since the M1.10 fourth review: a string drawn where PDFKit has no text would find the gap, even in a CID font, whose strings spell as mojibake. Found in the M1.10 review, 2026-10-15.
- Fix the M1.10 fifth review's findings, or record them as limits in FEATURES.md → F9 → Gap: 9 leaks, 2 false marks, a crash on a hostile widths array and a spec gap in visibility expressions (reports/M1.10-hidden.md → Fifth review). Found 2026-10-16.
