# 003. macOS 11 as the oldest supported version

Decided: 2026-10-15    Status: current

The tool supports macOS 11 and newer, on Apple Silicon and Intel. macOS 11 is the oldest version that ships every engine the base tool needs. A feature that needs a newer macOS checks the version when it runs and turns off below it, and `pdf doctor` names what an upgrade would unlock.

| Feature | Needs |
|---|---|
| PDFKit text, figures from drawing commands, and OCR in English, Chinese, French, German, Italian, Portuguese and Spanish | macOS 11 |
| Layout models on Core ML, if a goal needs one | macOS 12, because the models convert to Core ML's ML Program format |
| OCR in Japanese and Korean | macOS 13 |
| Scan structure: paragraphs, tables and lists | macOS 26 |

| Option | For | Against |
|---|---|---|
| **macOS 11** | Every base engine is there, including Chinese OCR. Inside the range Apple's current compiler supports (macOS 11–26), and Homebrew still runs on it. | Homebrew serves macOS 11–14 at its lowest support tier. Only macOS 26 is tested, so bugs on older versions reach users first. |
| macOS 10.15 | Reaches Intel Macs that stop at Catalina. | Apple's OCR reads English only. Homebrew no longer runs on it. Below the compiler's supported range. |
| macOS 26 | Every feature works, and the tested version is the only supported one. | Leaves out every Mac that cannot run macOS 26, most Intel Macs among them. |

The universal binary builds for macOS 11 on both architectures, checked with `scripts/build-universal.sh` on 2026-10-15.
