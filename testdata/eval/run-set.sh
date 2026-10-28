#!/bin/bash
# usage: run-set.sh <questions.tsv> <pdf> <outdir>   runs both arms over a question file, one at a time.
here=$(dirname "$0")
for arm in A B; do
  while IFS=$'\t' read -r id type q; do
    bash "$here/run-eval.sh" "$arm" "$2" "$id" "$q" "$3" < /dev/null
  done < "$1"
done
