#!/usr/bin/env bash
# Installs (or updates) the pdf-cli plugin for Codex: a skill that teaches the agent the `pdf` command.
#
#   curl -fsSL https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install-codex.sh | bash
#
# Run it again to update. It installs the plugin, then the `pdf` command (install.sh) unless it is already
# on your PATH; set PDF_CLI_SKIP_CLI=1 to leave the command alone, and PDF_CLI_REPO to use a fork.
set -euo pipefail

main() {
  local repo="${PDF_CLI_REPO:-jinhuang712/pdf-cli}"
  local market="pdf-cli"
  local plugin="pdf-cli@pdf-cli"

  command -v codex >/dev/null 2>&1 || die "codex was not found: install Codex first"

  if codex plugin marketplace list </dev/null 2>/dev/null | grep -q "^${market} "; then
    say "updating the plugin marketplace ${market}"
    # a marketplace added from a local path has no snapshot to pull; the reinstall below still works
    codex plugin marketplace upgrade "${market}" </dev/null || true
  else
    say "adding the plugin marketplace ${repo}"
    codex plugin marketplace add "${repo}" </dev/null
  fi

  # Codex copies the plugin into its cache, so remove it first to get the latest
  if codex plugin list </dev/null 2>/dev/null | grep -Eq "^${plugin} +installed"; then
    say "updating the plugin ${plugin}"
    codex plugin remove "${plugin}" </dev/null
  else
    say "installing the plugin ${plugin}"
  fi
  codex plugin add "${plugin}" </dev/null

  check_cli
  say "done. In a new Codex session the skill shows as pdf-cli:pdf-cli"
}

say() { printf '==> %s\n' "$*"; }
warn() { printf 'note: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# The plugin is the guide only, so the pdf command comes too, unless PDF_CLI_SKIP_CLI=1 or it is there.
check_cli() {
  if [ "${PDF_CLI_SKIP_CLI:-0}" = "1" ]; then
    say "skipping the pdf command (PDF_CLI_SKIP_CLI=1)"
  elif command -v pdf >/dev/null 2>&1; then
    say "the pdf command is already on your PATH ($(command -v pdf))"
  else
    say "installing the pdf command (builds from source, a few minutes)"
    curl -fsSL "https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install.sh" | bash
  fi
}

main "$@"
