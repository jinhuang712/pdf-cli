import Foundation
import Testing

@testable import pdf

/// The rules for flags that cannot go together, and the help that states them (plan/ROADMAP.md → M3.7):
/// each ends 64 with a line naming the flags, and each command's own help has an Examples section.
@Suite struct OptionRuleTests {
    static func run(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let home = try OutputContractTests.freshHome()
        let run = try DoctorSetupTests.pdf(arguments, home: home)
        return (run.status, run.output, run.errors)
    }

    static let file = "paper.pdf"

    @Test func readNamesTheTwoSelectorsThatClash() throws {
        let pairs: [([String], String, String)] = [
            (["--page", "1", "--printed-page", "2"], "--page", "--printed-page"),
            (["--page", "1", "--section", "A"], "--page", "--section"),
            (["--page", "1", "--full"], "--page", "--full"),
            (["--printed-page", "2", "--section", "A"], "--printed-page", "--section"),
            (["--section", "A", "--full"], "--section", "--full"),
        ]
        for (flags, first, second) in pairs {
            let run = try Self.run(["read", Self.file] + flags)
            let line = run.errors.split(separator: "\n").first.map(String.init) ?? ""
            #expect(
                run.status == 64 && line.contains(first) && line.contains(second) && line.contains("cannot go together"), "\(flags): \(run.errors)")
        }
        let json = try Self.run(["read", Self.file, "--json", "--format", "text"])
        #expect(json.status == 64 && json.errors.contains("--json") && json.errors.contains("--format"), "\(json.errors)")
    }

    @Test func readKeepsFromWithAPartAndWithBudget() throws {
        // These parse: the file is missing, so they end 1, not 64.
        for flags in [
            ["--page", "3-5", "--from", "p4.7"], ["--section", "A", "--from", "p4"], ["--full", "--from", "p4"],
            ["--from", "p4.7", "--budget", "all"],
        ] {
            let run = try Self.run(["read", "/no/such.pdf"] + flags)
            #expect(run.status == 1, "\(flags): \(run.status) \(run.errors)")
        }
    }

    @Test func cropTakesOnePage() throws {
        for spec in ["3-5", "3,5", "1,2,3"] {
            let run = try Self.run(["crop", Self.file, "--page", spec])
            #expect(run.status == 64 && run.errors.contains("crop takes one page; use --page N"), "\(spec): \(run.errors)")
        }
        for spec in ["0", "x"] {
            let run = try Self.run(["crop", Self.file, "--page", spec])
            #expect(run.status == 64 && run.errors.contains("--page takes one page number"), "\(spec): \(run.errors)")
        }
    }

    @Test func cropNamesTheFlagsThatClash() throws {
        let bbox = ["--page", "1", "--bbox", "0.1,0.1,0.2,0.2"]
        for kind in ["--figure", "--table", "--equation"] {
            let run = try Self.run(["crop", Self.file] + bbox + [kind, "1"])
            #expect(run.status == 64 && run.errors.contains("--bbox and \(kind) cannot go together"), "\(kind): \(run.errors)")
        }
        let two = try Self.run(["crop", Self.file, "--figure", "1", "--table", "1"])
        #expect(two.status == 64 && two.errors.contains("--figure, --table and --equation cannot go together"), "\(two.errors)")
        let none = try Self.run(["crop", Self.file, "--grid"])
        #expect(none.status == 64 && none.errors.contains("give --page, or --figure"), "\(none.errors)")
    }

    @Test func transcribeTakesOnePageAndOneKind() throws {
        let range = try Self.run(["transcribe", Self.file, "--page", "2-3", "--equation", "1"])
        #expect(range.status == 64 && range.errors.contains("transcribe takes one page; use --page N"), "\(range.errors)")
        let both = try Self.run(["transcribe", Self.file, "--page", "1", "--equation", "1", "--table", "1"])
        #expect(both.status == 64 && both.errors.contains("--equation and --table cannot go together"), "\(both.errors)")
        let neither = try Self.run(["transcribe", Self.file, "--page", "1"])
        #expect(neither.status == 64 && neither.errors.contains("--equation or --table"), "\(neither.errors)")
    }

    @Test func searchAndDumpAndPickRulesEndSixtyFour() throws {
        let regex = try Self.run(["search", Self.file, "--regex", "x", "two", "words"])
        #expect(regex.status == 64 && regex.errors.contains("--regex"), "\(regex.errors)")
        let show = try Self.run(["search", Self.file, "word", "--show", "raw"])
        #expect(show.status == 64 && show.errors.contains("--show"), "\(show.errors)")
        let page = try Self.run(["dump", Self.file, "--figures", "--page", "2"])
        #expect(page.status == 64 && page.errors.contains("--page limits --markdown and --text"), "\(page.errors)")
        let reading = try Self.run(["pick", Self.file, "p1.1", "c"])
        #expect(reading.status == 64 && reading.errors.contains("pick a or b"), "\(reading.errors)")
    }

    @Test func everyCommandHasItsOwnHelpWithExamples() throws {
        let names = PDF.configuration.subcommands.filter { $0.configuration.shouldDisplay }.map { $0._commandName }
        #expect(names.contains("clean") && names.contains("doctor") && names.count >= 17)
        for command in PDF.configuration.subcommands where command.configuration.shouldDisplay {
            let help = PDF.helpMessage(for: command)
            #expect(
                help.contains("Examples:") && help.contains("USAGE:") && help.contains("Exit codes"),
                "pdf \(command._commandName) --help has no Examples or no Exit codes")
        }
        // `pdf help <command>` shows the same help.
        let viaHelp = try Self.run(["help", "clean"])
        #expect(viaHelp.status == 0 && viaHelp.output.contains("Examples:"), "\(viaHelp.output)")
    }

    @Test func theTopLevelListNeverWrapsInsideAParenthesis() {
        let help = PDF.helpMessage(for: PDF.self)
        let list = help.components(separatedBy: "Which command:")[1].components(separatedBy: "Examples:")[0]
        for line in list.split(separator: "\n") where line.hasPrefix("  pdf") {
            #expect(line.count <= 78, "\(line)")
            #expect(line.filter { $0 == "(" }.count == line.filter { $0 == ")" }.count, "\(line)")
        }
        #expect(list.contains("pdf clean"))
    }

    @Test func aSingleValueOptionGivenTwiceEnds64() throws {
        let cases: [[String]] = [
            ["read", Self.file, "--section", "A", "--section", "B"], ["read", Self.file, "--printed-page", "1", "--printed-page", "2"],
            ["crop", Self.file, "--page", "3", "--page", "4"], ["transcribe", Self.file, "--page", "3", "--page", "6", "--equation", "1"],
        ]
        for arguments in cases {
            let run = try Self.run(arguments)
            let flag = arguments.first { $0.hasPrefix("--") } ?? ""
            let named = arguments.first { name in name.hasPrefix("--") && arguments.filter { $0 == name }.count > 1 } ?? flag
            #expect(run.status == 64 && run.errors.contains("\(named) given twice"), "\(arguments): \(run.errors)")
        }
        // --page of read may repeat.
        #expect(try Self.run(["read", "/no/such.pdf", "--page", "1", "--page", "3"]).status == 1)
    }
}
