"""M0.3: compare reading order on two-column pages across PDFKit, PDFium,
poppler and Apple's document recognizer.

Run from the repo root, after building `pdf`:

    uv run --with pypdfium2 python scripts/spike/reading_order.py

For each page, every engine's text is reduced to the order in which it visits
the page's left (L) and right (R) halves, keeping only runs of 20 or more
characters. A clean two-column page reads "L R". Full-width captions and
headings add a few switches for every engine alike, so the engines are
compared with each other on the same page. Long alternations such as
"L R L R L R" mean the columns were interleaved.

Writes spike/M0.3-reading-order.md.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pypdfium2 as pdfium

ROOT = Path(__file__).resolve().parents[2]
SMOKE = ROOT / "testdata" / "smoke"
REPORT = ROOT / "spike" / "M0.3-reading-order.md"
PDF_BIN = ROOT / ".build" / "release" / "pdf"
PAGES = range(1, 5)  # pages 1-4 of each paper
SINGLE_COLUMN = {"arxiv-2608.16011.pdf"}
MIN_RUN = 20


def json_lines(output: str) -> list[dict]:
    # Split on "\n" only: str.splitlines() also splits on U+2028, which JSON strings may contain.
    return [json.loads(line) for line in output.split("\n") if line.strip()]


def collapse(sides: list[str], minimum: int = MIN_RUN) -> str:
    runs: list[list] = []
    for side in sides:
        if runs and runs[-1][0] == side:
            runs[-1][1] += 1
        else:
            runs.append([side, 1])
    kept: list[str] = []
    for side, count in runs:
        if count >= minimum and (not kept or kept[-1] != side):
            kept.append(side)
    return " ".join(kept)


def pdfkit_columns(path: Path) -> dict[int, str]:
    out = subprocess.run([str(PDF_BIN), "spike", "text", str(path)], capture_output=True, text=True, check=True)
    return {r["page"]: r["columns"] for r in json_lines(out.stdout) if r["page"] in PAGES}


def pdfium_columns(path: Path) -> dict[int, str]:
    document = pdfium.PdfDocument(str(path))
    result = {}
    for number in PAGES:
        if number > len(document):
            break
        page = document[number - 1]
        width = page.get_width()
        textpage = page.get_textpage()
        sides: list[str] = []
        line: list[tuple[float, float]] = []
        for index in range(textpage.count_chars()):
            char = textpage.get_text_range(index, 1)
            if char in ("\r", "\n"):
                sides.extend(line_sides(line, width))
                line = []
                continue
            if not char.strip() or char == "￾":
                continue
            left, _, right, _ = textpage.get_charbox(index)
            line.append((left, right))
        sides.extend(line_sides(line, width))
        result[number] = collapse(sides)
    return result


def line_sides(boxes: list[tuple[float, float]], width: float) -> list[str]:
    """One side per character of a line, or nothing when the line crosses the page's middle."""
    if not boxes:
        return []
    middle, margin = width / 2, width * 0.05
    low, high = min(b[0] for b in boxes), max(b[1] for b in boxes)
    if low < middle - margin and high > middle + margin:
        return []
    return ["L" if (low + high) / 2 < middle else "R"] * len(boxes)


def poppler_columns(path: Path) -> dict[int, str]:
    out = subprocess.run(
        ["pdftotext", "-bbox-layout", "-f", str(PAGES.start), "-l", str(PAGES.stop - 1), str(path), "-"],
        capture_output=True, text=True, check=True,
    )
    # poppler's -bbox-layout output is not always well-formed XML, so read it with patterns.
    result = {}
    pages = re.split(r'<page width="', out.stdout)[1:]
    for offset, chunk in enumerate(pages):
        width = float(chunk.split('"', 1)[0])
        sides = []
        for line in re.findall(r"<line .*?</line>", chunk, flags=re.S):
            boxes = []
            for x_min, x_max, word in re.findall(r'<word xMin="([\d.]+)" yMin="[\d.]+" xMax="([\d.]+)" yMax="[\d.]+">([^<]*)</word>', line):
                boxes.extend([(float(x_min), float(x_max))] * len(word.strip()))
            sides.extend(line_sides(boxes, width))
        result[PAGES.start + offset] = collapse(sides)
    return result


def apple_columns(path: Path) -> tuple[dict[int, str], list[float]]:
    out = subprocess.run(
        [str(PDF_BIN), "spike", "docs", str(path), "--pages", f"{PAGES.start}-{PAGES.stop - 1}"],
        capture_output=True, text=True, check=True,
    )
    result, timings = {}, []
    for record in json_lines(out.stdout):
        sides = []
        for paragraph in record["paragraphs"]:
            x, _, width, _ = paragraph["bbox"]
            if x < 0.45 and x + width > 0.55:
                continue  # crosses the middle: a title, caption or heading
            side = "L" if x + width / 2 < 0.5 else "R"
            sides.extend([side] * len(paragraph["text"].replace(" ", "")))
        result[record["page"]] = collapse(sides)
        timings.append(record["visionMs"])
    return result, timings


def switches(sequence: str) -> int:
    return max(len(sequence.split()) - 1, 0)


def main() -> int:
    papers = [p for p in sorted(SMOKE.glob("arxiv-*.pdf")) if p.name not in SINGLE_COLUMN]
    rows, totals, vision_ms = [], {"PDFKit": 0, "PDFium": 0, "poppler": 0, "Apple recognizer": 0}, []
    for path in papers:
        engines = {
            "PDFKit": pdfkit_columns(path),
            "PDFium": pdfium_columns(path),
            "poppler": poppler_columns(path),
        }
        apple, timings = apple_columns(path)
        engines["Apple recognizer"] = apple
        vision_ms.extend(timings)
        for number in PAGES:
            cells = {name: seq.get(number, "") for name, seq in engines.items()}
            if not any(cells.values()):
                continue
            for name, seq in cells.items():
                totals[name] += switches(seq)
            rows.append((path.name, number, cells))

    lines = ["# M0.3 — Reading order on two-column pages", ""]
    lines.append("Generated by `scripts/spike/reading_order.py`: pages 1–4 of the nine two-column papers in `testdata/smoke/`.")
    lines.append("")
    lines.append("Each cell shows the order in which an engine's text visits the left (L) and right (R) half of the page, counting only runs of 20 or more characters. A clean two-column page reads `L R`. Full-width blocks add switches for every engine alike. Lines (for Apple's recognizer, paragraphs) that cross the middle of the page are skipped for every engine.")
    lines.append("")
    lines.append("## Total column switches (fewer is better)")
    lines.append("")
    lines.append("| Engine | Switches |")
    lines.append("|---|---|")
    for name, total in totals.items():
        lines.append(f"| {name} | {total} |")
    lines.append("")
    if vision_ms:
        ordered = sorted(vision_ms)
        lines.append(f"Apple recognizer time per page at 200 dpi: median {ordered[len(ordered) // 2]:.0f} ms, max {ordered[-1]:.0f} ms, over {len(ordered)} pages.")
        lines.append("")
    lines.append("## Per page")
    lines.append("")
    lines.append("| File | Page | PDFKit | PDFium | poppler | Apple recognizer |")
    lines.append("|---|---|---|---|---|---|")
    for name, number, cells in rows:
        lines.append(f"| {name} | {number} | {cells['PDFKit']} | {cells['PDFium']} | {cells['poppler']} | {cells['Apple recognizer']} |")
    REPORT.write_text("\n".join(lines) + "\n")
    print(f"wrote {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
