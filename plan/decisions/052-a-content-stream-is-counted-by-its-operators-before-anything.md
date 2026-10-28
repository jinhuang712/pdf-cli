# 052. a content stream is counted by its operators before anything copies it

Decided: 2026-10-25    Status: current

A content stream of 600 KB that inflates to 600 MB (a page's `Contents`, a form, a Type 3 glyph procedure, a tiling pattern) took 1.2 GB and 45 s: the page key copied each stream out with `CGPDFStreamCopyData` (15 s, 1.2 GB at the index), and the sample check then read the page's text through PDFKit (14 s). CGPDFScanner reads the decoded bytes as it goes and holds nothing, so `StreamGuard` counts a stream's operators with it and stops past 20 million (about 0.25 s). A page with a stream over the limit fails at once with its reason and the crop command; its key hashes the stream's dictionary (so its stored length) and the limit, not its bytes, and the index, the sample check and the parse skip it. Every other page keeps its key, so no page key version was raised, which would have orphaned every transcript. A stream with no expanding filter, or one Flate or RunLength filter, stored in 128 KB or less decodes to 130 MB at most (Flate holds 1,032 to 1) and is copied without counting; any other filter chain (two Flate filters in an array, LZW) is always counted. A refusal is remembered with every object that holds the stream, so a later page of the same job that reaches the form through a shared resources dictionary is refused too.

Gap: a bomb with few operators (mostly whitespace) passes the count; the memory limit and the page time limit stop it, as before.

| Option | For | Against |
|---|---|---|
| **Count operators with CGPDFScanner, 20 million, stored size gate** | Streams, so no memory; deterministic (no clock); about 12 ns an operator; keys of other pages stay. | Blind to a stream of whitespace or comments. |
| A byte cap with a streaming inflate | Catches every shape of bomb. | CGPDF gives no raw bytes, so it means finding the stream in the file by hand, a parser of our own. |
| A time limit on the count | Simple. | The answer would depend on the machine: the same file, two answers. |
| The memory limit alone (what stopped it) | Nothing new. | The bomb still ran 30 s and held 1.2 GB first; under the default 2 GB limit it was never stopped by memory. |
