# 015. `pdf transcribe` takes the LaTeX on standard input and keeps it beside the picks

Decided: 2026-10-18    Status: current

M2.13's command, `pdf transcribe paper.pdf --page 4 --equation 5`, or `--table 2` for a table's Markdown, which the user asked for too, reads the text from standard input, as a quoted heredoc gives it, and keeps it by the page's key and the region's number as the page gives it, in the agent's own folder, beside the picks. `pdf read` shows it in the region's block, labelled `[equation 5, transcribed <day>]`, with the crop still there to check it by, and `pdf crop --equation 5` prints it beside the image. Each line of it goes out four spaces in: deeper than the block's own `crop:` line, which it could otherwise pass for, and inert in Markdown, where three spaces still make a heading or a fence.

| Option | For | Against |
|---|---|---|
| **Standard input, kept beside the picks** | LaTeX goes in as written: a heredoc in quotes keeps its backslashes, dollar signs and primes. Deleting the cache keeps the agent's work, and the page's key keeps it to the page it was read from. | Two lines more to write than a flag, which the guide shows. |
| The LaTeX as a flag's value | One line. | A shell word in single quotes breaks on a prime, as `f'(x)`, and one in double quotes takes `$` and backslashes as the shell's. |
| Kept in the cache, with the page | One place for a page's data. | The cache is rebuilt at every parser version and deleted at will; the agent's reading would go with it. |
