#!/bin/bash
# M2.26 review: two concurrent searches on a cache whose pages are not in the keyword index must
# index each block once. Usage: index-race.sh <pdf binary> <pdf file> [tries]
B=$1; F=$2; N=${3:-3}
H=$(mktemp -d /private/tmp/claude-501/race.XXXX); export PDF_CLI_HOME=$H
DB=$H/Caches/cache.sqlite
$B add "$F" > /dev/null 2>&1
for t in $(seq 1 $N); do
  sqlite3 $DB "
    DELETE FROM block_text; DELETE FROM search_block; DELETE FROM search_page;"
  $B search "$F" the --top 1 > $H/a.out 2>&1 &
  $B search "$F" the --top 1 > $H/b.out 2>&1 &
  wait
  echo "try $t: rows, distinct = $(sqlite3 $DB "SELECT count(*), count(DISTINCT page_key||'/'||block) FROM search_block")"
done
echo "home: $H"
