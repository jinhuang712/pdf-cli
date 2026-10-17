#!/bin/sh
# Reads every PDF of the smoke set, testdata/smoke (sources in its SOURCES.md), whole, with an
# empty cache: each must exit 0, or 2 for pages flagged with the rest valid, print a heading for
# every page, finish within 300 s, and flag the pages testdata/smoke/expected-flags.tsv lists,
# no others. A reader that crashes, runs out of time or memory fails the file.
#
# Usage: scripts/smoke-check.sh [path to the pdf binary, default .build/debug/pdf]
#        scripts/smoke-check.sh <pdf binary> --write   writes expected-flags.tsv from this run
set -u
cd "$(dirname "$0")/.."
pdf=${1:-.build/debug/pdf}
[ -x "$pdf" ] || { echo "no pdf binary at $pdf: build it first"; exit 2; }
write=${2:-}
home=$(mktemp -d)
real=$(cd "$(dirname "$pdf")" && pwd -P)/$(basename "$pdf")
settle() { for _ in $(seq 120); do pgrep -f "$real __" >/dev/null || return; sleep 1; done; }
trap 'settle; rm -rf "$home"' EXIT
expected=testdata/smoke/expected-flags.tsv
files=0 failures=0
[ "$write" = --write ] && : >"$expected"

for file in testdata/smoke/*.pdf; do
    name=$(basename "$file" .pdf)
    files=$((files + 1))
    start=$(date +%s)
    output=$(PDF_CLI_HOME=$home perl -e 'alarm shift; exec @ARGV' 300 "$pdf" read "$file" --budget all 2>&1)
    status=$?
    seconds=$(($(date +%s) - start))
    pages=$(PDF_CLI_HOME=$home "$pdf" info "$file" 2>&1 | sed -n 's/^\([0-9]*\) pages\{0,1\} · .*/\1/p' | head -1)
    headings=$(printf '%s\n' "$output" | grep -c '^## p\.')
    flagged=$(printf '%s\n' "$output" | head -1 | sed -n 's/.* · flagged: \([^·]*\).*/\1/p' | sed 's/ *$//')
    [ "$write" = --write ] && printf '%s\t%s\n' "$name" "$flagged" >>"$expected"
    want=$(awk -F '\t' -v name="$name" '$1 == name { print $2 }' "$expected")
    if [ $status -ne 0 ] && [ $status -ne 2 ]; then
        echo "FAIL  $name: exit $status after $seconds s"; failures=$((failures + 1))
    elif printf '%s' "$output" | grep -q -e "reader crashed" -e "time limit" -e "memory limit" -e "reader stopped" -e "(failed)"; then
        echo "FAIL  $name: a page failed: $flagged"; failures=$((failures + 1))
    elif [ -z "$pages" ] || [ "$headings" -ne "$pages" ]; then
        echo "FAIL  $name: $headings page headings for ${pages:-?} pages"; failures=$((failures + 1))
    elif [ "$flagged" != "$want" ]; then
        echo "FAIL  $name: flagged \"$flagged\", expected \"$want\""; failures=$((failures + 1))
    else
        echo "ok    $name: $pages pages in $seconds s, exit $status, flagged: $flagged"
    fi
done

echo "smoke: $((files - failures)) of $files files read whole"
if [ $failures -eq 0 ]; then echo "all smoke checks passed"; else exit 1; fi
