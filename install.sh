#!/usr/bin/env bash
# Installs (or updates) the `pdf` command: it clones the source, builds it, and links it into your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/jinhuang712/pdf-cli/main/install.sh | bash
#
# It downloads the prebuilt binary of the latest release (Apple silicon and Intel in one file) and checks
# its SHA-256. With PDF_CLI_FROM_SOURCE=1, or when no release has a binary, it builds from source instead:
# that needs git and a Swift toolchain (Xcode, or `xcode-select --install`) and takes a few minutes.
# Run it again to update. Needs macOS 12 or later.
#
# Settings, all optional:
#   PDF_CLI_VERSION      a release to install, such as 0.1.0 (default: the latest)
#   PDF_CLI_FROM_SOURCE  1 to build from source
#   PDF_CLI_REPO         where to clone from when building (default https://github.com/jinhuang712/pdf-cli.git)
#   PDF_CLI_REF          a branch or tag to build (default: the repository's default branch)
#   PDF_CLI_SRC          where the source lives when building (default ~/.local/share/pdf-cli)
#   PDF_CLI_BIN_DIR      where `pdf` goes (default ~/.local/bin)
set -euo pipefail

tmp=""

main() {
  local repo="${PDF_CLI_REPO:-https://github.com/jinhuang712/pdf-cli.git}"
  local ref="${PDF_CLI_REF:-}"
  local src="${PDF_CLI_SRC:-$HOME/.local/share/pdf-cli}"
  local bin_dir="${PDF_CLI_BIN_DIR:-$HOME/.local/bin}"

  [ "$(uname -s)" = "Darwin" ] || die "pdf runs on macOS only"

  if [ "${PDF_CLI_FROM_SOURCE:-0}" != "1" ] && install_release "$bin_dir"; then
    finish "$bin_dir"
    return
  fi
  say "building from source"
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
  finish "$bin_dir"
}

# Downloads the release's binary into $1 and checks it; returns 1 when there is none to use.
install_release() {
  local bin_dir="$1" repo_path="${PDF_CLI_RELEASE_REPO:-jinhuang712/pdf-cli}" version="${PDF_CLI_VERSION:-}"
  command -v curl >/dev/null 2>&1 || return 1
  if [ -z "$version" ]; then
    version="$(curl -fsSL "https://api.github.com/repos/$repo_path/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$version" ] || { warn "no release was found"; return 1; }
  local name="pdf-$version-macos-universal"
  local base="https://github.com/$repo_path/releases/download/v$version"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  say "downloading pdf $version"
  curl -fsSL "$base/$name.tar.gz" -o "$tmp/$name.tar.gz" || { warn "no binary for $version"; return 1; }
  curl -fsSL "$base/$name.tar.gz.sha256" -o "$tmp/$name.tar.gz.sha256" || { warn "no checksum for $version"; return 1; }
  (cd "$tmp" && shasum -a 256 -c "$name.tar.gz.sha256" >/dev/null) || die "the checksum does not match: the download is damaged"
  tar -xz -C "$tmp" -f "$tmp/$name.tar.gz"
  mkdir -p "$bin_dir"
  # A symlink from an earlier source build gives way to the file.
  rm -f "$bin_dir/pdf"
  cp "$tmp/$name/pdf" "$bin_dir/pdf"
  chmod +x "$bin_dir/pdf"
  # A download through curl carries no quarantine mark, so macOS opens it; this covers a copy made otherwise.
  xattr -d com.apple.quarantine "$bin_dir/pdf" 2>/dev/null || true
  say "installed $bin_dir/pdf"
}

finish() {
  local bin_dir="$1"
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
