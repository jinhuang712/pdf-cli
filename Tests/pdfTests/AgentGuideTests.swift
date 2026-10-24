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
        .map { ($0._commandName, $0) })

    /// Flags a command has that the guide leaves out, on purpose: `--full` reads as a read with
    /// no page flag does, `--password` shows the password to every user of the Mac, and `dump`'s
    /// `--page`, `--json` and `--password-stdin` work as they do for the other commands.
    static let leftOut: [String: Set<String>] = ["read": ["--full"], "add": ["--password"], "dump": ["--page", "--json", "--password-stdin"]]
    static let everywhere: Set<String> = ["-h", "--help", "--version"]

    /// A command or a flag the guide names: `pdf read`, or `--raw` and `-j`, in any case, with
    /// digits and underscores, so that a near miss such as `--Raw` or `--json2` is checked too.
    static let mention = #"(?<![\w./<-])pdf ([a-z][a-z-]*)|(?<![\w-])(--?[A-Za-z][\w-]*)"#

    /// A command's flags, as its help lists them: the names at the start of each option line.
    static func flags(of command: ParsableCommand.Type) -> Set<String> {
        let help = PDF.helpMessage(for: command)
        guard let options = help.range(of: "OPTIONS:") else { return [] }
        var names: Set<String> = []
        for line in help[options.upperBound...].split(separator: "\n") where line.hasPrefix("  -") {
            // "  -j <N>   Parse with…" or "  -h, --help   Show…": the names come before the help.
            let head = String(line.dropFirst(2).components(separatedBy: "  ")[0])
            for match in matches(#"(?<![\w-])--?[A-Za-z][\w-]*"#, in: head) { names.insert(group(match, 0, in: head)!) }
        }
        return names
    }

    /// A command as the guide writes it, as the CLI would get it: placeholders filled in, and the
    /// leading `pdf` dropped.
    static func arguments(_ written: String) -> [String] {
        var text = written
        for (placeholder, value) in [("[<pdf>]", "paper.pdf"), ("<words>", "word"), ("<pattern>", "x"),
                                     ("x,y,width,height", "0.1,0.2,0.3,0.4")] {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }
        // A redirection, as `<<'EOF'`, is the shell's, not the CLI's.
        if let redirection = text.range(of: " <<") { text = String(text[..<redirection.lowerBound]) }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "paper.pdf", options: .regularExpression)
        let words = text.split(separator: " ").map { $0 == "N" ? "1" : String($0) }
        return words.first == "pdf" ? Array(words.dropFirst()) : words
    }

    /// What a flag the guide names alone, such as `--page 3`, needs before it to make a whole
    /// command of the one named before it on its line.
    static func base(_ command: String, for flag: [String]) -> [String]? {
        switch command {
        case "read", "info", "add": return [command, "paper.pdf"]
        case "search": return flag.contains("--regex") ? ["search", "paper.pdf"] : ["search", "paper.pdf", "word"]
        case "crop": return flag.contains("--page") ? ["crop", "paper.pdf"] : ["crop", "paper.pdf", "--page", "1"]
        case "agent-guide": return [command]
        default: return nil
        }
    }

    /// Why the CLI refuses a command, or nil when it takes it. Parsing runs each command's own
    /// checks, as `pdf pick`'s a or b, but runs nothing.
    static func refusal(_ arguments: [String]) -> String? {
        do {
            _ = try PDF.parseAsRoot(arguments)
            return nil
        } catch {
            return PDF.message(for: error)
        }
    }

    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    /// What the guide names, line by line: each flag goes with the command named before it on
    /// its line, or with none, and every name that is no command or flag of the CLI is a problem.
    static func read() -> (named: [String: Set<String>], problems: [String], checked: Int) {
        var named: [String: Set<String>] = [:]
        var problems: [String] = []
        var checked = 0
        let allFlags = shown.values.reduce(into: Set<String>()) { $0.formUnion(flags(of: $1)) }
        for line in AgentGuide.text.split(separator: "\n").map(String.init) {
            var command: String?
            for match in matches(mention, in: line) {
                if let name = group(match, 1, in: line) {
                    if shown[name] == nil { problems.append("pdf \(name) is no command that pdf --help lists: \(line)") }
                    command = name
                } else if let flag = group(match, 2, in: line) {
                    checked += 1
                    let known = command.flatMap { shown[$0] }.map(flags(of:)) ?? allFlags
                    if known.contains(flag) {
                        if let command { named[command, default: []].insert(flag) }
                    } else {
                        problems.append("\(flag) is no flag of \(command.map { "pdf \($0)" } ?? "any command"): \(line)")
                    }
                }
            }
            // Each command in code, and each flag in code after a command on its line, must parse.
            command = nil
            for span in matches("`([^`]+)`", in: line).compactMap({ group($0, 1, in: line) }) {
                if let start = matches(#"(?<![\w./<-])pdf [a-z]"#, in: span).first.flatMap({ Range($0.range, in: span) }) {
                    let written = span[start.lowerBound...].trimmingCharacters(in: CharacterSet(charactersIn: "]"))
                    let words = arguments(written)
                    command = words.first
                    // `pdf crop` alone names the command; `pdf crop …` stands for one.
                    if words.count > 1 && !written.contains("…"), let refused = refusal(words) {
                        problems.append("the CLI refuses `\(written)`: \(refused)")
                    }
                } else if span.hasPrefix("-"), arguments(span).count > 1, let command,
                          let base = base(command, for: arguments(span)) {
                    // A flag with its value, as `--format text`; a flag named alone is checked by name.
                    if let refused = refusal(base + arguments(span)) {
                        problems.append("the CLI refuses `\(span)` with pdf \(command): \(refused)")
                    }
                }
            }
        }
        return (named, problems, checked)
    }

    @Test func theGuideNamesEverySubcommand() {
        #expect(Self.shown.count >= 10)
        for name in Self.shown.keys.sorted() {
            #expect(!Self.matches("`pdf \(name)[ `]", in: AgentGuide.text).isEmpty, "the guide never names pdf \(name)")
        }
    }

    @Test func everyCommandAndFlagTheGuideNamesIsBuilt() {
        let (_, problems, checked) = Self.read()
        #expect(checked > 30)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func theGuideNamesEveryFlagOfEveryCommand() {
        let (named, _, _) = Self.read()
        for (name, command) in Self.shown.sorted(by: { $0.key < $1.key }) {
            let missing = Self.flags(of: command).subtracting(named[name] ?? []).subtracting(Self.everywhere)
                .subtracting(Self.leftOut[name] ?? [])
            #expect(missing.isEmpty, "the guide never names \(missing.sorted().joined(separator: ", ")) with pdf \(name)")
        }
    }

    /// Every command's help and the top-level help, against the CLI: a flag a help text names is
    /// a flag of that command, and each example in an "Examples:" block parses, so that a rename
    /// cannot leave a stale help text behind.
    @Test func theHelpTextsNameOnlyFlagsAndCommandsThatParse() {
        let allFlags = Self.shown.values.reduce(into: Set<String>()) { $0.formUnion(Self.flags(of: $1)) }
        var texts: [(String, String, Set<String>)] = [("pdf", PDF.helpMessage(for: PDF.self), allFlags)]
        for (name, command) in Self.shown.sorted(by: { $0.key < $1.key }) {
            texts.append((name, PDF.helpMessage(for: command), Self.flags(of: command)))
        }
        var examples = 0
        for (name, help, own) in texts {
            for match in Self.matches(#"(?<![\w-])--?[A-Za-z][\w-]*"#, in: help) {
                let flag = Self.group(match, 0, in: help)!
                guard flag.hasPrefix("--") else { continue }
                #expect(own.contains(flag) || Self.everywhere.contains(flag), "pdf \(name) --help names \(flag), which is not its flag")
            }
            var inExamples = false
            for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.hasPrefix("Examples:") { inExamples = true; continue }
                if line.isEmpty || !line.hasPrefix(" ") { inExamples = false; continue }
                guard inExamples else { continue }
                var written = line.trimmingCharacters(in: .whitespaces)
                if let pipe = written.range(of: "| pdf ") { written = String(written[written.index(after: pipe.lowerBound)...]).trimmingCharacters(in: .whitespaces) }
                guard written.hasPrefix("pdf ") else { continue }
                examples += 1
                if let input = written.range(of: " < ") { written = String(written[..<input.lowerBound]) }
                if let refused = Self.refusal(Self.arguments(written)) {
                    Issue.record("pdf \(name) --help: the CLI refuses `\(written)`: \(refused)")
                }
            }
        }
        #expect(examples >= 25)
    }

    /// The test itself: near misses and wrong uses a guide could hold must each be caught.
    @Test func theChecksCatchWhatTheyAreFor() {
        #expect(Self.refusal(["pick", "paper.pdf", "p2.5", "c"]) != nil)
        #expect(Self.refusal(["read", "paper.pdf", "--format", "html"]) != nil)
        #expect(Self.refusal(["crop", "paper.pdf", "--bbox", "0.1,0.2,0.3,0.4"]) != nil)
        #expect(Self.refusal(["agent-guide", "--install", "codex"]) != nil)
        #expect(Self.refusal(["read", "paper.pdf", "--from", "p4.7", "--budget", "all"]) == nil)
        let flags = Self.flags(of: ReadCommand.self)
        #expect(flags.contains("--include-hidden") && flags.contains("-h") && !flags.contains("--Raw") && !flags.contains("--bbox"))
        #expect(Self.flags(of: AddCommand.self).contains("-j"))
        let near = Self.matches(Self.mention, in: "`pdf read x.pdf --json2 --Raw` and pdf figure 3")
        #expect(near.count == 4)
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

    /// A link to a file not made yet, as a dotfiles folder set up before the first install.
    @Test func anInstallThroughALinkToNothingYetKeepsTheLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-skill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("skills/pdf-cli/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "../../dotfiles/SKILL.md")
        #expect(try AgentGuide.install(at: file) == .new)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == "../../dotfiles/SKILL.md")
        #expect(try String(contentsOf: folder.appendingPathComponent("dotfiles/SKILL.md"), encoding: .utf8) == AgentGuide.skill)
        let loop = folder.appendingPathComponent("loop.md")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop.md")
        #expect(throws: (any Error).self) { try AgentGuide.install(at: loop) }
    }

    @Test func theCommandOnThePathIsTheFirstExecutableThere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("empty"), plain = folder.appendingPathComponent("plain"),
            tools = folder.appendingPathComponent("tools")
        for made in [empty.appendingPathComponent("pdf"), plain, tools] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        // A folder named pdf, and a file that cannot run, are no command.
        FileManager.default.createFile(atPath: plain.appendingPathComponent("pdf").path, contents: Data())
        FileManager.default.createFile(atPath: tools.appendingPathComponent("pdf").path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        let path = [empty, plain, tools].map(\.path).joined(separator: ":")
        #expect(AgentGuide.commandOnPath(environment: ["PATH": path])?.lastPathComponent == "pdf")
        #expect(AgentGuide.commandOnPath(environment: ["PATH": path])?.deletingLastPathComponent().lastPathComponent == "tools")
        #expect(AgentGuide.commandOnPath(environment: ["PATH": empty.path + ":" + plain.path]) == nil)
        #expect(AgentGuide.commandOnPath(environment: [:]) == nil)
    }
}
