# 006. line-end hyphens resolved by the page and macOS's word list

Decided: 2026-10-15    Status: current

PDFKit keeps the hyphen where a word breaks across lines, as in "exam-" and "ple". The text layer joins the two halves when the joined word appears elsewhere on the page, or in macOS's word list at `/usr/share/dict/words`, allowing common endings such as "-s" and "-ed". Otherwise the hyphen stays, as in "self-attention". A capital letter or a digit after the break always keeps the hyphen. When in doubt the hyphen stays, because "data-set" still reads right and a wrongly joined word does not.

| Option | For | Against |
|---|---|---|
| **The page's words and macOS's word list** | Apple-only and fixed, so the same file always reads the same. | The list is old: it lacks "dataset", so such a word joins only when the page spells it whole elsewhere. |
| Every hyphen kept | Never wrong. | "exam-ple" in the text breaks search. |
| Every hyphen dropped | Simple. | "selfattention" is wrong. |
| macOS's spell checker | Knows modern words. | Learns from each user, so two Macs can read one file differently. |
