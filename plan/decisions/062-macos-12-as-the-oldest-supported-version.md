# 062. macOS 12 as the oldest supported version

Decided: 2026-10-29    Status: current

The tool supports macOS 12 and newer, on Apple Silicon and Intel. This replaces [003](003-macos-11-as-the-oldest-supported-version.md), which said macOS 11.

## The problem

The first release (0.1.0) was to be built with `scripts/build-universal.sh`, which asks for `arm64-apple-macosx11.0` and `x86_64-apple-macosx11.0`. The compiler now installed (Xcode with the macOS 27 SDK) refused: "the macOS deployment target is set to 11.0, but the range of supported deployment target versions is 12.0 to 27.0.x". Decision 003 had checked the same script on 2026-10-15 and found it built for macOS 11. A plain `swift build -c release` had already been producing a binary that says `minos 12.0` (`vtool -show-build`), so the claim of macOS 11 was no longer true of what was built.

## The choice

macOS 12 is the oldest version the current toolchain can build for, and the version the binary says it needs. The table of what needs what stays as in 003, with its first row moved up to macOS 12.

| Option | For | Against |
|---|---|---|
| **macOS 12** | What the toolchain builds and the binary says. Nothing to hide. Layout models, if a goal ever needs one, need macOS 12 as well. | Leaves out macOS 11, which Apple has not updated for years. |
| macOS 11 with an older Xcode | Keeps the wider range. | No older Xcode or SDK is installed, so it cannot be built or tested here; it would be a claim no one has checked. |
| Keep saying macOS 11 | No change to the documents. | The binary refuses to run there, and the README would be wrong. |

## Consequences

`Package.swift`, `scripts/build-universal.sh`, the README, PROPOSAL.md and the install script say macOS 12. Nothing in the code used a macOS 11 path; its checks for macOS 12 and newer APIs stay as they are.
