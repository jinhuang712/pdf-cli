import ArgumentParser
import Foundation
import Testing
@testable import pdf
@testable import PDFCore

/// The agent guide against the command line it teaches, so that neither drifts from the other
/// (FEATURES.md → F13).
@Suite struct AgentGuideTests {
    /// Every subcommand that `pdf --help` lists, by name.
    static let shown: [String: ParsableCommand.Type] = Dictionary(uniqueKeysWithValues: PDF.configuration.subcommands
        .filter { $0.configuration.shouldDisplay }
        .map { ($0.configuration.commandName!, $0) })

    /// A command's options, as its help lists them.
    static func options(of command: ParsableCommand.Type) -> String {
        let help = PDF.helpMessage(for: command)
        return help.range(of: "OPTIONS:").map { String(help[$0.upperBound...]) } ?? ""
    }

    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    @Test func theGuideNamesEverySubcommand() {
        #expect(Self.shown.count >= 10)
        for name in Self.shown.keys.sorted() {
            #expect(!Self.matches("`pdf \(name)[ `]", in: AgentGuide.text).isEmpty, "the guide never names pdf \(name)")
        }
    }

    /// Each command in the guide's code is one `pdf --help` lists, and each flag is one of the
    /// command named before it on its line, or, on a line that names none, of some command.
    @Test func everyCommandAndFlagTheGuideNamesIsBuilt() {
        var problems: [String] = []
        var checked = 0
        for line in AgentGuide.text.split(separator: "\n").map(String.init) {
            var command: String?
            for span in Self.matches("`([^`]+)`", in: line).compactMap({ Self.group($0, 1, in: line) }) {
                for match in Self.matches(#"(?<![\w./<-])pdf ([a-z][a-z-]*)|(?<![\w-])(--?[a-z][a-z-]*)"#, in: span) {
                    if let name = Self.group(match, 1, in: span) {
                        if Self.shown[name] == nil { problems.append("pdf \(name) is no command `pdf --help` lists") }
                        command = name
                    } else if let flag = Self.group(match, 2, in: span) {
                        checked += 1
                        let pattern = "(?<![\\w-])\(NSRegularExpression.escapedPattern(for: flag))(?![\\w-])"
                        let owners = command.flatMap { Self.shown[$0] }.map { [$0] } ?? Array(Self.shown.values)
                        if !owners.contains(where: { !Self.matches(pattern, in: Self.options(of: $0)).isEmpty }) {
                            problems.append("\(flag) is no flag of \(command.map { "pdf \($0)" } ?? "any command"): \(line)")
                        }
                    }
                }
            }
        }
        #expect(checked > 20)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func theSkillLeadsWithWhenToUseIt() {
        let skill = AgentGuide.skill
        #expect(skill.hasPrefix("---\nname: pdf-cli\ndescription: \"Use whenever you need to read"))
        #expect(skill.hasSuffix("\n---\n\n" + AgentGuide.text))
        #expect(AgentGuide.description.count <= 1_536)
        #expect(!AgentGuide.description.contains("\"") && !AgentGuide.description.contains("\\"))
        #expect(skill.split(separator: "\n", omittingEmptySubsequences: false).count < 500)
    }

    /// One read, in context for the rest of a session once the skill loads: it stays small.
    @Test func theGuideStaysCompact() {
        #expect(Output.tokens(AgentGuide.text) < 2_000)
    }

    /// Claude Code fills `$1`, `$ARGUMENTS` and `${CLAUDE_…}` in a skill, and runs a command
    /// written as an exclamation mark before a code span. The guide must hold none of them.
    @Test func theSkillHoldsNothingClaudeCodeFillsInOrRuns() {
        #expect(Self.matches(#"\$(\d|ARGUMENTS|\{CLAUDE_)"#, in: AgentGuide.skill).isEmpty)
        #expect(Self.matches(#"(^|\s)!`"#, in: AgentGuide.skill).isEmpty)
        #expect(!AgentGuide.skill.contains("```!"))
    }

    @Test func theSkillGoesWhereClaudeCodeLooks() {
        let home = AgentGuide.claudeCodeSkillFile(environment: ["HOME": "/Users/someone"])
        #expect(home.path == "/Users/someone/.claude/skills/pdf-cli/SKILL.md")
        let config = AgentGuide.claudeCodeSkillFile(environment: ["HOME": "/Users/someone", "CLAUDE_CONFIG_DIR": "/Users/someone/.claude-work"])
        #expect(config.path == "/Users/someone/.claude-work/skills/pdf-cli/SKILL.md")
        let empty = AgentGuide.claudeCodeSkillFile(environment: ["HOME": "/Users/someone", "CLAUDE_CONFIG_DIR": ""])
        #expect(empty.path == "/Users/someone/.claude/skills/pdf-cli/SKILL.md")
        #expect(AgentGuide.claudeCodeSkillFile(environment: [:]).path == NSHomeDirectory() + "/.claude/skills/pdf-cli/SKILL.md")
    }

    @Test func anInstallWritesThenReplacesAnEarlierVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-skill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("skills/pdf-cli/SKILL.md")
        #expect(try AgentGuide.install(at: file) == .new)
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentGuide.skill)
        #expect(try AgentGuide.install(at: file) == .unchanged)
        try Data("an earlier guide".utf8).write(to: file)
        #expect(try AgentGuide.install(at: file) == .replaced)
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentGuide.skill)
    }

    @Test func anInstallThroughALinkKeepsTheLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-skill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appendingPathComponent("dotfiles/SKILL.md")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("an earlier guide".utf8).write(to: kept)
        let file = folder.appendingPathComponent("skills/pdf-cli/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: kept)
        #expect(try AgentGuide.install(at: file) == .replaced)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == kept.path)
        #expect(try String(contentsOf: kept, encoding: .utf8) == AgentGuide.skill)
    }
}
