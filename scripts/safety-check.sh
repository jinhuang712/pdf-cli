#!/bin/sh
# Runs the safety set, testdata/safety (made by scripts/make-hidden-fixture.swift), and checks
# goal G16 (GOALS.md): every planted hidden text is flagged and kept out of normal output, and
# no file crashes or hangs the tool. It also checks that the visible controls read whole, that
# what the files carry reaches `pdf info`, and that broken files fail with a reason.
#
# Usage: scripts/safety-check.sh [path to the pdf binary, default .build/debug/pdf]
set -u
cd "$(dirname "$0")/.."
pdf=${1:-.build/debug/pdf}
[ -x "$pdf" ] || { echo "no pdf binary at $pdf: build it first"; exit 2; }
home=$(mktemp -d)
trap 'pkill -f "$home" 2>/dev/null; rm -rf "$home"' EXIT
planted=0 kept=0 stops=0 failures=0

fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }
# A command that runs past 120 s counts as a hang: perl's alarm stops it.
run() { PDF_CLI_HOME=$home/cache perl -e 'alarm shift; exec @ARGV' 120 "$pdf" "$@" 2>&1; }
# Whether a status is an exit of the tool's own, not a signal from a crash or the alarm.
exited() { [ "$1" -lt 128 ]; }

for file in testdata/safety/hidden-*.pdf; do
    name=$(basename "$file" .pdf)
    output=$(run read "$file" --budget all)
    status=$?
    exited $status || { stops=$((stops + 1)); fail "$name: stopped with status $status"; continue; }
    planted=$((planted + 1))
    if printf '%s' "$output" | grep -q PLANTED; then
        fail "$name: the planted text reads as text"
    elif ! printf '%s' "$output" | grep -q "\[hidden"; then
        fail "$name: no hidden-text marker"
    else
        kept=$((kept + 1))
        ok "$name: the planted text is flagged and kept out"
    fi
    shown=$(run read "$file" --budget all --include-hidden)
    printf '%s' "$shown" | grep -q "\[hidden, [^]]*PLANTED" || fail "$name: --include-hidden does not show it, labelled"
done

# The fixture of every trick the reviews of M1.10 found, one a page: each page whose words,
# shown with --include-hidden, hold a planted line must keep it out of normal output.
pages_with() { printf '%s\n' "$1" | awk '/^## p\./ { page = $2 } /PLANTED/ { seen[page] = 1 } END { n = 0; for (p in seen) n++; print n }'; }
output=$(run read testdata/hidden/hidden.pdf --budget all)
status=$?
shown=$(run read testdata/hidden/hidden.pdf --budget all --include-hidden)
if exited $status; then
    pages=$(pages_with "$shown")
    leaked=$(pages_with "$output")
    planted=$((planted + pages))
    kept=$((kept + pages - leaked))
    if [ "$pages" -eq 0 ]; then fail "hidden.pdf: --include-hidden shows no planted line"
    elif [ "$leaked" -eq 0 ]; then ok "hidden.pdf: $pages planted lines flagged and kept out"; else fail "hidden.pdf: $leaked of $pages planted lines read as text"; fi
else
    stops=$((stops + 1))
    fail "hidden.pdf: stopped with status $status"
fi

for file in testdata/safety/visible-*.pdf; do
    name=$(basename "$file" .pdf)
    output=$(run read "$file" --budget all)
    status=$?
    exited $status || { stops=$((stops + 1)); fail "$name: stopped with status $status"; continue; }
    if printf '%s' "$output" | grep -q "\[hidden"; then fail "$name: visible text marked hidden"; else ok "$name: reads as text"; fi
done

expect_info() {
    output=$(run info "testdata/safety/$1.pdf")
    status=$?
    exited $status || { stops=$((stops + 1)); fail "$1: stopped with status $status"; return; }
    if printf '%s' "$output" | grep -q -- "$2"; then ok "$1: pdf info shows $2"; else fail "$1: pdf info lacks \"$2\""; fi
}
expect_info carries-comments "comments: 2 · highlights: 1"
expect_info carries-form-fields "form fields: 4 (3 filled)"
expect_info carries-attachments "attachments: data.csv (23 bytes), notes.txt (26 bytes, p.1) · never opened"
expect_info carries-scripts "JavaScript on document open"
expect_info carries-scripts "Launch on link click (p.1), calc.exe · never run"
output=$(run read testdata/safety/carries-links.pdf --budget all)
status=$?
if exited $status; then ok "carries-links: reads"; else stops=$((stops + 1)); fail "carries-links: stopped with status $status"; fi

for file in testdata/safety/broken-*.pdf testdata/hidden/broken.pdf; do
    name=$(basename "$file" .pdf)
    output=$(run read "$file" --budget all)
    status=$?
    if ! exited $status; then
        stops=$((stops + 1))
        fail "$name: stopped with status $status"
    elif [ $status -eq 3 ] && ! printf '%s' "$output" | grep -q -e "failed: " -e "low-quality: "; then
        fail "$name: failed without a reason"
    elif [ "$name" = broken-stream ] && ! printf '%s' "$output" | grep -q "drawing commands is damaged"; then
        fail "$name: the damaged content stream is not flagged"
    else
        ok "$name: exit $status, $(printf '%s' "$output" | head -1 | sed 's/.*· read //; s/.*failed: /failed: /' | cut -c1-80)"
    fi
done

echo "G16: $kept of $planted planted hidden texts flagged and kept out of normal output; $stops crashes or hangs"
if [ $failures -eq 0 ]; then echo "all safety checks passed"; else echo "$failures safety checks failed"; exit 1; fi
