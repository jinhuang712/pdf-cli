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
            """
    )

    enum Agent: String, ExpressibleByArgument, CaseIterable {
        case claudeCode = "claude-code"
    }

    @Option(help: ArgumentHelp("Install the guide for an agent instead of printing it.", valueName: "agent"))
    var install: Agent?

    func run() throws {
        guard install != nil else {
            print(AgentGuide.text, terminator: "")
            return
        }
        let file = AgentGuide.claudeCodeSkillFile()
        let skills = file.deletingLastPathComponent().deletingLastPathComponent()
        let skillsExisted = FileManager.default.fileExists(atPath: skills.path)
        let installed: AgentGuide.Installed
        do {
            installed = try AgentGuide.install(at: file)
        } catch {
            print("could not install the Claude Code skill at \(file.path): \((error as NSError).localizedDescription)")
            throw ExitCode(1)
        }
        switch installed {
        case .new: print("installed the Claude Code skill: \(file.path)")
        case .replaced: print("updated the Claude Code skill: \(file.path)")
        case .unchanged: print("the Claude Code skill is up to date: \(file.path)")
        }
        // Claude Code watches the skills folders it found at its start, and no others.
        if !skillsExisted {
            print("a Claude Code session that is already running sees it after /reload-skills")
        }
    }
}
