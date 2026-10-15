#!/bin/sh
# Builds `pdf` as one universal binary (Apple Silicon and Intel).
# `swift build --arch arm64 --arch x86_64` needs Xcode's XCBuild, so this script
# builds each architecture on its own and joins them with lipo, which works with
# the Command Line Tools alone.
set -eu

cd "$(dirname "$0")/.."

swift build -c release --triple arm64-apple-macosx11.0
swift build -c release --triple x86_64-apple-macosx11.0

mkdir -p .build/universal
lipo -create \
    .build/arm64-apple-macosx/release/pdf \
    .build/x86_64-apple-macosx/release/pdf \
    -output .build/universal/pdf

lipo -info .build/universal/pdf
