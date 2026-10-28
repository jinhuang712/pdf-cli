# 037. one guide, printed or installed as a skill

Decided: 2026-10-16    Status: current

The agent guide is one Markdown text built into the binary. `pdf agent-guide` prints it, and `pdf agent-guide --install claude-code` writes the same text, under YAML frontmatter, as a Claude Code skill: `~/.claude/skills/pdf-cli/SKILL.md`, or the `skills` folder under `CLAUDE_CONFIG_DIR` when it is set: Claude Code's docs say that folder replaces `~/.claude` for its settings, history and plugins, and an April 2026 bug report shows Claude Code looking for skills there too. The format follows [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills), checked on 2026-10-16: the frontmatter holds only `name` and `description`, the two fields every place that takes skills accepts, and the description leads with when to use the tool, since the listing shows it alone until the skill loads, cut at 1,536 characters. Claude Code fills `$1` and `${CLAUDE_…}` in a skill and runs a command written as an exclamation mark before a code span, so a test keeps all three out of the guide.

The skill grants no tool permission: `allowed-tools: Bash(pdf *)` would let Claude run every `pdf` command without asking, `pdf rm` and `pdf clean` included, and that choice stays the user's. An install replaces an earlier `SKILL.md`, as a newer guide, and says so; it writes through a link, even one to a file not made yet, so a skills folder kept in a dotfiles repository keeps its link. It warns when no `pdf` is on the PATH, or another one is, since the skill's commands run the one a shell finds. A test holds the guide to the CLI both ways: every command and flag it names exists, every command it writes out parses, and it names every command and flag but two it leaves out on purpose, so neither drifts from the other.

| Option | For | Against |
|---|---|---|
| **One text in the binary, printed or installed** | One source for both. The binary stays one file. A test holds the guide to the CLI. | A change to the guide needs a new build. |
| A Markdown file shipped beside the binary | Editable without a build. | A second file to install and find, against the one-binary decision. |
| A short skill that points to reference files | Less in context once it loads. | The guide is about 1,700 tokens, far under the docs' 500 lines, and F13 asks for one read. |
