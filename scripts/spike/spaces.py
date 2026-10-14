"""M0.2b: why PDFKit drops spaces on one paper, and how well each repair works.

Run from the repo root, after building `pdf`:

    uv run --with pikepdf --with pypdfium2 python scripts/spike/spaces.py

1. Lists each font's declared width for character 32.
2. Writes a copy of the paper with that width set from 500 to 250 (spike/out/).
3. Reads both files with PDFKit, the original with Apple's document recognizer
   and with PDFium, and scores four ways of reading the paper against PDFKit's
   text of the corrected copy.

Writes spike/M0.2b-spaces.md.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from difflib import SequenceMatcher
from pathlib import Path

import pikepdf
import pypdfium2 as pdfium

ROOT = Path(__file__).resolve().parents[2]
PAPER = ROOT / "testdata" / "smoke" / "arxiv-2609.23257.pdf"
OUT = ROOT / "spike" / "out"
REPORT = ROOT / "spike" / "M0.2b-spaces.md"
PDF_BIN = ROOT / ".build" / "release" / "pdf"


def json_lines(output: str) -> list[dict]:
    # Split on "\n" only: str.splitlines() also splits on U+2028, which JSON strings may contain.
    return [json.loads(line) for line in output.split("\n") if line.strip()]


def fonts_with_width_32(path: Path) -> list[tuple[str, float]]:
    pdf = pikepdf.open(path)
    seen = {}
    for obj in pdf.objects:
        if isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == "/Font" and "/Widths" in obj and "/FirstChar" in obj:
            first = int(obj.FirstChar)
            if first <= 32 < first + len(obj.Widths):
                seen.setdefault(str(obj.get("/BaseFont")), float(obj.Widths[32 - first]))
    return sorted(seen.items())


def fix_width_32(path: Path, target: Path) -> list[str]:
    pdf = pikepdf.open(path)
    changed = []
    for obj in pdf.objects:
        if isinstance(obj, pikepdf.Dictionary) and obj.get("/Type") == "/Font" and "/Widths" in obj and "/FirstChar" in obj:
            first = int(obj.FirstChar)
            if first <= 32 < first + len(obj.Widths) and float(obj.Widths[32 - first]) == 500:
                obj.Widths[32 - first] = 250
                changed.append(str(obj.get("/BaseFont")))
    pdf.save(target)
    return changed


def pdfkit_pages(path: Path) -> dict[int, str]:
    out = subprocess.run([str(PDF_BIN), "spike", "text", str(path)], capture_output=True, text=True, check=True)
    return {r["page"]: r["text"] for r in json_lines(out.stdout)}


def ocr_pages(path: Path, count: int) -> tuple[dict[int, str], float]:
    start = time.perf_counter()
    out = subprocess.run(
        [str(PDF_BIN), "spike", "docs", str(path), "--pages", f"1-{count}"], capture_output=True, text=True, check=True
    )
    elapsed = time.perf_counter() - start
    return {r["page"]: "\n".join(p["text"] for p in r["paragraphs"]) for r in json_lines(out.stdout)}, elapsed


def pdfium_pages(path: Path) -> dict[int, str]:
    document = pdfium.PdfDocument(str(path))
    # PDFium marks a hyphen at a line break with U+FFFE.
    return {i + 1: document[i].get_textpage().get_text_range().replace("￾", "-") for i in range(len(document))}


def run_together(text: str) -> int:
    return sum(1 for word in re.findall(r"[A-Za-z]+", text) if len(word) > 25)


def strip(text: str) -> tuple[str, list[bool]]:
    """The non-space characters, and for each one whether whitespace came before it."""
    chars, before, gap = [], [], False
    for ch in text:
        if ch.isspace():
            gap = True
            continue
        chars.append(ch)
        before.append(gap)
        gap = False
    return "".join(chars), before


def with_ocr_word_breaks(kit: str, ocr: str) -> str:
    """PDFKit's characters, with a space wherever the OCR text has one inside a matching run."""
    k, k_before = strip(kit)
    o, o_before = strip(ocr)
    fixed = list(k_before)
    for block in SequenceMatcher(None, k, o, autojunk=False).get_matching_blocks():
        for offset in range(1, block.size):  # a block's first character has no reliable neighbour
            if o_before[block.b + offset]:
                fixed[block.a + offset] = True
    return "".join((" " if fixed[i] else "") + ch for i, ch in enumerate(k))


def score(truth: dict[int, str], candidate: dict[int, str]) -> tuple[float, float, int]:
    """Characters matching, spaces found and spaces added, over matching runs of characters."""
    true_spaces = found = added = matched = total = 0
    for page, text in truth.items():
        t, t_before = strip(text)
        c, c_before = strip(candidate.get(page, ""))
        total += len(t)
        for block in SequenceMatcher(None, t, c, autojunk=False).get_matching_blocks():
            matched += block.size
            for offset in range(1, block.size):
                i, j = block.a + offset, block.b + offset
                if t_before[i]:
                    true_spaces += 1
                    found += c_before[j]
                elif c_before[j]:
                    added += 1
    return matched / total, found / true_spaces, added


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    fixed_path = OUT / f"{PAPER.stem}.width32-fixed.pdf"
    widths = fonts_with_width_32(PAPER)
    changed = fix_width_32(PAPER, fixed_path)

    kit = pdfkit_pages(PAPER)
    truth = pdfkit_pages(fixed_path)
    ocr, ocr_seconds = ocr_pages(PAPER, len(kit))
    ium = pdfium_pages(PAPER)
    repaired = {page: with_ocr_word_breaks(kit[page], ocr.get(page, "")) for page in kit}

    methods = {
        "PDFKit alone": kit,
        "PDFKit characters + OCR word breaks": repaired,
        "Apple's document recognizer alone": ocr,
        "PDFium alone": ium,
    }
    lines = ["# M0.2b — Why PDFKit drops spaces, and how to repair it", ""]
    lines.append(f"Generated by `scripts/spike/spaces.py` on `{PAPER.name}`, the one smoke-set paper where PDFKit runs words together.")
    lines.append("")
    lines.append("## Cause")
    lines.append("")
    lines.append("The paper holds no space characters: each word gap is a sideways jump in a `TJ` drawing command. The paper's TeX Gyre Termes fonts use LaTeX's T1 layout, where slot 32 is the visible-space sign, and declare it 500 units wide: twice a normal space. The paper never draws character 32. A one-off measurement during the spike found that on pages 1–5, PDFKit dropped the space at all 294 gaps narrower than about 0.25 em and kept it at all 445 wider gaps, while two papers whose fonts declare 250 kept spaces at gaps of 0.18 em. So PDFKit appears to compare each gap with about half the declared width of character 32. PDFKit's code is closed, so this rule is inferred, and the test below confirms the cause.")
    lines.append("")
    lines.append("Declared width of character 32, per font:")
    lines.append("")
    lines.append("| Font | Width |")
    lines.append("|---|---|")
    for name, width in widths:
        lines.append(f"| `{name}` | {width:g} |")
    lines.append("")
    lines.append(f"Setting the width to 250 in {len(changed)} fonts ({', '.join(f'`{c}`' for c in changed)}) changes the run-together words (letter runs longer than 25) per page from {[run_together(kit[p]) for p in sorted(kit)]} to {[run_together(truth[p]) for p in sorted(truth)]}.")
    lines.append("")
    lines.append("## Repairs")
    lines.append("")
    lines.append("Each method is scored against PDFKit's text of the corrected copy, over the runs of characters the two share. This favours the two PDFKit rows on characters: part of PDFium's difference is a different order, not errors. Most added spaces sit inside formulas and number lists, such as `[0.5, 1.5]`, where the maths fonts give the corrected copy the same problem.")
    lines.append("")
    lines.append("| Method | Characters matching | Spaces found | Spaces added |")
    lines.append("|---|---|---|---|")
    for name, pages in methods.items():
        chars, spaces, added = score(truth, pages)
        lines.append(f"| {name} | {chars:.1%} | {spaces:.1%} | {added} |")
    lines.append("")
    lines.append(f"Apple's document recognizer took {ocr_seconds:.1f} s for {len(kit)} pages ({ocr_seconds / len(kit):.2f} s per page, process start included). It misreads small marks: superscript 1 becomes `'` or `!`, and `}}` becomes `)`.")
    REPORT.write_text("\n".join(lines) + "\n")
    print(f"wrote {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
