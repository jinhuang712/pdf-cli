import ArgumentParser
import Foundation
import PDFCore

/// Prints the guide that teaches an agent the tool, or installs it as a Claude Code skill
/// (FEATURES.md → F13).
struct AgentGuideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide",
        abstract: "Print a guide that teaches an agent this tool, or install it as a Claude Code skill.",
        discussion: """
            --install claude-code writes the guide to ~/.claude/skills/pdf-cli/SKILL.md, or under CLAUDE_CONFIG_DIR \
            when that is set, and replaces an earlier version there.

            Exit codes: 0 printed or installed; 1 it could not install; 64 used wrongly (an unknown \
            target).

            Examples:
              pdf agent-guide
              pdf agent-guide --install claude-code
              pdf agent-guide --install claude-code --json
            """
    )

    enum Agent: String, ExpressibleByArgument, CaseIterable {
        case claudeCode = "claude-code"
    }

    @Option(help: ArgumentHelp("Install the guide for an agent instead of printing it.", valueName: "agent"))
    var install: Agent?
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try Contract.guarding("pdf agent-guide", json: json) { try guide() }
    }

    func guide() throws {
        guard install != nil else {
            if json {
                print(Contract.json(["guide": AgentGuide.text]))
            } else {
                print(AgentGuide.text, terminator: "")
            }
            return
        }
        let file = AgentGuide.claudeCodeSkillFile()
        let installed: AgentGuide.Installed
        do {
            installed = try AgentGuide.install(at: file)
        } catch {
            throw Contract.fail(file.path, "could not install the Claude Code skill: \((error as NSError).localizedDescription)", json: json)
        }
        // Claude Code watches the skills folders it found at its start, and no others.
        let hint =
            installed == .unchanged
            ? nil
            : "a running Claude Code session picks it up, after /reload-skills if its skills folder is newer than the session"
        // The skill's commands run the pdf that a shell finds on the PATH.
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath()
        var warnings: [String] = []
        if let found = AgentGuide.commandOnPath() {
            if let me, found != me {
                warnings.append("the pdf on the PATH is \(found.path), not this one, \(me.path): the skill's commands run that one")
            }
        } else {
            warnings.append(
                "no pdf on the PATH, so the skill's commands cannot run until one is there"
                    + (me.map { "; this one is \($0.path)" } ?? ""))
        }
        if json {
            struct Body: Encodable {
                var file: String
                var installed: String
                var warnings: [String]
                var hint: String?
            }
            let state = installed == .new ? "new" : installed == .replaced ? "replaced" : "unchanged"
            print(Contract.json(Body(file: file.path, installed: state, warnings: warnings, hint: hint)))
            return
        }
        switch installed {
        case .new: print("installed the Claude Code skill: \(file.path)")
        case .replaced: print("updated the Claude Code skill, replacing the SKILL.md that was there: \(file.path)")
        case .unchanged: print("the Claude Code skill is up to date: \(file.path)")
        }
        if let hint { print(hint) }
        for warning in warnings { print("⚠ " + warning) }
    }
}
