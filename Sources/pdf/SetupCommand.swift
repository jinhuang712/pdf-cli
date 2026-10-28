import ArgumentParser
import Darwin
import Foundation
import PDFCore

/// Asks the user how much memory parsing may take, and downloads the models that need one
/// (FEATURES.md → F12; plan/decisions/041-the-user-sets-parsing-s-memory-the-tool-the-worker-count.md → Decision: the user sets parsing's memory, the tool the worker
/// count). It asks only at a terminal: an agent's shell has no one to answer, so there it takes
/// the answer from `--memory` and never waits.
struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set how much memory parsing may take; downloads the models that need one (none yet).",
        discussion: """
            Parsing's memory is light, balanced or fastest, or a size. The number of workers follows from it and the \
            Mac's performance cores; fewer run when macOS reports memory pressure, heat or Low Power Mode. At a \
            terminal, pdf setup asks; with --memory it does not. Without a terminal and without --memory it \
            changes nothing and shows the setting.

            Exit codes: 0 shown or set; 1 it could not write the setting; 64 used wrongly (a size \
            below 64 MB, an unknown preset).

            Examples:
              pdf setup
              pdf setup --memory balanced
              pdf setup --memory 3GB --json
              pdf setup --memory default
            """
    )

    @Option(help: ArgumentHelp("light, balanced, fastest, a size such as 4GB or 3072MB, or default.", valueName: "budget"))
    var memory: String?
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if let memory { _ = try Self.choice(memory).get() }
    }

    func run() throws {
        try Contract.guarding("pdf setup", json: json) { try setup() }
    }

    /// What the user chose: a budget in megabytes, or nil for the default.
    enum Choice: Equatable {
        case budget(Int?)
    }

    /// Reads a choice from `--memory` or from an answer at the prompt.
    static func choice(_ text: String) -> Result<Choice, ValidationError> {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        if word == "default" { return .success(.budget(nil)) }
        if let preset = Settings.Preset(rawValue: word) { return .success(.budget(preset.megabytes(performanceCores: Env.performanceCores))) }
        switch Settings.parseMemory(word) {
        case .success(let megabytes): return .success(.budget(megabytes))
        case .failure(let error): return .failure(ValidationError(error.description))
        }
    }

    /// An answer at the prompt: 1, 2 or 3 pick a named budget, Enter keeps the setting, else as `--memory`.
    static func answer(_ line: String) -> Result<Choice?, ValidationError> {
        let word = line.trimmingCharacters(in: .whitespaces).lowercased()
        if word.isEmpty { return .success(nil) }
        if let number = Int(word), (1...Settings.Preset.allCases.count).contains(number) {
            return .success(.budget(Settings.Preset.allCases[number - 1].megabytes(performanceCores: Env.performanceCores)))
        }
        return choice(word).map { $0 }
    }

    static func prompt(current: Int?, cores: Int) -> String {
        var lines = ["How much memory may parsing take? Workers at once follow from it and this Mac's \(cores) performance cores."]
        for (index, preset) in Settings.Preset.allCases.enumerated() {
            let megabytes = preset.megabytes(performanceCores: cores)
            let workers = Settings.plan(budgetMB: megabytes, performanceCores: cores).workers
            lines.append("  \(index + 1)  \(preset.rawValue)  \(Settings.format(megabytes))  \(count(workers, "worker")): \(preset.summary)")
        }
        let now = current.map { "now \(Settings.format($0))" } ?? "now the default, as balanced"
        lines.append("Or a size such as 3GB, or \"default\". Enter keeps it (\(now)). Fewer workers run when the Mac is under pressure.")
        return lines.joined(separator: "\n")
    }

    struct Body: Encodable {
        var memoryMB: Nullable<Int>
        var preset: Nullable<String>
        var workers: Int
        var workerLimitMB: Int
        var performanceCores: Int
        var changed: Bool
        var prompted: Bool
        var file: String
        var overriddenBy: [String]
        var warnings: [String]
        var models: ModelsBody
    }

    struct ModelsBody: Encodable {
        var available: [String]
        var installed: [String]
        var downloaded: [String]
        var note: String
    }

    func setup() throws {
        let (stored, loadProblem) = Settings.load()
        let cores = Env.performanceCores
        var chosen: Choice?
        var prompted = false
        if let memory {
            chosen = try Self.choice(memory).get()
        } else if isatty(STDIN_FILENO) != 0 && !json {
            prompted = true
            print(Self.prompt(current: stored.memoryMB, cores: cores))
            while true {
                print("> ", terminator: "")
                guard let line = readLine() else { break }
                switch Self.answer(line) {
                case .success(let answer):
                    chosen = answer
                case .failure(let error):
                    print(error.message)
                    continue
                }
                break
            }
        }
        var budget = stored.memoryMB
        var changed = false
        if case .budget(let new)? = chosen {
            changed = new != stored.memoryMB || loadProblem != nil
            budget = new
            if changed { try Settings.save(Settings.Stored(memoryMB: new)) }
        }
        let plan = Settings.plan(budgetMB: budget, performanceCores: cores)
        var overridden: [String] = []
        if Env.parsing.workersSource == .environment { overridden.append("PDF_CLI_WORKERS") }
        if Env.parsing.workerLimitSource == .environment { overridden.append("PDF_CLI_MEMORY_LIMIT_MB") }
        var warnings: [String] = loadProblem.map { [$0] } ?? []
        let physical = Int(ProcessInfo.processInfo.physicalMemory >> 20)
        if let budget, budget * 2 > physical {
            warnings.append("\(Settings.format(budget)) is more than half of this Mac's \(Settings.format(physical)) of memory")
        }
        if let budget, budget < Settings.workerLimitMB {
            warnings.append("under 2 GB, a page that needs more fails with a memory-limit failure")
        }
        let models = Models.available
        let installed = Models.installed()
        let note =
            models.isEmpty
            ? "no models to download: none is built yet, and nothing built needs one"
            : "\(models.count) to download; each shows its licence first and downloads only after you accept it"
        let body = Body(
            memoryMB: Nullable(budget), preset: Nullable(budget.flatMap { Settings.preset(forMB: $0, performanceCores: cores)?.rawValue }),
            workers: plan.workers,
            workerLimitMB: plan.workerLimitMB, performanceCores: cores, changed: changed, prompted: prompted,
            file: Settings.file().path, overriddenBy: overridden, warnings: warnings,
            models: ModelsBody(available: models.map(\.name), installed: installed, downloaded: [], note: note))
        if json {
            print(Contract.json(body))
            return
        }
        let name = body.preset.value.map { " (\($0))" } ?? ""
        let now = budget.map { "parsing may take \(Settings.format($0))\(name)" } ?? "parsing's memory is not set: the default holds"
        let how = changed ? "saved" : (chosen == nil ? "unchanged" : "already set")
        print("\(now) · \(count(plan.workers, "worker")) at once, each stopped at \(plan.workerLimitMB) MB · \(how)")
        if chosen == nil && !prompted { print("to set it: pdf setup --memory light|balanced|fastest|<size>|default") }
        if !overridden.isEmpty { print("note: \(overridden.joined(separator: ", ")) in the environment overrides it") }
        for warning in warnings { print("note: \(warning)") }
        print(note)
    }
}
