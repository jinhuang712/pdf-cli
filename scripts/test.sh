#!/bin/sh
# Runs the unit tests. With the Command Line Tools alone, SwiftPM does not find the Swift
# Testing framework, so this script points the compiler and the linker at it.
set -eu

cd "$(dirname "$0")/.."

frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
libraries=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
    swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libraries" \
        "$@"
else
    swift test "$@"
fi
