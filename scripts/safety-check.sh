#!/bin/sh
# Runs the safety set, testdata/safety (made by scripts/make-hidden-fixture.swift), and checks
# goal G16 (GOALS.md): every planted hidden text is flagged and kept out of normal output, and
# no file crashes or hangs the tool. It also checks that the visible controls read whole, that
# what the files carry reaches `pdf info`, and that broken files fail with a reason.
#
# What each page hides comes from the generator, in testdata/safety/planted.tsv, not from the
# tool's own output: every word of a planted string that the page shows nowhere else must stay
# out of the page's text, and the page must mark hidden text.
#
# Usage: scripts/safety-check.sh [path to the pdf binary, default .build/debug/pdf]
set -u
cd "$(dirname "$0")/.."
pdf=${1:-.build/debug/pdf}
[ -x "$pdf" ] || { echo "no pdf binary at $pdf: build it first"; exit 2; }
home=$(mktemp -d)
# The runners and workers a command leaves, as one the alarm stopped, end once their pages are
# read, within the page limits: the script waits for them, by the binary's real path, before it
# removes their cache.
real=$(cd "$(dirname "$pdf")" && pwd -P)/$(basename "$pdf")
settle() { for _ in $(seq 120); do pgrep -f "$real __" >/dev/null || return; sleep 1; done; }
trap 'settle; rm -rf "$home"' EXIT
planted=0 kept=0 stops=0 failures=0

fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }
# A command that runs past 120 s counts as a hang: perl's alarm stops it.
run() { PDF_CLI_HOME=$home/cache perl -e 'alarm shift; exec @ARGV' 120 "$pdf" "$@" 2>&1; }
# A command stopped by a signal, a crash or the alarm, or one whose reader crashed, ran out of
# time or memory, or stopped while opening the file, counts as a crash or a hang.
stopped() {
    [ "$1" -ge 128 ] && return 0
    printf '%s' "$2" | grep -q -e "reader crashed" -e "time limit" -e "memory limit" -e "reader stopped" \
        -e "reader kept stopping" -e "slow to open"
}

# Checks the planted strings of one file, as the manifest names it, against its normal output in
# $work/normal and its output with --show hidden in $work/shown. Prints a line a string, then
# "kept K of N".
check_planted() {
    awk -F '\t' -v file="$1" -v manifest=testdata/safety/planted.tsv -v normal="$home/normal" '
        # Words apart: spaces, punctuation, hyphens, curly quotes and the marks of raised and
        # lowered characters part them.
        function norm(s) {
            gsub(/\^\{|_\{|\}/, " ", s)
            gsub(/“|”|‘|’|—|–/, " ", s)
            gsub(/[][ \t.,;:!?"()\/-]+/, " ", s)
            return " " s " "
        }
        # Whether a planted word stands in a text: a short word as a word of its own, a longer one
        # anywhere, glued to another or not, and one of 5 letters or more spaced out letter by
        # letter as well. Words of letters outside ASCII, as Japanese, which has no spaces, count
        # anywhere.
        function stands(word, text,    squeezed) {
            if (word ~ /[^ -~]/) return index(text, word) > 0
            if (length(word) < 4) return index(text, " " word " ") > 0
            if (index(text, word)) return 1
            if (length(word) < 5) return 0
            squeezed = text
            gsub(/ /, "", squeezed)
            return index(squeezed, word) > 0
        }
        FILENAME == manifest {
            if ($1 != file) next
            if ($3 == "hides") { count++; at[count] = $2; text[count] = $4 }
            else { n = split(norm($4), w, " "); for (i = 1; i <= n; i++) shows[$2 SUBSEP w[i]] = 1 }
            next
        }
        match($0, /^## p\.[0-9]+/) { page = substr($0, 6, RLENGTH - 5) + 0; next }
        FILENAME == normal {
            if (index($0, "[hidden")) flagged[page] = 1
            # Failure blocks, the commands under blocks and the next line are the tool'"'"'s own
            # words; the readings of an unsure block are the page'"'"'s.
            if ($0 ~ /^⚠/ || $0 ~ /^next:/ || $0 ~ /^  (read it as an image|raw|pick|look):/) next
            line = $0
            # So is the crop command that ends a picture'"'"'s line, whose path holds the file'"'"'s
            # name: that command alone, so words a picture'"'"'s line carries before it still count.
            if (line ~ /^\[(image|drawing|stamp|ink|shape)( · [^]]*)?\]/)
                sub(/( ·)? crop: pdf crop [^ ]+ --page [0-9]+ --bbox [0-9.]+,[0-9.]+,[0-9.]+,[0-9.]+$/, " ", line)
            gsub(/\[hidden[^]]*\]/, " ", line)
            # An annotation'"'"'s label, a reading'"'"'s label and the word before a mark'"'"'s comment are
            # the tool'"'"'s too.
            sub(/^\[[a-z]+( · [^]]*)?\]/, " ", line)
            gsub(/\[(a|b|unsure|picked [0-9-]+)\]/, " ", line)
            gsub(/ · comment: /, " ", line)
            body[page] = body[page] norm(line)
            next
        }
        { told[page] = told[page] norm($0) }
        END {
            for (i = 1; i <= count; i++) {
                p = at[i]; n = split(norm(text[i]), w, " "); leaks = ""; shown = 0
                for (j = 1; j <= n; j++) {
                    word = w[j]
                    if (length(word) < 2 || ((p SUBSEP word) in shows)) continue
                    if (stands(word, body[p])) leaks = leaks " " word
                    if (stands(word, told[p])) shown = 1
                }
                if (leaks != "") print "FAIL  " file " p." p ": planted words read as text:" leaks
                else if (!flagged[p]) print "FAIL  " file " p." p ": no hidden-text marker"
                else { kept++; print "ok    " file " p." p ": planted text flagged and kept out" }
                if (!shown) print "FAIL  " file " p." p ": --show hidden does not show it"
            }
            print "kept " kept " of " count
        }
    ' testdata/safety/planted.tsv "$home/normal" "$home/shown"
}

for file in testdata/safety/hidden-*.pdf testdata/hidden/hidden.pdf; do
    name=${file#testdata/}
    run read "$file" --budget all >"$home/normal"
    status=$?
    run read "$file" --budget all --show hidden >"$home/shown"
    if stopped $status "$(cat "$home/normal" "$home/shown")"; then stops=$((stops + 1)); fail "$name: crashed or hung (status $status)"; fi
    result=$(check_planted "$name")
    printf '%s\n' "$result" | grep -v '^kept '
    failures=$((failures + $(printf '%s\n' "$result" | grep -c '^FAIL')))
    count=$(printf '%s\n' "$result" | sed -n 's/^kept \([0-9]*\) of \([0-9]*\)$/\2/p')
    done=$(printf '%s\n' "$result" | sed -n 's/^kept \([0-9]*\) of \([0-9]*\)$/\1/p')
    [ "${count:-0}" -gt 0 ] || fail "$name: the manifest lists nothing it hides"
    planted=$((planted + ${count:-0}))
    kept=$((kept + ${done:-0}))
done

for file in testdata/safety/visible-*.pdf; do
    name=$(basename "$file" .pdf)
    output=$(run read "$file" --budget all)
    status=$?
    if stopped $status "$output"; then stops=$((stops + 1)); fail "$name: crashed or hung (status $status)"
    elif [ $status -ne 0 ] || printf '%s' "$output" | grep -q -e "\[hidden" -e "^⚠"; then fail "$name: does not read whole as text (exit $status)"
    else ok "$name: reads as text"; fi
done

expect_info() {
    output=$(run info "testdata/safety/$1.pdf")
    status=$?
    if stopped $status "$output"; then stops=$((stops + 1)); fail "$1: crashed or hung (status $status)"; return; fi
    if printf '%s' "$output" | grep -q -- "$2"; then ok "$1: pdf info shows $2"; else fail "$1: pdf info lacks \"$2\""; fi
}
expect_info carries-comments "comments: 2 · highlights: 1"
expect_info carries-form-fields "form fields: 4 (3 filled)"
expect_info carries-attachments "attachments: data.csv (23 bytes), notes.txt (26 bytes, p.1) · never opened"
expect_info carries-scripts "JavaScript on document open"
expect_info carries-scripts "Launch on link click (p.1), calc.exe · never run"
# What the files carry reaches `pdf read` too, after the block it sits on (M1.13).
expect_read() {
    output=$(run read "testdata/safety/$1.pdf" --budget all)
    status=$?
    if stopped $status "$output"; then stops=$((stops + 1)); fail "$1: crashed or hung (status $status)"; return; fi
    if [ $status -ne 0 ]; then fail "$1: exit $status"; return; fi
    if printf '%s\n' "$output" | grep -q -F -x -- "$2"; then ok "$1: pdf read shows $2"; else fail "$1: pdf read lacks \"$2\""; fi
}
# A line, or part of one, that pdf read must not show.
expect_no_read() {
    output=$(run read "testdata/safety/$1.pdf" --budget all)
    if printf '%s\n' "$output" | grep -q -F -- "$2"; then fail "$1: pdf read shows \"$2\""; else ok "$1: pdf read leaves out $2"; fi
}
expect_read carries-comments "[comment · Reviewer 2] Please cite the 2019 baseline."
expect_read carries-comments "[highlight · Reviewer 1] The 2017 baseline reaches 71 percent on the held-out set · comment: Check this number."
expect_read carries-comments "[note] Typed note on the page."
expect_read carries-form-fields "[field: Name = Jane Doe]"
expect_read carries-form-fields "[field: Agree = checked]"
expect_read carries-form-fields "[field: Country = France]"
expect_read carries-links "¶2 [See the project page for](https://example.org/paper) the code."
expect_read carries-scripts "¶2 Open the calculator."
expect_read carries-pictures "[stamp] Approved · crop: pdf crop testdata/safety/carries-pictures.pdf --page 1 --bbox 0.73,0.09,0.19,0.06"
expect_read carries-pictures "[drawing] crop: pdf crop testdata/safety/carries-pictures.pdf --page 1 --bbox 0.52,0.30,0.37,0.14"
expect_read carries-pictures "[image] crop: pdf crop testdata/safety/carries-pictures.pdf --page 1 --bbox 0.11,0.30,0.34,0.14"
expect_read carries-pictures "[stamp] · crop: pdf crop testdata/safety/carries-pictures.pdf --page 2 --bbox 0.73,0.79,0.19,0.06"
expect_read carries-pictures "[image] crop: pdf crop testdata/safety/carries-pictures.pdf --page 3 --bbox 0.16,0.11,0.66,0.39"
expect_read carries-pictures "[drawing] crop: pdf crop testdata/safety/carries-pictures.pdf --page 3 --bbox 0.52,0.55,0.37,0.27"
# Page 2 holds no picture, and its stamp's name, a planted line, stays out.
expect_no_read carries-pictures "[image] crop: pdf crop testdata/safety/carries-pictures.pdf --page 2"
expect_no_read carries-pictures "[drawing] crop: pdf crop testdata/safety/carries-pictures.pdf --page 2"
expect_no_read carries-pictures "PLANTED"

for file in testdata/safety/broken-*.pdf testdata/hidden/broken.pdf; do
    name=$(basename "$file" .pdf)
    output=$(run read "$file" --budget all)
    status=$?
    if stopped $status "$output"; then
        stops=$((stops + 1))
        fail "$name: crashed or hung (status $status)"
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
