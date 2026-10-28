# Changelog

What changed in each release, from the user's side.

## Unreleased

None yet.

## 0.1.0 (2026-10-29)

First release. Read PDFs for a coding agent on a Mac: a map of the file, only the pages asked for, search, crops of tables and figures, and a flag on everything it could not read well. Everything runs on the Mac, with Apple's PDFKit and OCR.

- Needs macOS 12 or later. (The plan was macOS 11, but the toolchain builds for 12 at the lowest, and so the binary says; see plan/decisions/062-macos-12-as-the-oldest-supported-version.md.)
- `pdf add`, `info`, `read`, `search`, `crop`, `note`, `ref`, `dump`, `reparse`, `pick`, `transcribe`, `ls`, `rm`, `doctor`, `clean`, `setup` and `agent-guide`; what each does is in FEATURES.md.
- Output stops at about 5,000 tokens (`--budget` changes it) and ends with the command that goes on; `--json` counts its budget in its own form so it stays under 30,000 characters, the size past which Claude Code files a command's output away.
- Nothing is dropped without a trace: hidden text, running headers, doubtful text, comments and attachments leave a marker, and the first line counts them with the flag that shows them.
- A universal prebuilt binary (Apple silicon and Intel) with a SHA-256 checksum is attached to the release; `scripts/package.sh` builds it, and `install.sh` installs it through curl.
- A plugin for Claude Code and Codex (`.claude-plugin/`, `skills/pdf-cli/SKILL.md`), with `install-claude.sh` and `install-codex.sh`. A test fails when the skill differs from `pdf agent-guide`.
- Known limits: big tables are read from their images, so a question over many rows costs several; every goal in plan/GOALS.md is still being measured. The first small question runs are in reports/M3.6-first-question-runs.md.
