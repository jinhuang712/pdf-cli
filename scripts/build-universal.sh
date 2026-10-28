#!/bin/sh
# Builds `pdf` as one universal binary (Apple Silicon and Intel), in .build/universal/pdf.
# Each architecture is built on its own and the two are joined with lipo, which works with the
# Command Line Tools alone. A build leaves its binary in one place whatever the triple, so each
# is copied out before the next starts.
set -eu

cd "$(dirname "$0")/.."

rm -rf .build/universal
mkdir -p .build/universal

for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx12.0"
    bin="$(swift build -c release --triple "$arch-apple-macosx12.0" --show-bin-path)/pdf"
    cp "$bin" ".build/universal/pdf-$arch"
done

lipo -create .build/universal/pdf-arm64 .build/universal/pdf-x86_64 -output .build/universal/pdf
rm .build/universal/pdf-arm64 .build/universal/pdf-x86_64

lipo -info .build/universal/pdf
