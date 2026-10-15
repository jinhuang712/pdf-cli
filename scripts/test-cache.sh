#!/bin/bash
# Checks the cache, the runner and the workers end to end, with faults planted in workers:
# a page that hangs, a page that eats memory, a crash, a file that is not a PDF, and three
# commands at once on one new file. Each fault must cost one page, never the document.
set -u

cd "$(dirname "$0")/.."
swift build >/dev/null || exit 1
pdf=.build/debug/pdf
paper=testdata/smoke/arxiv-2607.16859.pdf
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

check() {
    if grep -q -- "$2" <<<"$3"; then
        echo "ok    $1"
    else
        echo "FAIL  $1: expected \"$2\""
        echo "$3" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
}

run() {
    local home=$work/home-$RANDOM
    PDF_CLI_HOME=$home PDF_CLI_PAGE_TIME_LIMIT=2 PDF_CLI_MEMORY_LIMIT_MB=300 "$@" 2>&1
}

output=$(run $pdf debug-pages $paper --page 3)
check "a first read returns the page" "p.3 ok" "$output"
check "a good paper reads without the space repair" "p.3 ok: pdfkit ·" "$output"

output=$(run $pdf debug-pages testdata/smoke/arxiv-2609.23257.pdf --page 2)
check "a paper whose fonts hide spaces gets the repair" "p.2 ok: pdfkit+ocr-spaces" "$output"
check "the repaired page has no run-together words" "0 run together" "$output"

output=$(run $pdf debug-pages testdata/ocr/scan-no-text.pdf --page 1)
check "a scan with no text is read by OCR" "p.1 ok: ocr" "$output"

output=$(run $pdf debug-pages testdata/ocr/scan-right-layer.pdf --page 1)
check "a scan with a right text layer keeps it" "p.1 ok: pdfkit" "$output"

output=$(run $pdf debug-pages testdata/ocr/scan-wrong-layer.pdf --page 2)
check "a file whose text layer fails the sample check is read by OCR" "p.2 ok: ocr" "$output"

output=$(run env PDF_CLI_TEST_FAULT=sample-crash:0 $pdf debug-pages testdata/ocr/scan-right-layer.pdf --page 1)
check "a file whose sample check keeps crashing is read by OCR" "p.1 ok: ocr" "$output"

output=$(run env PDF_CLI_TEST_FAULT=hang:3 $pdf debug-pages $paper)
check "a hanging page fails at the time limit" "p.4 failed: time limit" "$output"
check "the page after a hang still reads" "p.5 ok" "$output"

output=$(run env PDF_CLI_TEST_FAULT=alloc:1 $pdf debug-pages $paper)
check "a page that eats memory fails at the limit" "p.2 failed: memory limit" "$output"
check "the page after it still reads" "p.3 ok" "$output"

output=$(run env PDF_CLI_TEST_FAULT=crash:5 $pdf debug-pages $paper)
check "a page that crashes its worker fails" "p.6 failed: the reader crashed" "$output"
check "the page after a crash still reads" "p.7 ok" "$output"

output=$(run env PDF_CLI_TEST_FAULT=index-hang:3 $pdf debug-pages $paper)
check "a page that hangs while keys are read fails" "p.4 failed: time limit" "$output"
check "the other pages still read" "p.5 ok" "$output"

# A file that moves away mid-parse must leave no failure in the cache: its results are keyed
# by content, so a cached failure would follow every copy of the document.
cp $paper "$work/moving.pdf"
home=$work/moving
PDF_CLI_HOME=$home PDF_CLI_WORKERS=1 PDF_CLI_PAGE_TIME_LIMIT=3 PDF_CLI_TEST_FAULT=hang:4 \
    $pdf debug-pages "$work/moving.pdf" --page 1 >/dev/null
mv "$work/moving.pdf" "$work/away.pdf"
sleep 5
mv "$work/away.pdf" "$work/moving.pdf"
output=$(PDF_CLI_HOME=$home $pdf debug-pages "$work/moving.pdf" 2>&1)
check "a file that moved away mid-parse caches no failure" "11 read" "$output"
if grep -q failed <<<"$output"; then
    echo "FAIL  pages failed after the file came back"
    echo "$output" | grep failed | sed 's/^/      /'
    failures=$((failures + 1))
fi

printf 'hello' >"$work/fake.pdf"
output=$(run $pdf debug-pages "$work/fake.pdf")
check "a file that is not a PDF fails as a whole" "failed: not a PDF" "$output"

home=$work/concurrent
for page in 2 6 10; do
    PDF_CLI_HOME=$home PDF_CLI_LOG=$work/log.txt $pdf debug-pages $paper --page $page >"$work/out-$page.txt" 2>&1 &
done
wait
for page in 2 6 10; do
    check "command $page of three at once reads its page" "p.$page ok" "$(cat "$work/out-$page.txt")"
done
sleep 2
runners=$(grep -o 'runner [0-9]*' "$work/log.txt" | sort -u | wc -l | tr -d ' ')
sent=$(grep ' parse ' "$work/log.txt" | sed 's/.*--pages //' | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' ')
check "three commands at once share one runner" "^1$" "$runners"
check "no page goes to two workers" "^0$" "$sent"

# Three new files at once share one pool of two worker slots, and the pages nobody waits for
# parse at background priority.
home=$work/pool
files='arxiv-2608.16011|arxiv-2608.22898|arxiv-2609.22884'
commands=()
for name in arxiv-2608.16011 arxiv-2608.22898 arxiv-2609.22884; do
    PDF_CLI_HOME=$home PDF_CLI_WORKERS=2 PDF_CLI_LOG=$work/pool-log.txt \
        $pdf debug-pages testdata/smoke/$name.pdf --page 1 >"$work/pool-$name.txt" 2>&1 &
    commands+=($!)
done
most=0
# Watch until every command, runner and worker of the three files has exited. Runners and
# workers name the file on their command line; no other check reads these three files.
while kill -0 "${commands[@]}" 2>/dev/null || pgrep -f "pdf __.*($files)" >/dev/null; do
    count=$(pgrep -f "pdf __worker .*($files)" | wc -l | tr -d ' ')
    [ "$count" -gt "$most" ] && most=$count
    sleep 0.02
done
wait
for name in arxiv-2608.16011 arxiv-2608.22898 arxiv-2609.22884; do
    check "$name reads its first page while two other files parse" "p.1 ok" "$(cat "$work/pool-$name.txt")"
done
check "three new files at once never run more than the pool's two workers" "^[12]$" "$most"
check "pages nobody waits for parse in the background" "(background): parse" "$(cat "$work/pool-log.txt")"

# A command that asks for a page a background worker holds brings that worker to full speed. The
# paper's pages go through OCR, so the background worker is still on page 2 when page 3 is asked for.
slow=testdata/smoke/arxiv-2609.23257.pdf
promote() { PDF_CLI_HOME=$work/promote PDF_CLI_WORKERS=2 PDF_CLI_LOG=$work/promote-log.txt $pdf debug-pages $slow "$@" 2>&1; }
promote --page 1 >/dev/null
check "a page a background worker holds still reads" "p.3 ok" "$(promote --page 3)"
check "asking for it brings the worker to full speed" "promoted worker" "$(cat "$work/promote-log.txt")"
check "a full read brings the rest to full speed too" "18 read" "$(promote)"

# A page that runs out of time in the background, as a throttled worker can, gets one more try
# at full speed before it fails for good.
home=$work/background-hang
PDF_CLI_HOME=$home PDF_CLI_PAGE_TIME_LIMIT=2 PDF_CLI_TEST_FAULT=background-hang:5 \
    $pdf debug-pages $paper --page 1 >/dev/null 2>&1
for _ in $(seq 30); do
    pgrep -f "pdf __runner .*$(basename $paper)" >/dev/null || break
    sleep 1
done
check "a page that ran out of time in the background reads at full speed" "p.6 ok" \
    "$(PDF_CLI_HOME=$home $pdf debug-pages $paper --page 6 2>&1)"

check "page 0 is out of range" "page 0 is out of range" "$(run $pdf debug-pages $paper --page 0)"

# Pages nobody waits for parse slowly, at background priority, so runners get a minute to finish.
for _ in $(seq 60); do
    pgrep -f 'pdf __' >/dev/null || break
    sleep 1
done
check "no worker or runner is left running" "^none$" "$(pgrep -f 'pdf __' || echo none)"

if [ $failures -gt 0 ]; then
    echo "$failures checks failed"
    exit 1
fi
echo "all checks passed"
