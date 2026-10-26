#!/bin/bash
# M3.10: a cache made by an older build must open, read, search and reparse with the new one.
# Usage: old-cache-check.sh <old-commit>
# Builds <old-commit> in a scratch worktree outside the repo, makes a cache with it (add, read --full,
# search, info, a pick and a transcript), then runs this checkout's build on that same PDF_CLI_HOME and
# checks: no error or SQL text on stderr, read/search/info equal to a fresh-cache run of the new build,
# reparse, picks and transcripts kept, doctor clean, clean --dry-run changing nothing, and the tables and
# columns a fresh cache has all there. Prints ok/FAIL lines; exits non-zero on any FAIL.
# Heavy: two debug builds, the scan parsed twice. Run one at a time.
set -u
OLD=${1:?usage: old-cache-check.sh <old-commit>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$ROOT" || exit 1
SHA=$(git rev-parse --short "$OLD") || exit 1
OLDDIR=$(dirname "$ROOT")/pdf-cli-oldbuild-$SHA
case "$ROOT" in */.claude/worktrees/*) OLDDIR=${ROOT%%/.claude/worktrees/*}-oldbuild-$SHA;; esac
WORK=$(mktemp -d /private/tmp/oldcache.XXXXXX)
failures=0

check() { # name, result (0 = pass), detail
    if [ "$2" = 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; [ -n "${3:-}" ] && echo "$3" | head -20 | sed 's/^/      /'; failures=$((failures + 1)); fi
}
stop_runners() {
    pkill -f "$OLDDIR/.build" 2>/dev/null
    pkill -f "$ROOT/.build/.*pdf __" 2>/dev/null
    sleep 1
}
cleanup() {
    stop_runners
    git -C "$ROOT" worktree remove --force "$OLDDIR" >/dev/null 2>&1
    git -C "$ROOT" worktree prune
    rm -rf "$WORK"
}
trap cleanup EXIT

nice -n 10 swift build -j 2 >/dev/null 2>&1 || { echo "FAIL  build of this checkout"; exit 1; }
NEWBIN=$ROOT/.build/debug/pdf
git worktree add --detach "$OLDDIR" "$OLD" >/dev/null 2>&1 || { echo "FAIL  worktree of $OLD at $OLDDIR"; exit 1; }
(cd "$OLDDIR" && nice -n 10 swift build -j 2 >"$WORK/oldbuild.log" 2>&1) || { echo "FAIL  build of $OLD"; tail -5 "$WORK/oldbuild.log"; exit 1; }
OLDBIN=$OLDDIR/.build/debug/pdf

# The files: a paper with an unsure block and a table, a scan, a file with comments, a hidden-text file.
PAPER=$ROOT/testdata/smoke/arxiv-2608.24191.pdf
SCAN=$ROOT/testdata/smoke/scan-naca-report-1034.pdf
COMM=$ROOT/testdata/safety/carries-comments.pdf
HIDD=$ROOT/testdata/safety/hidden-color.pdf
FILES=("$PAPER" "$SCAN" "$COMM" "$HIDD")

# Fill a home with BIN: add, read --full, search, info, a pick and a transcript.
populate() {
    local bin=$1 home=$2
    export PDF_CLI_HOME=$home
    "$bin" add "${FILES[@]}" >/dev/null 2>&1
    for f in "${FILES[@]}"; do "$bin" read "$f" --full >/dev/null 2>&1; "$bin" info "$f" >/dev/null 2>&1; done
    "$bin" search "$PAPER" urdu --top 3 >/dev/null 2>&1
    "$bin" search the --top 3 >/dev/null 2>&1
    "$bin" pick "$PAPER" p1.17 a >/dev/null 2>&1
    printf '| a | b |\n|---|---|\n| 1 | 2 |\n' | "$bin" transcribe "$PAPER" --page 4 --table 1 >/dev/null 2>&1
    stop_runners
}

# What the checks compare: stdout and exit code of reads, searches and infos; stderr checked apart.
snapshot() {
    local bin=$1 home=$2 out=$3 n=0
    mkdir -p "$out"; export PDF_CLI_HOME=$home
    run() { n=$((n + 1)); "$bin" "$@" >"$out/$n.out" 2>"$out/$n.err"; echo $? >"$out/$n.code"; echo "$*" >"$out/$n.cmd"; }
    for f in "${FILES[@]}"; do
        run read "$f" --full
        run read "$f" --page 1
        run info "$f"
    done
    run search "$PAPER" urdu --top 5
    run search "$SCAN" the --top 5
    run search the --top 8
    run search urdu --top 8
    run ls
    run crop "$PAPER" --page 4 --table 1
    stop_runners
}

H_OLD=$WORK/home-old; H_NEW=$WORK/home-fresh
echo "== old build $SHA: making the cache"
populate "$OLDBIN" "$H_OLD"
DB=$H_OLD/Caches/cache.sqlite; LIB=$H_OLD/Support/library.sqlite
[ -f "$DB" ] && [ -f "$LIB" ]; check "old build made cache.sqlite and library.sqlite" $?
tables() { sqlite3 "$1" ".tables" | tr -s ' ' '\n' | grep . | sort; }
cols() { for t in $(tables "$1"); do sqlite3 "$1" "SELECT '$t.'||name FROM pragma_table_info('$t')"; done | sort; }
tables "$DB" >"$WORK/tables-before"; tables "$LIB" >"$WORK/lib-tables-before"
cols "$DB" >"$WORK/cols-before"; cols "$LIB" >"$WORK/lib-cols-before"
echo "old cache: user_version $(sqlite3 "$DB" 'PRAGMA user_version'), tables: $(tr '\n' ' ' <"$WORK/tables-before")"

echo "== new build: fresh cache"
populate "$NEWBIN" "$H_NEW"
snapshot "$NEWBIN" "$H_NEW" "$WORK/snap-fresh"

echo "== new build on the old cache"
# Pages of an older parser are read again in the background on the first reads; a read says
# "provisional" until they are done. Note how long that takes, then wait it out: the output is
# compared once every page is the new parser's.
export PDF_CLI_HOME=$H_OLD
first_provisional=0
for f in "${FILES[@]}"; do
    for try in $(seq 1 40); do
        "$NEWBIN" read "$f" --full 2>/dev/null | head -1 | grep -q provisional || break
        [ "$try" = 1 ] && first_provisional=$((first_provisional + 1))
        sleep 3
    done
done
echo "files whose first read on the old cache was provisional: $first_provisional of ${#FILES[@]}"
[ "$try" -lt 40 ]; check "pages of the old parser are read again until no read is provisional" $?
stop_runners
snapshot "$NEWBIN" "$H_OLD" "$WORK/snap-old"
bad=0; detail=""
for c in "$WORK"/snap-old/*.cmd; do
    n=$(basename "$c" .cmd); cmd=$(sed "s#$ROOT/##g" "$c")
    code=$(cat "$WORK/snap-old/$n.code")
    # read may end 2 (flagged) or 3 (the scan's page 1 has no text read for certain)
    case "$cmd" in read*) ok="0 2 3";; *) ok="0";; esac
    # Exit code allowed by the documentation, and equal to the fresh run's.
    if ! { echo " $ok " | grep -q " $code " && [ "$code" = "$(cat "$WORK/snap-fresh/$n.code")" ]; }; then
        bad=1; detail="$detail
$cmd: exit $code (fresh: $(cat "$WORK/snap-fresh/$n.code"))"; fi
    if grep -qE 'Error:|SQL|sqlite|no such (table|column)|syntax error|constraint failed' "$WORK/snap-old/$n.err"; then
        bad=1; detail="$detail
$cmd: stderr: $(head -3 "$WORK/snap-old/$n.err")"; fi
    # The two homes differ in their path (crop images live there); take it out.
    if ! diff <(sed "s#$H_OLD#HOME#g" "$WORK/snap-old/$n.out") <(sed "s#$H_NEW#HOME#g" "$WORK/snap-fresh/$n.out") >"$WORK/d.$n"; then
        bad=1; detail="$detail
$cmd: stdout differs from the fresh run:
$(head -6 "$WORK/d.$n")"; fi
done
check "open, ls, info, read (page and --full), search (file and library), crop: exit codes, no error/SQL text, same output as a fresh cache" $bad "$detail"
cat "$WORK"/snap-old/*.out | grep -q 'transcribed'; check "transcript shown in place after the open" $?
cat "$WORK"/snap-old/*.out | grep -q '\[picked'; check "pick shown in place after the open" $?

export PDF_CLI_HOME=$H_OLD
out=$("$NEWBIN" pick "$PAPER" p1.17 b --dry-run 2>&1); echo "$out" | grep -q 'replaces an earlier pick, a'; check "pick survives (a dry-run pick says it would replace a)" $? "$out"
reparse_check() { # label, args...: same exit code on the old cache as on the fresh one, no error text
    local label=$1; shift
    export PDF_CLI_HOME=$H_NEW; "$NEWBIN" reparse "$@" >/dev/null 2>&1; local want=$?
    export PDF_CLI_HOME=$H_OLD; local out rc; out=$("$NEWBIN" reparse "$@" 2>&1); rc=$?
    [ "$rc" = "$want" ] && ! echo "$out" | grep -qE 'Error:|SQL|sqlite'; check "$label (exit $rc, the fresh cache's $want)" $? "$out"
    stop_runners
}
reparse_check "reparse --page 1" "$PAPER" --page 1
reparse_check "reparse --step ocr on the scan" "$SCAN" --page 1 --step ocr
export PDF_CLI_HOME=$H_OLD
"$NEWBIN" read "$PAPER" --page 1 2>&1 | grep -q '\[picked'; check "pick still shown after reparse" $?
"$NEWBIN" read "$PAPER" --page 4 2>&1 | grep -q 'transcribed'; check "transcript still shown after reparse" $?
stop_runners

out=$("$NEWBIN" doctor 2>&1); rc=$?
echo "$out" | grep -q 'cache: ok' && echo "$out" | grep -q 'library: ok' && echo "$out" | grep -q 'problems: none' && [ "$rc" = 0 ]; check "doctor: cache ok, library ok, no problems" $? "$out"
dumpsum() { { sqlite3 "$DB" .dump; sqlite3 "$LIB" .dump; } | shasum | cut -d' ' -f1; }
a=$(dumpsum); out=$("$NEWBIN" clean --dry-run 2>&1); rc=$?; b=$(dumpsum)
[ "$rc" = 0 ] && [ "$a" = "$b" ]; check "clean --dry-run exits 0 and changes nothing in either database" $? "$out"
stop_runners

tables "$DB" >"$WORK/tables-after"; tables "$LIB" >"$WORK/lib-tables-after"
cols "$DB" >"$WORK/cols-after"; cols "$LIB" >"$WORK/lib-cols-after"
tables "$H_NEW/Caches/cache.sqlite" >"$WORK/tables-fresh"; tables "$H_NEW/Support/library.sqlite" >"$WORK/lib-tables-fresh"
cols "$H_NEW/Caches/cache.sqlite" >"$WORK/cols-fresh"; cols "$H_NEW/Support/library.sqlite" >"$WORK/lib-cols-fresh"
missing=$(comm -13 "$WORK/tables-after" "$WORK/tables-fresh"; comm -13 "$WORK/lib-tables-after" "$WORK/lib-tables-fresh"
          comm -13 "$WORK/cols-after" "$WORK/cols-fresh"; comm -13 "$WORK/lib-cols-after" "$WORK/lib-cols-fresh")
[ -z "$missing" ]; check "every table and column of a fresh cache exists after the open" $? "$missing"
echo "added to the old cache by the new build: tables [$(comm -13 "$WORK/tables-before" "$WORK/tables-after" | tr '\n' ' ')] library tables [$(comm -13 "$WORK/lib-tables-before" "$WORK/lib-tables-after" | tr '\n' ' ')] columns [$(comm -13 "$WORK/cols-before" "$WORK/cols-after" | tr '\n' ' ')$(comm -13 "$WORK/lib-cols-before" "$WORK/lib-cols-after" | tr '\n' ' ')]"

ps -axo command | grep -F -e "$OLDDIR/.build" -e "$ROOT/.build/" | grep -v grep | grep -q 'pdf __'; [ $? != 0 ]; check "no stray runner or worker left" $?
echo
[ "$failures" = 0 ] && echo "old-cache-check $SHA: all ok" || echo "old-cache-check $SHA: $failures FAIL"
[ "$failures" = 0 ]
