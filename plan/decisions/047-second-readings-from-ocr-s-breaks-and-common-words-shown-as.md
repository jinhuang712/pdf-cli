# 047. second readings from OCR's breaks and common words, shown as unsure blocks

Decided: 2026-10-15    Status: current

Where the space repair leaves a word in doubt, the output shows the text layer's reading and a second one, and the agent picks with `pdf pick`. The second reading never changes a letter, only where words break, so the agent judges by language alone. It comes from three sources, each tried on the samples:

- **OCR's breaks just after a misread.** The repair skips a break at the start of a run where PDFKit and OCR agree, because the alignment there may be a character off. On the paper that loses its spaces, 53 such words were offered, and most were wrong, as "T able" and "syste m". A break now counts only where macOS's word list backs it: the letters on each side form words and the letters across it do not, as in "overall shift", or it separates a maths letter from a word, as in "𝑁 test". The 20 words left were all right.
- **The same letters elsewhere in OCR's text.** PDFKit and OCR can put a line in different places in the page's order, and the alignment then leaves it unmatched. A word that is still run together, with more than 25 letters in a row, takes OCR's breaks where its letters occur exactly once in OCR's text. It fixed "nineALW/WOAHeditionsviatheACLAnthology" on the Word-made paper.
- **Common English words.** Where OCR runs the letters together too, they are split into the fewest common words, from the word embedding macOS ships (about 57,000 words, loaded in 73 ms), as "single dataset per condition and should be treated". The full word list holds rare words, such as "sare" and "ora", which split "datasetsare" wrongly. A word that common words cover by at least 60% but that splits no clean way, such as one cut at a line end, gets an unsure block with its one reading and a crop to look at. A German compound, which common English words do not cover, stays as it is.

Names from code and web addresses, such as "SpaceRepairRelocateRunTogetherWords" or a long URL path, run together in both readers because they are written that way. A word with "://", an underscore, two slashes, a dot between small letters, or three capitals after small letters gets no second reading.

On the eleven samples, nine papers got no unsure block, and the two that lose spaces got 28 second readings and one word to look at, over 12 pages. All 28 readings were right when checked by eye. A pick lives apart from the cache and applies only while the page offers the same readings, so a page parsed differently never takes a pick made for other words.

| Option | For | Against |
|---|---|---|
| **A second reading where a word list backs it, picked by the agent** | Fixes what the repair leaves, without a guess in the text. | English only, and an unsure block costs about 60 tokens. |
| Every OCR break applied | No agent step. | Wrong breaks in plain words, such as "T able". |
| Words left run together, unflagged | No noise. | Search misses the merged words, silently. |
