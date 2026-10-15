<!-- what-we-build: approved 2026-10-15 -->
# Philosophy

Agents now read PDFs for people. The project answers seven questions, and each answer is a choice.

## What is a PDF?

**A drawing of a document, not the document.** The file only places letters and lines on a page. Reading order, headings and tables are all reconstructed, so every reconstruction can be wrong. No guessing what the file already states: use its own structure first, and infer only the rest.

## What is reading?

**Navigating, not converting.** A good reader skims, jumps, and looks closely only where it matters. No converter first: help the reader find the part that matters.

## How do agents read PDFs differently from humans?

**They believe what they are handed.** A person sees the whole page and notices garbled text. An agent sees only the text it gets, and repeats it with confidence. So **wrong is way worse than missing**. No silent guesses: say what you could not read well.

## What may the tool leave out?

**Nothing goes missing without a trace.** Hidden text can carry planted instructions, and doubtful text can be wrong, so neither belongs in plain output. Dropping them silently is worse: the agent never learns that part of the page exists, and the user never learns what the agent missed. So every part of the file reaches the agent, as text or as a marker in its place that says what sits there, why it was set aside and the command that shows it. No silent drops: mark what you set aside.

## How does an agent read PDFs better?

**A better map beats a bigger context.** Context windows keep growing, but sending more pages does not make an agent read better. Knowing where to look does. No whole document by default: give the agent a map, and let it go where it needs.

## What makes a reading tool good?

**Answers, not conversions.** A reading tool is judged by the questions it helps answer right on real documents, and a wrong answer counts against it more than a missing one. No score that counts converted characters alone: test on real questions.

## How much should the tool do?

**Less, but right.** Every feature earns its place. When in doubt, leave it out.

When two answers collide, "wrong is way worse than missing" wins.

## Reflections

- **If every PDF carried its own structure, would we still need a layout model?**
  More PDFs are tagged each year, so the answer may change over time.
- **When a context window holds a whole library, does a map still beat context?**
  Our bet is yes, because attention runs out before space does. We have not tested that bet.
- **Is an agent's memo part of the document, or part of the reader?**
  It sits beside the text, but it holds the agent's understanding, not the author's words.
- **When the tool flags nothing and is still wrong, who finds out?**
  Wrong is way worse than missing, and an unflagged wrong is the worst case of all.
