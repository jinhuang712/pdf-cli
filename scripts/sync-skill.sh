#!/bin/bash
# Writes skills/pdf-cli/SKILL.md, the plugin's copy of the agent guide, from the built `pdf`.
# The guide's source is Sources/PDFCore/AgentGuide.swift; a unit test fails when this copy differs.
# usage: scripts/sync-skill.sh [path to pdf]    (default: .build/release/pdf)
set -eu
cd "$(dirname "$0")/.."
bin=${1:-.build/release/pdf}
config=$(mktemp -d)
trap 'rm -rf "$config"' EXIT
CLAUDE_CONFIG_DIR=$config "$bin" agent-guide --install claude-code > /dev/null
mkdir -p skills/pdf-cli
cp "$config/skills/pdf-cli/SKILL.md" skills/pdf-cli/SKILL.md
echo "skills/pdf-cli/SKILL.md written"
