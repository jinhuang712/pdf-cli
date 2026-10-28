#!/usr/bin/env bash
# Installs (or updates) the `pdf` command: it clones the source, builds it, and links it into your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install.sh | bash
#
# There is no prebuilt binary yet, so this builds from source: it needs macOS 11 or later, git and a
# Swift toolchain (Xcode, or `xcode-select --install`), and takes a few minutes. Run it again to update.
#
# Settings, all optional:
#   PDF_CLI_REPO     where to clone from (default https://github.com/jinhuang712/pdf-cli.git)
#   PDF_CLI_REF      a branch or tag to build (default: the repository's default branch)
#   PDF_CLI_SRC      where the source lives (default ~/.local/share/pdf-cli)
#   PDF_CLI_BIN_DIR  where `pdf` is linked (default ~/.local/bin)
set -euo pipefail

main() {
  local repo="${PDF_CLI_REPO:-https://github.com/jinhuang712/pdf-cli.git}"
  local ref="${PDF_CLI_REF:-}"
  local src="${PDF_CLI_SRC:-$HOME/.local/share/pdf-cli}"
  local bin_dir="${PDF_CLI_BIN_DIR:-$HOME/.local/bin}"

  [ "$(uname -s)" = "Darwin" ] || die "pdf runs on macOS only"
  command -v git >/dev/null 2>&1 || die "git was not found: run xcode-select --install"
  command -v swift >/dev/null 2>&1 || die "a Swift toolchain was not found: install Xcode, or run xcode-select --install"

  if [ -d "$src/.git" ]; then
    say "updating the source in $src"
    git -C "$src" fetch --quiet origin ${ref:+"$ref"}
    git -C "$src" checkout --quiet ${ref:+"$ref"} 2>/dev/null || true
    git -C "$src" pull --ff-only --quiet origin ${ref:+"$ref"} 2>/dev/null || git -C "$src" merge --ff-only --quiet FETCH_HEAD
  else
    say "cloning $repo into $src"
    mkdir -p "$(dirname "$src")"
    git clone --quiet ${ref:+--branch "$ref"} "$repo" "$src"
  fi

  say "building (a few minutes the first time)"
  (cd "$src" && swift build -c release --product pdf)

  mkdir -p "$bin_dir"
  ln -sf "$src/.build/release/pdf" "$bin_dir/pdf"
  say "linked $bin_dir/pdf"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) warn "$bin_dir is not on your PATH: add this to your shell profile:  export PATH=\"$bin_dir:\$PATH\"" ;;
  esac
  "$bin_dir/pdf" --version
  say "done. Try: pdf --help. To teach Claude Code the tool: pdf agent-guide --install claude-code"
}

say() { printf '==> %s\n' "$*"; }
warn() { printf 'note: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

main "$@"
