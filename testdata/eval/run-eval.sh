#!/bin/bash
# One run of one question for MEASURE.md. usage: run-eval.sh <A|B> <pdf> <qid> <question> <outdir>
#   A = pdf-cli (Bash + Read, the guide appended); B = the built-in Read only.
# Needs `claude` on the PATH, and for arm A `pdf` (PDF_CLI_BIN = the folder that holds it).
# Each run gets a new PDF_CLI_HOME, so parse times are cold.
set -u
arm=$1; pdf=$2; qid=$3; q=$4; out=$5
bin=${PDF_CLI_BIN:-$(dirname "$(command -v pdf)")}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$out"; cp "$pdf" "$work/doc.pdf"; cd "$work" || exit 1
export PDF_CLI_HOME=$work/home
prompt="Answer from the file ./doc.pdf. Reply with the answer only, then 'Page: N' for the page that holds it. If the file does not say, reply 'Not stated'. Question: $q"
common=(-p --model claude-haiku-5-5 --output-format stream-json --verbose --no-session-persistence
  --setting-sources "" --strict-mcp-config --permission-mode bypassPermissions)
if [ "$arm" = A ]; then
  export PATH="$bin:$PATH"
  printf "%s" "$prompt" | claude "${common[@]}" --tools Bash,Read --append-system-prompt "$(pdf agent-guide)" > "$out/$arm-$qid.jsonl" 2>"$out/$arm-$qid.err"
else
  printf "%s" "$prompt" | claude "${common[@]}" --tools Read > "$out/$arm-$qid.jsonl" 2>"$out/$arm-$qid.err"
fi
