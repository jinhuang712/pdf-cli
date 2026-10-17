#!/bin/sh
# Reads every PDF of the smoke set, testdata/smoke (sources in its SOURCES.md), whole, with an
# empty cache: each must exit 0, or 2 for pages flagged with the rest valid, print a heading for
# every page, and finish within 300 s.
#
# Usage: scripts/smoke-check.sh [path to the pdf binary, default .build/debug/pdf]
set -u
cd "$(dirname "$0")/.."
pdf=${1:-.build/debug/pdf}
[ -x "$pdf" ] || { echo "no pdf binary at $pdf: build it first"; exit 2; }
home=$(mktemp -d)
trap 'pkill -f "$home" 2>/dev/null; rm -rf "$home"' EXIT
files=0 failures=0

for file in testdata/smoke/*.pdf; do
    name=$(basename "$file" .pdf)
    files=$((files + 1))
    start=$(date +%s)
    output=$(PDF_CLI_HOME=$home perl -e 'alarm shift; exec @ARGV' 300 "$pdf" read "$file" --budget all 2>&1)
    status=$?
    seconds=$(($(date +%s) - start))
    pages=$(PDF_CLI_HOME=$home "$pdf" info "$file" 2>&1 | sed -n 's/^\([0-9]*\) pages\{0,1\} · .*/\1/p' | head -1)
    headings=$(printf '%s\n' "$output" | grep -c '^## p\.')
    flagged=$(printf '%s\n' "$output" | head -1 | sed -n 's/.* · \(flagged: [^·]*\).*/\1/p')
    if [ $status -ne 0 ] && [ $status -ne 2 ]; then
        echo "FAIL  $name: exit $status after $seconds s"; failures=$((failures + 1))
    elif [ -z "$pages" ] || [ "$headings" -ne "$pages" ]; then
        echo "FAIL  $name: $headings page headings for ${pages:-?} pages"; failures=$((failures + 1))
    else
        echo "ok    $name: $pages pages in $seconds s, exit $status, $flagged"
    fi
done

echo "smoke: $((files - failures)) of $files files read whole"
if [ $failures -eq 0 ]; then echo "all smoke checks passed"; else exit 1; fi
